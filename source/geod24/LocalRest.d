/*******************************************************************************

    Provides utilities to mock a network in unittests

    This module is based on the idea that D `interface`s can be used
    to represent a server's API, and that D `class` inheriting this `interface`
    are used to define the server's business code,
    abstracting away the communication layer.

    For example, a server that exposes an API to concatenate two strings would
    define the following code:
    ---
    interface API { public string concat (string a, string b); }
    class Server : API
    {
        public override string concat (string a, string b)
        {
            return a ~ b;
        }
    }
    ---

    Then one can use "generators" to define how multiple process communicate
    together. One such generator, that pioneered this design is `vibe.web.rest`,
    which allows to expose such servers as REST APIs.

    `localrest` is another generator, which uses message passing and threads
    to create a local "network".
    The motivation was to create a testing library that could be used to
    model a network at a much cheaper cost than spawning processes
    (and containers) would be, when doing integration tests.

    Control_Interface:
    When instantiating a `RemoteAPI`, one has the ability to call foreign
    implementations through auto-generated `override`s of the `interface`.
    In addition to that, as this library is intended for testing,
    a few extra functionalities are offered under a control interface,
    accessible under the `ctrl` namespace in the instance.
    The control interface allows to make the node unresponsive to one or all
    methods, for some defined time or until unblocked.
    See `sleep`, `filter`, and `clearFilter` for more details.

    Event_Loop:
    Server process usually needs to perform some action in an asynchronous way.
    Additionally, some actions needs to be completed at a semi-regular interval,
    for example based on a timer.
    For those use cases, a node should call `runTask` or `sleep`, respectively.
    Note that this has the same name (and purpose) as Vibe.d's core primitives.
    Users should only ever call Vibe's `runTask` / `sleep` with `vibe.web.rest`,
    or only call LocalRest's `runTask` / `sleep` with `RemoteAPI`.

    Implementation:
    In order for tests to simulate an asynchronous system accurately,
    multiple nodes need to be able to run concurrently and asynchronously.

    There are two common solutions to this, to use either fibers or threads.
    Fibers have the advantage of being simpler to implement and predictable.
    Threads have the advantage of more accurately describing an asynchronous
    system and thus have the ability to uncover more issues.

    When spawning a node, a thread is spawned, a node is instantiated with
    the provided arguments, and an event loop waits for messages sent
    to the Tid. Messages consist of the sender's Tid, the mangled name
    of the function to call (to support overloading) and the arguments,
    serialized as a JSON string.

    Note:
    While this module's original motivation was to test REST nodes,
    the only dependency to Vibe.d is actually to it's JSON module,
    as Vibe.d is the only available JSON module known to the author
    to provide an interface to deserialize composite types.

    Removed Tid
    Added ITransceiver

    Author:         Mathias 'Geod24' Lang
    License:        MIT (See LICENSE.txt)
    Copyright:      Copyright (c) 2018-2019 Mathias Lang. All rights reserved.

*******************************************************************************/

module geod24.LocalRest;

import geod24.concurrency;
import geod24.Transceiver;

import vibe.data.json;

import std.meta : AliasSeq;
import std.traits : Parameters, ReturnType;

import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time;

/// Simple wrapper to deal with tuples
/// Vibe.d might emit a pragma(msg) when T.length == 0
private struct ArgWrapper (T...)
{
    static if (T.length == 0)
        size_t dummy;
    T args;
}

/// Commands used to shutdown the server
const string SHUTDOWN_COMMAND = "shutdown@command";

/*******************************************************************************

    After making the request, wait until the response comes,
    and find the response that suits the request.

*******************************************************************************/

private class WaitingManager
{
    /// Just a Condition with a state
    private struct Waiting
    {
        Condition c;
        bool busy;
    }

    /// The 'Response' we are currently processing, if any
    public Response pending;

    /// Request IDs waiting for a response
    public Waiting[ulong] waiting;

    /// Get the next available request ID
    public size_t getNextResponseId () @safe nothrow
    {
        static size_t last_idx;
        return last_idx++;
    }

    /// Wait for a response.
    public Response waitResponse (size_t id, Duration duration) @trusted nothrow
    {
        try
        {
            if (id !in this.waiting)
                this.waiting[id] = Waiting(thisScheduler.newCondition(null), false);

            Waiting* ptr = &this.waiting[id];
            if (ptr.busy)
                assert(0, "Trying to override a pending request");

            // We yield and wait for an answer
            ptr.busy = true;

            if (duration == Duration.init)
                ptr.c.wait();
            else if (!ptr.c.wait(duration))
                this.pending = Response(Status.Timeout, id, "");

            ptr.busy = false;
            // After control returns to us, `pending` has been filled
            scope(exit) this.pending = Response.init;
            return this.pending;
        }
        catch (Exception e)
        {
            import std.format;
            assert(0, format("Exception - %s", e.message));
        }
    }

    /// Called when a waiting condition was handled and can be safely removed
    public void remove (size_t id) @safe nothrow
    {
        this.waiting.remove(id);
    }

    /// Returns true if a key value equal to id exists.
    public bool exist (size_t id) @safe nothrow
    {
        return ((id in this.waiting) !is null);
    }
}


/// Helper template to get the constructor's parameters
private static template CtorParams (Impl)
{
    static if (is(typeof(Impl.__ctor)))
        private alias CtorParams = Parameters!(Impl.__ctor);
    else
        private alias CtorParams = AliasSeq!();
}


/***************************************************************************

    Getter of WaitingManager assigned to a called thread.

***************************************************************************/

public @property WaitingManager thisWaitingManager () nothrow
{
    if (auto p = "WaitingManager" in thisInfo.objectValues)
        return cast(WaitingManager)(*p);
    else
        return null;
}

/***************************************************************************

    Setter of WaitingManager assigned to a called thread.

***************************************************************************/

public @property void thisWaitingManager (WaitingManager value) nothrow
{
    thisInfo.objectValues["WaitingManager"] = cast(Object)value;
}



/***************************************************************************

    Getter of ITransceiver assigned to a called thread.

***************************************************************************/

public @property ITransceiver thisTransceiver () nothrow
{
    if (auto p = "ITransceiver" in thisInfo.objectValues)
        return cast(ITransceiver)(*p);
    else
        return null;
}

/***************************************************************************

    Setter of ITransceiver assigned to a called thread.

***************************************************************************/

public @property void thisTransceiver (ITransceiver value) nothrow
{
    thisInfo.objectValues["ITransceiver"] = cast(Object)value;
}


/*******************************************************************************

    Receive requests, To obtain and return results by passing
    them to an instance of the Node.

*******************************************************************************/

private class Server (API)
{
    /***************************************************************************

        Instantiate a node and start it

        This is usually called from the main thread, which will start all the
        nodes and then start to process request.
        In order to have a connected network, no nodes in any thread should have
        a different reference to the same node.
        In practice, this means there should only be one `ServerTransceiver`
        per "address".

        Note:
            When the `Server` returned by this function is finalized,
            the child thread will be shut down.
            This ownership mechanism should be replaced with reference counting
            in a later version.

        Params:
            Impl = Type of the implementation to instantiate
            args = Arguments to the object's constructor

        Returns:
            A `Server` owning the node reference

    ***************************************************************************/

    public static Server!API spawn (Impl) (CtorParams!Impl args)
    {
        auto transceiver = spawned!Impl(args);
        return new Server(transceiver);
    }


    /***************************************************************************

        Handler function

        Performs the dispatch from `req` to the proper `node` function,
        provided the function is not filtered.

        Params:
            req    = the request to run (contains the method name and the arguments)
            node   = the node to invoke the method on
            filter = used for filtering API calls (returns default response)

    ***************************************************************************/

    private static void handleRequest (Request req, API node, FilterAPI filter)
    {
        import std.format;

        switch (req.method)
        {
            static foreach (member; __traits(allMembers, API))
            static foreach (ovrld; __traits(getOverloads, API, member))
            {
                mixin(
                q{
                    case `%2$s`:
                    try
                    {
                        if (req.method == filter.func_mangleof)
                        {
                            // we have to send back a message
                            import std.format;
                            req.sender.send(Response(Status.Failed, req.id,
                                format("Filtered method '%%s'", filter.pretty_func)));
                            return;
                        }

                        auto args = req.args.deserializeJson!(ArgWrapper!(Parameters!ovrld));

                        static if (!is(ReturnType!ovrld == void))
                        {
                            req.sender.send(Response(Status.Success, req.id, node.%1$s(args.args).serializeToJsonString()));
                        }
                        else
                        {
                            node.%1$s(args.args);
                            req.sender.send(Response(Status.Success, req.id));
                        }
                    }
                    catch (Throwable t)
                    {
                        // Our sender expects a response
                        req.sender.send(Response(Status.Failed, req.id, t.toString()));
                    }

                    return;
                }.format(member, ovrld.mangleof));
            }
        default:
            assert(0, "Unmatched method name: " ~ req.method);
        }
    }


    /***************************************************************************

        Main dispatch function

        This function receive string-serialized messages from the calling thread,
        which is a struct with the sender's ITransceiver, the method's mangleof,
        and the method's arguments as a tuple, serialized to a JSON string.

        Params:
            Implementation = Type of the implementation to instantiate
            args = Arguments to `Implementation`'s constructor

    ***************************************************************************/

    private static ServerTransceiver spawned (Implementation) (CtorParams!Implementation cargs)
    {
        import std.datetime.systime : Clock, SysTime;

        ServerTransceiver transceiver = new ServerTransceiver();
        WaitingManager waitingManager = new WaitingManager();
        auto thread_scheduler = ThreadScheduler.instance;

        // used for controling filtering / sleep
        struct Control
        {
            FilterAPI filter;    // filter specific messages
            SysTime sleep_until; // sleep until this time
            bool drop;           // drop messages if sleeping
        }

        thread_scheduler.spawn({

            scope node = new Implementation(cargs);

            Control control;

            bool isSleeping()
            {
                return control.sleep_until != SysTime.init
                    && Clock.currTime < control.sleep_until;
            }

            void handle (Request req)
            {
                thisScheduler.spawn(() {
                    Server!(API).handleRequest(req, node, control.filter);
                });
            }

            auto fiber_scheduler = new FiberScheduler();
            fiber_scheduler.start({
                thisTransceiver = transceiver;
                thisWaitingManager = waitingManager;
                bool terminate = false;
                thisScheduler.spawn({
                    while (!terminate)
                    {
                        Request req = transceiver.req.receive();

                        if (req.method == SHUTDOWN_COMMAND)
                            terminate = true;

                        if (terminate)
                            break;

                        if (!isSleeping())
                        {
                            thisScheduler.spawn({
                                Server!(API).handleRequest(req, node, control.filter);
                            });
                        }
                        else if (!control.drop)
                        {
                            auto c = thisScheduler.newCondition(null);
                            thisScheduler.spawn({
                                while (isSleeping())
                                    thisScheduler.wait(c, 1.msecs);
                                Server!(API).handleRequest(req, node, control.filter);
                            });
                        }
                    }
                });

                thisScheduler.spawn({
                    while (!terminate)
                    {
                        TimeCommand time_command = transceiver.ctrl_time.receive();

                        if (terminate)
                            break;

                        control.sleep_until = Clock.currTime + time_command.dur;
                        control.drop = time_command.drop;
                    }
                });

                thisScheduler.spawn({
                    while (!terminate)
                    {
                        FilterAPI filter = transceiver.ctrl_filter.receive();

                        if (terminate)
                            break;

                        control.filter = filter;
                    }
                });

                thisScheduler.spawn({
                    auto c = thisScheduler.newCondition(null);
                    while (!terminate)
                    {
                        Response res = transceiver.res.receive();

                        if (terminate)
                            break;

                        foreach (_; 0..10)
                        {
                            if (waitingManager.exist(res.id))
                                break;
                            thisScheduler.wait(c, 1.msecs);
                        }

                        waitingManager.pending = res;
                        waitingManager.waiting[res.id].c.notify();
                        waitingManager.remove(res.id);
                    }
                });
            });
        });

        return transceiver;
    }

    /// Devices that can receive requests.
    private ServerTransceiver _transceiver;


    /***************************************************************************

        Create an instante of a `Server`

        Params:
            transceiver = This is an instance of `ServerTransceiver` and
                a device that can receive requests.

    ***************************************************************************/

    public this (ServerTransceiver transceiver) @nogc pure nothrow
    {
        this._transceiver = transceiver;
    }


    /***************************************************************************

        Returns the `ServerTransceiver`

        This can be useful for calling `geod24.concurrency.register` or similar.
        Note that the `ServerTransceiver` should not be used directly,
        as our event loop, would error out on an unknown message.

    ***************************************************************************/

    @property public ServerTransceiver transceiver () @safe nothrow
    {
        return this._transceiver;
    }


    /***************************************************************************

        Send an async message to the thread to immediately shut down.

    ***************************************************************************/

    public void shutdown () @trusted
    {
        this._transceiver.send(Request(null, 0, SHUTDOWN_COMMAND));
        this._transceiver.close();
    }
}


/*******************************************************************************

    Request to the `Server`, receive a response

*******************************************************************************/

private class Client
{
    /// Devices that can receive a response
    private ClientTransceiver _transceiver;

    /// After making the request, wait until the response comes,
    /// and find the response that suits the request.
    private WaitingManager _waitingManager;

    /// Timeout to use when issuing requests
    private Duration _timeout;

    ///
    private bool _terminate;

    /// Ctor
    public this (Duration timeout = Duration.init) @safe nothrow
    {
        this._transceiver = new ClientTransceiver;
        this._waitingManager = new WaitingManager();
        this._timeout = timeout;
    }


    /***************************************************************************

        Returns client's Transceiver.
        It accept only `Response`.

        Returns:
            Client's Transceiver

    ***************************************************************************/

    @property public ClientTransceiver transceiver () @safe nothrow
    {
        return this._transceiver;
    }


    /***************************************************************************

        This enables appropriate responses to requests through the API

        Params:
           remote = Instance of ServerTransceiver
           req = `Request`
           res = `Response`

    ***************************************************************************/

    public Response router (ServerTransceiver remote, string method, string args) @trusted
    {
        Request req;
        Response res;

        // from Node to Node
        if (thisWaitingManager !is null)
        {
            req = Request(thisTransceiver, thisWaitingManager.getNextResponseId(), method, args);
            remote.send(req);
            res = thisWaitingManager.waitResponse(req.id, this._timeout);
        }
        // from MainThread to Node
        else
        {
            if (thisScheduler is null)
                thisScheduler = new FiberScheduler();

            thisScheduler.spawn({
                req = Request(this.transceiver, this._waitingManager.getNextResponseId(), method, args);
                remote.send(req);
            });

            this._terminate = false;
            auto c = thisScheduler.newCondition(null);
            thisScheduler.spawn({
                while (!this._terminate)
                {
                    Response res = this._transceiver.res.receive();

                    if (this._terminate)
                        break;

                    foreach (_; 0..10)
                    {
                        if (this._waitingManager.exist(res.id))
                            break;
                        thisScheduler.wait(c, 1.msecs);
                    }

                    this._waitingManager.pending = res;
                    this._waitingManager.waiting[res.id].c.notify();
                    this._waitingManager.remove(res.id);
                }
            });

            thisScheduler.start({
                res = this._waitingManager.waitResponse(req.id, this._timeout);
                this._terminate = true;
            });
        }

        return res;
    }

    /***************************************************************************

        Send an async message to the thread to immediately shut down.

    ***************************************************************************/

    public void shutdown () @trusted
    {
        this._terminate = true;
        this._transceiver.close();
    }


    /***************************************************************************

        Get next response id

        Returns:
            Next Response id, It use in Resuest's id

    ***************************************************************************/

    public size_t getNextResponseId () @trusted nothrow
    {
        return this._waitingManager.getNextResponseId();
    }
}

/*******************************************************************************

    Provide eventloop-like functionalities

    Since nodes instantiated via this modules are Vibe.d server,
    they expect the ability to run an asynchronous task ,
    usually provided by `vibe.core.core : runTask`.

    In order for them to properly work, we need to integrate them to our event
    loop by providing the ability to spawn a task, and wait on some condition,
    optionally with a timeout.

    The following functions do that.
    Note that those facilities are not available from the main thread,
    while is supposed to do tests and doesn't have a scheduler.

*******************************************************************************/

public void runTask (scope void delegate() dg)
{
    assert(thisScheduler !is null, "Cannot call this function from the main thread");
    thisScheduler.spawn(dg);
}

/// Ditto
public void sleep (Duration timeout)
{
    assert(thisScheduler !is null, "Cannot call this function from the main thread");
    scope c = thisScheduler.newCondition(null);
    thisScheduler.wait(c, timeout);
}

/*******************************************************************************

    It has one `Server` and one `Client`. make a new thread It uses `Server`.

*******************************************************************************/

public class RemoteAPI (API) : API
{
    /***************************************************************************

        Instantiate a node and start it

        This is usually called from the main thread, which will start all the
        nodes and then start to process request.
        In order to have a connected network, no nodes in any thread should have
        a different reference to the same node.
        In practice, this means there should only be one `ServerTransceiver`
        per "address".

        Note:
          When the `RemoteAPI` returned by this function is finalized,
          the child thread will be shut down.
          This ownership mechanism should be replaced with reference counting
          in a later version.

        Params:
          Impl = Type of the implementation to instantiate
          args = Arguments to the object's constructor
          timeout = (optional) timeout to use with requests

        Returns:
          A `RemoteAPI` owning the node reference

    ***************************************************************************/

    public static RemoteAPI!(API) spawn (Impl) (CtorParams!Impl args)
    {
        auto server = Server!API.spawn!Impl(args);
        return new RemoteAPI(server.transceiver);
    }

    /// A device that can requests.
    private ServerTransceiver _server_transceiver;

    /// Request to the `Server`, receive a response
    private Client _client;

    // Vibe.d mandates that method must be @safe
    @safe:

    /***************************************************************************

        Create an instante of a client

        This connects to an already instantiated node.
        In order to instantiate a node, see the static `spawn` function.

        Params:
            transceiver = `ServerTransceiver` of the node.
            timeout = any timeout to use

    ***************************************************************************/

    public this (ServerTransceiver transceiver, Duration timeout = Duration.init) @safe nothrow
    {
        this._server_transceiver = transceiver;
        this._client = new Client(timeout);
    }


    /***************************************************************************

        Introduce a namespace to avoid name clashes

        The only way we have a name conflict is if someone exposes `ctrl`,
        in which case they will be served an error along the following line:
        LocalRest.d(...): Error: function `RemoteAPI!(...).ctrl` conflicts
        with mixin RemoteAPI!(...).ControlInterface!() at LocalRest.d(...)

    ***************************************************************************/

    public mixin ControlInterface!() ctrl;

    /// Ditto
    private mixin template ControlInterface ()
    {

        /***********************************************************************

            Returns the `ServerTransceiver`

        ***********************************************************************/

        @property public ServerTransceiver transceiver () @safe nothrow
        {
            return this._server_transceiver;
        }


        /***********************************************************************

            Send an async message to the thread to immediately shut down.

        ***********************************************************************/

        public void shutdown () @trusted
        {
            this._server_transceiver.send(Request(null, 0, SHUTDOWN_COMMAND));
            this._server_transceiver.close();
            this._client.shutdown();
        }


        /***********************************************************************

            Make the remote node sleep for `Duration`

            The remote node will call `Thread.sleep`, becoming completely
            unresponsive, potentially having multiple tasks hanging.
            This is useful to simulate a delay or a network outage.

            Params:
              delay = Duration the node will sleep for
              dropMessages = Whether to process the pending requests when the
                             node come back online (the default), or to drop
                             pending traffic

        ***********************************************************************/

        public void sleep (Duration d, bool dropMessages = false) @trusted
        {
            this._server_transceiver.send(TimeCommand(d, dropMessages));
        }


        /***********************************************************************

            Filter any requests issued to the provided method.

            Calling the API endpoint will throw an exception,
            therefore the request will fail.

            Use via:

            ----
            interface API { void call(); }
            class C : API { void call() { } }
            auto obj = new RemoteAPI!API(...);
            obj.filter!(API.call);
            ----

            To match a specific overload of a method, specify the
            parameters to match against in the call. For example:

            ----
            interface API { void call(int); void call(int, float); }
            class C : API { void call(int) {} void call(int, float) {} }
            auto obj = new RemoteAPI!API(...);
            obj.filter!(API.call, int, float);  // only filters the second overload
            ----

            Params:
              method = the API method for which to filter out requests
              OverloadParams = (optional) the parameters to match against
                  to select an overload. Note that if the method has no other
                  overloads, then even if that method takes parameters and
                  OverloadParams is empty, it will match that method
                  out of convenience.

        ***********************************************************************/

        public void filter (alias method, OverloadParams...) () @trusted
        {
            import std.format;
            import std.traits;
            enum method_name = __traits(identifier, method);

            // return the mangled name of the matching overload
            template getBestMatch (T...)
            {
                static if (is(Parameters!(T[0]) == OverloadParams))
                {
                    enum getBestMatch = T[0].mangleof;
                }
                else static if (T.length > 0)
                {
                    enum getBestMatch = getBestMatch!(T[1 .. $]);
                }
                else
                {
                    static assert(0,
                        format("Couldn't select best overload of '%s' for " ~
                        "parameter types: %s",
                        method_name, OverloadParams.stringof));
                }
            }

            // ensure it's used with API.method, *not* RemoteAPI.method which
            // is an override of API.method. Otherwise mangling won't match!
            // special-case: no other overloads, and parameter list is empty:
            // just select that one API method
            alias Overloads = __traits(getOverloads, API, method_name);
            static if (Overloads.length == 1 && OverloadParams.length == 0)
            {
                immutable pretty = method_name ~ Parameters!(Overloads[0]).stringof;
                enum mangled = Overloads[0].mangleof;
            }
            else
            {
                immutable pretty = format("%s%s", method_name, OverloadParams.stringof);
                enum mangled = getBestMatch!Overloads;
            }

            this._server_transceiver.send(FilterAPI(mangled, pretty));
        }


        /***********************************************************************

            Clear out any filtering set by a call to filter()

        ***********************************************************************/

        public void clearFilter () @trusted
        {
            this._server_transceiver.send(FilterAPI(""));
        }
    }

    static foreach (member; __traits(allMembers, API))
        static foreach (ovrld; __traits(getOverloads, API, member))
        {
            mixin(q{
                override ReturnType!(ovrld) } ~ member ~ q{ (Parameters!ovrld params)
                {
                    auto serialized = ArgWrapper!(Parameters!ovrld)(params)
                        .serializeToJsonString();

                    auto res = this._client.router(this._server_transceiver, ovrld.mangleof, serialized);

                    if (res.status == Status.Failed)
                        throw new Exception(res.data);

                    if (res.status == Status.Timeout)
                        throw new Exception(serializeToJsonString("Request timed-out"));

                    static if (!is(ReturnType!(ovrld) == void))
                        return res.data.deserializeJson!(typeof(return));
                }
            });
        }
}

/// Simple usage example
unittest
{
    static interface API
    {
        @safe:
        public @property ulong pubkey ();
        public Json getValue (ulong idx);
        public Json getQuorumSet ();
        public string recv (Json data);
    }

    static class MockAPI : API
    {
        @safe:
        public override @property ulong pubkey ()
        { return 42; }
        public override Json getValue (ulong idx)
        { assert(0); }
        public override Json getQuorumSet ()
        { assert(0); }
        public override string recv (Json data)
        { assert(0); }
    }

    scope test = RemoteAPI!API.spawn!MockAPI();
    assert(test.pubkey() == 42);
    test.ctrl.shutdown();
}
/*
/// In a real world usage, users will most likely need to use the registry
unittest
{
    import std.conv;
    static import geod24.concurrency;
    import geod24.Registry;

    __gshared Registry registry;
    registry.initialize();

    static interface API
    {
        @safe:
        public @property ulong pubkey ();
        public Json getValue (ulong idx);
        public string recv (Json data);
        public string recv (ulong index, Json data);

        public string last ();
    }

    static class Node : API
    {
        @safe:
        public this (bool isByzantine) { this.isByzantine = isByzantine; }
        public override @property ulong pubkey ()
        { lastCall = `pubkey`; return this.isByzantine ? 0 : 42; }
        public override Json getValue (ulong idx)
        { lastCall = `getValue`; return Json.init; }
        public override string recv (Json data)
        { lastCall = `recv@1`; return null; }
        public override string recv (ulong index, Json data)
        { lastCall = `recv@2`; return null; }

        public override string last () { return this.lastCall; }

        private bool isByzantine;
        private string lastCall;
    }

    static RemoteAPI!API factory (string type, ulong hash)
    {
        const name = hash.to!string;
        auto tid = registry.locate(name);
        if (tid != tid.init)
            return new RemoteAPI!API(tid);

        switch (type)
        {
        case "normal":
            auto ret =  RemoteAPI!API.spawn!Node(false);
            registry.register(name, ret.tid());
            return ret;
        case "byzantine":
            auto ret =  RemoteAPI!API.spawn!Node(true);
            registry.register(name, ret.tid());
            return ret;
        default:
            assert(0, type);
        }
    }

    auto node1 = factory("normal", 1);
    auto node2 = factory("byzantine", 2);

    static void testFunc(ITransceiver parent)
    {
        auto node1 = factory("this does not matter", 1);
        auto node2 = factory("neither does this", 2);
        assert(node1.pubkey() == 42);
        assert(node1.last() == "pubkey");
        assert(node2.pubkey() == 0);
        assert(node2.last() == "pubkey");

        node1.recv(42, Json.init);
        assert(node1.last() == "recv@2");
        node1.recv(Json.init);
        assert(node1.last() == "recv@1");
        assert(node2.last() == "pubkey");
        node1.ctrl.shutdown();
        node2.ctrl.shutdown();
        geod24.concurrency.send(parent, 42);
    }

    auto testerFiber = geod24.concurrency.spawn(&testFunc, geod24.concurrency.thisTid);
    // Make sure our main thread terminates after everyone else
    geod24.concurrency.receiveOnly!int();
}
*/