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
    to the Transceiver. Messages consist of the sender's Transceiver, the mangled name
    of the function to call (to support overloading) and the arguments,
    serialized as a JSON string.

    Note:
    While this module's original motivation was to test REST nodes,
    the only dependency to Vibe.d is actually to it's JSON module,
    as Vibe.d is the only available JSON module known to the author
    to provide an interface to deserialize composite types.

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

import std.stdio;

/// Simple wrapper to deal with tuples
/// Vibe.d might emit a pragma(msg) when T.length == 0
private struct ArgWrapper (T...)
{
    static if (T.length == 0)
        size_t dummy;
    T args;
}

/*******************************************************************************

    After making the request, wait until the response comes,
    and find the response that suits the request.

*******************************************************************************/

private class WaitingManager : InfoObject
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

    ///
    public void cleanup (bool root)
    {
        foreach (k; this.waiting.keys)
        {
            this.waiting[k].c.notify();
        }
        this.waiting.clear();
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
    thisInfo.objectValues["WaitingManager"] = cast(InfoObject)value;
}


public class ThreadInfoEx : InfoObject
{
    public bool is_node;

    this (bool value)
    {
        this.is_node = value;
    }

    public void cleanup (bool root)
    {
    }
}

/***************************************************************************

    Getter of WaitingManager assigned to a called thread.

***************************************************************************/

public @property ThreadInfoEx thisThreadInfoEx () nothrow
{
    if (auto p = "ThreadInfoEx" in thisInfo.objectValues)
        return cast(ThreadInfoEx)(*p);
    else
        return null;
}


/***************************************************************************

    Setter of WaitingManager assigned to a called thread.

***************************************************************************/

public @property void thisThreadInfoEx (ThreadInfoEx value) nothrow
{
    thisInfo.objectValues["ThreadInfoEx"] = cast(InfoObject)value;
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
        In practice, this means there should only be one `Transceiver`
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
        which is a struct with the sender's Transceiver, the method's mangleof,
        and the method's arguments as a tuple, serialized to a JSON string.

        Params:
            Implementation = Type of the implementation to instantiate
            args = Arguments to `Implementation`'s constructor

    ***************************************************************************/

    private static Transceiver spawned (Implementation) (CtorParams!Implementation cargs)
    {
        import std.datetime.systime : Clock, SysTime;
        import std.algorithm : each;
        import std.range;
        import core.atomic : atomicOp, atomicLoad;

        Transceiver transceiver;
        Request[] await_req;
        Response[] await_res;
        ThreadScheduler thread_scheduler;

        // used for controling filtering / sleep
        struct Control
        {
            FilterAPI filter;    // filter specific messages
            SysTime sleep_until; // sleep until this time
            bool drop;           // drop messages if sleeping
        }

        shared(int) started = 0;

        thread_scheduler = new ThreadScheduler();
        thread_scheduler.spawn({
            scope node = new Implementation(cargs);

            Control control;

            bool isSleeping ()
            {
                return control.sleep_until != SysTime.init
                    && Clock.currTime < control.sleep_until;
            }

            void handleReq (Request req)
            {
                thisScheduler.spawn(() {
                    handleRequest(req, node, control.filter);
                });
            }

            void handleRes (Response res)
            {
                thisWaitingManager.pending = res;
                thisWaitingManager.waiting[res.id].c.notify();
                thisWaitingManager.remove(res.id);
            }

            thisScheduler.start({
                thisTransceiver = new Transceiver();
                thisWaitingManager = new WaitingManager();
                thisThreadInfoEx = new ThreadInfoEx(true);
                transceiver = thisTransceiver;

                started.atomicOp!"+="(1);

                bool terminate = false;

                while (!terminate)
                {
                    Message msg;
                    if (thisTransceiver.tryReceive(&msg))
                    {
                        switch (msg.tag)
                        {
                            case MessageType.request :
                                if (!isSleeping())
                                    handleReq(msg.req);
                                else if (!control.drop)
                                    await_req ~= msg.req;
                                break;

                            case MessageType.response :
                                scope c = thisScheduler.newCondition(null);
                                foreach (_; 0..10)
                                {
                                    if (thisWaitingManager.exist(msg.res.id))
                                        break;
                                    thisScheduler.wait(c, 10.msecs);
                                }
                                if (!isSleeping())
                                    handleRes(msg.res);
                                else if (!control.drop)
                                    await_res ~= msg.res;
                                break;

                            case MessageType.filter :
                                control.filter = msg.filter;
                                break;

                            case MessageType.time_command :
                                control.sleep_until = Clock.currTime + msg.time.dur;
                                control.drop = msg.time.drop;
                                break;

                            case MessageType.shutdown_command :
                                terminate = true;
                                break;

                            default :
                                assert(0, "Unexpected type: " ~ msg.tag);
                        }
                    }
                    if (thisScheduler !is null)
                        thisScheduler.yield();

                    if (!isSleeping())
                    {
                        if (await_req.length > 0)
                        {
                            await_req.each!(req => handleReq(req));
                            await_req.length = 0;
                            assumeSafeAppend(await_req);
                        }

                        if (await_res.length > 0)
                        {
                            await_res.each!(res => handleRes(res));
                            await_res.length = 0;
                            assumeSafeAppend(await_res);
                        }
                    }
                    if (thisScheduler !is null)
                        thisScheduler.yield();
                }
            }, 32 * 1024 * 1024);
        });

        //  Wait for the node to be created.
        while (!atomicLoad(started))
            Thread.sleep(1.msecs);

        return transceiver;
    }

    /// Devices that can receive requests.
    private Transceiver _transceiver;


    /***************************************************************************

        Create an instante of a `Server`

        Params:
            transceiver = This is an instance of `Transceiver` and
                a device that can receive requests.

    ***************************************************************************/

    public this (Transceiver transceiver) @nogc pure nothrow
    {
        this._transceiver = transceiver;
    }


    /***************************************************************************

        Returns the `Transceiver`

        This can be useful for calling `geod24.concurrency.register` or similar.
        Note that the `Transceiver` should not be used directly,
        as our event loop, would error out on an unknown message.

    ***************************************************************************/

    @property public Transceiver transceiver () @safe nothrow
    {
        return this._transceiver;
    }


    /***************************************************************************

        Send an async message to the thread to immediately shut down.

    ***************************************************************************/

    public void shutdown () @trusted
    {
        this._transceiver.send(ShutdownCommand());
        this._transceiver.close();
    }
}


/*******************************************************************************

    Request to the `Server`, receive a response

*******************************************************************************/

private class Client
{
    /// Devices that can receive a response
    private Transceiver _transceiver;

    /// After making the request, wait until the response comes,
    /// and find the response that suits the request.
    private WaitingManager _waitingManager;

    /// Timeout to use when issuing requests
    private Duration _timeout;

    ///
    private bool _terminate;

    private bool _has_server;

    /// Ctor
    public this (Duration timeout = Duration.init, bool has_server = false) @safe nothrow
    {
        this._transceiver = new Transceiver;
        this._waitingManager = new WaitingManager();
        this._timeout = timeout;
        this._has_server = has_server;
    }


    /***************************************************************************

        Returns client's Transceiver.
        It accept only `Response`.

        Returns:
            Client's Transceiver

    ***************************************************************************/

    @property public Transceiver transceiver () @safe nothrow
    {
        return this._transceiver;
    }


    /***************************************************************************

        This enables appropriate responses to requests through the API

        Params:
           remote = Instance of Transceiver
           req = `Request`
           res = `Response`

    ***************************************************************************/

    public Response router (Transceiver remote, string method, string args) @trusted
    {
        Request req;
        Response res;

        // from Node to Node
        if ((thisThreadInfoEx !is null) && (thisThreadInfoEx.is_node))
        {
            writefln("router 1");
            req = Request(thisTransceiver, thisWaitingManager.getNextResponseId(), method, args);
            remote.send(req);
            res = thisWaitingManager.waitResponse(req.id, this._timeout);
        }
        // from Non-Node to Node
        else
        {
            writefln("router 3 %s", thread_isMainThread());
            if (thisScheduler is null)
                thisScheduler = new FiberScheduler();

            this._terminate = false;
            thisScheduler.spawn({
                req = Request(this.transceiver, this._waitingManager.getNextResponseId(), method, args);
                remote.send(req);
            });

            thisScheduler.spawn({
                while (!this._terminate)
                {
                    Message msg = this._transceiver.receive();

                    if (this._terminate)
                        break;

                    foreach (_; 0..10)
                    {
                        if (this._waitingManager.exist(msg.res.id))
                            break;
                        if (thisScheduler !is null)
                        {
                            auto c = thisScheduler.newCondition(null);
                            thisScheduler.wait(c, 1.msecs);
                        }
                    }

                    this._waitingManager.pending = msg.res;
                    this._waitingManager.waiting[msg.res.id].c.notify();
                }
            });

            bool done = false;
            thisScheduler.start({
                res = this._waitingManager.waitResponse(req.id, this._timeout);
                this._terminate = true;
                done = true;
            });
            while (!done) thisScheduler.yield();
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
        this._waitingManager.cleanup(true);
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

public void runTask (void delegate() dg)
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
        In practice, this means there should only be one `Transceiver`
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

    public static RemoteAPI!(API) spawn (Impl) (CtorParams!Impl args,
        Duration timeout = Duration.init)
    {
        auto server = Server!API.spawn!Impl(args);
        return new RemoteAPI(server.transceiver, timeout, true);
    }

    /// A device that can requests.
    private Transceiver _server_transceiver;

    /// Request to the `Server`, receive a response
    private Client _client;

    /// Timeout to use when issuing requests
    private Duration _timeout;


    private bool _has_server;


    // Vibe.d mandates that method must be @safe
    @safe:


    /***************************************************************************

        Create an instante of a client

        This connects to an already instantiated node.
        In order to instantiate a node, see the static `spawn` function.

        Params:
            transceiver = `Transceiver` of the node.
            timeout = any timeout to use

    ***************************************************************************/

    public this (Transceiver transceiver, Duration timeout = Duration.init, bool has_server = false) @safe nothrow
    {
        this._server_transceiver = transceiver;
        this._timeout = timeout;
        this._has_server = has_server;
        this._client = new Client(timeout, has_server);
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

            Returns the `Transceiver`

        ***********************************************************************/

        @property public Transceiver transceiver () @safe nothrow
        {
            return this._server_transceiver;
        }


        /***********************************************************************

            Send an async message to the thread to immediately shut down.

        ***********************************************************************/

        public void shutdown () @trusted
        {
            if (this._server_transceiver)
            {
                this._server_transceiver.send(ShutdownCommand());
                this._server_transceiver.close();
            }

            if (this._client)
                this._client.shutdown();
        }


        public void shutdownClient () @trusted
        {
            if (this._client)
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

                    //writefln("API _has_server %s", _has_server);

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

import std.stdio;

/// Simple usage example
unittest
{
    writefln("test01, B");
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

    cleanupMainThread();
    writefln("test01");
}

/// In a real world usage, users will most likely need to use the registry
unittest
{
    writefln("test02, B");
    import std.conv;
    import geod24.concurrency;
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
        auto transceiver = registry.locate(name);
        if (transceiver !is null)
            return new RemoteAPI!API(transceiver);

        switch (type)
        {
        case "normal":
            auto ret =  RemoteAPI!API.spawn!Node(false);
            registry.register(name, ret.transceiver);
            return ret;
        case "byzantine":
            auto ret =  RemoteAPI!API.spawn!Node(true);
            registry.register(name, ret.transceiver);
            return ret;
        default:
            assert(0, type);
        }
    }

    auto node1 = factory("normal", 1);
    auto node2 = factory("byzantine", 2);
    auto chan = new Channel!int;

    auto thrad_scheduler = new ThreadScheduler();
    thrad_scheduler.spawn({
        thisScheduler.start({
            auto node12 = factory("this does not matter", 1);
            auto node22 = factory("neither does this", 2);

            assert(node12.pubkey() == 42);
            assert(node12.last() == "pubkey");
            assert(node22.pubkey() == 0);
            assert(node22.last() == "pubkey");

            node12.recv(42, Json.init);
            assert(node12.last() == "recv@2");
            node12.recv(Json.init);
            assert(node12.last() == "recv@1");
            assert(node22.last() == "pubkey");

            node12.ctrl.shutdown();
            node22.ctrl.shutdown();

            chan.send(1);
        });
    });

    auto res = chan.receive();

    node1.ctrl.shutdown();
    node2.ctrl.shutdown();

    cleanupMainThread();
    writefln("test02");
}
/*
/// This network have different types of nodes in it
unittest
{
    writefln("test03, B");
    import geod24.concurrency;

    static interface API
    {
        @safe:
        public @property ulong requests ();
        public @property ulong value ();
    }

    static class MasterNode : API
    {
        @safe:
        public override @property ulong requests()
        {
            return this.requests_;
        }

        public override @property ulong value()
        {
            this.requests_++;
            return 42; // Of course
        }

        private ulong requests_;
    }

    static class SlaveNode : API
    {
        @safe:
        this(Transceiver masterTransceiver)
        {
            this.master = new RemoteAPI!API(masterTransceiver);
        }

        public override @property ulong requests()
        {
            return this.requests_;
        }

        public override @property ulong value()
        {
            this.requests_++;
            return master.value();
        }

        private API master;
        private ulong requests_;
    }

    RemoteAPI!API[4] nodes;
    auto master = RemoteAPI!API.spawn!MasterNode();
    nodes[0] = master;
    nodes[1] = RemoteAPI!API.spawn!SlaveNode(master.transceiver);
    nodes[2] = RemoteAPI!API.spawn!SlaveNode(master.transceiver);
    nodes[3] = RemoteAPI!API.spawn!SlaveNode(master.transceiver);

    foreach (n; nodes)
    {
        assert(n.requests() == 0);
        assert(n.value() == 42);
    }

    assert(nodes[0].requests() == 4);

    foreach (n; nodes[1 .. $])
    {
        assert(n.value() == 42);
        assert(n.requests() == 2);
    }

    assert(nodes[0].requests() == 7);

    import std.algorithm;
    nodes.each!(node => node.ctrl.shutdown());

    cleanupMainThread();
    writefln("test03");
}

/// Support for circular nodes call
unittest
{
    writefln("test04, B");
    import geod24.concurrency;
    import std.format;

    __gshared Transceiver[string] tbn;

    static interface API
    {
        @safe:
        public ulong call (ulong count, ulong val);
        public void setNext (string name);
    }

    static class Node : API
    {
        @safe:
        public override ulong call (ulong count, ulong val)
        {
            if (!count)
                return val;
            return this.next.call(count - 1, val + count);
        }

        public override void setNext (string name) @trusted
        {
            this.next = new RemoteAPI!API(tbn[name]);
        }

        private API next;
    }

    RemoteAPI!(API)[3] nodes = [
        RemoteAPI!API.spawn!Node(),
        RemoteAPI!API.spawn!Node(),
        RemoteAPI!API.spawn!Node(),
    ];

    foreach (idx, ref api; nodes)
        tbn[format("node%d", idx)] = api.transceiver();
    nodes[0].setNext("node1");
    nodes[1].setNext("node2");
    nodes[2].setNext("node0");

    // 7 level of re-entrancy
    assert(210 == nodes[0].call(20, 0));

    import std.algorithm;
    nodes.each!(node => node.ctrl.shutdown());

    cleanupMainThread();
    writefln("test04");
}
*/
/// Nodes can start tasks
unittest
{
    writefln("test05, B");
    import core.thread;
    import core.time;

    static interface API
    {
        public void start ();
        public void stop ();
        public ulong getCounter ();
    }

    static class Node : API
    {
        public override void start ()
        {
            terminate = false;
            runTask(&this.task);
        }

        public override void stop ()
        {
            terminate = true;
        }

        public override ulong getCounter ()
        {
            scope (exit) this.counter = 0;
            return this.counter;
        }

        private void task ()
        {
            while (!terminate)
            {
                this.counter++;
                sleep(50.msecs);
            }
        }

        private ulong counter;
        private bool terminate;
    }

    import std.format;
    auto node = RemoteAPI!API.spawn!Node();
    assert(node.getCounter() == 0);
    node.start();
    assert(node.getCounter() == 1);
    assert(node.getCounter() == 0);
    core.thread.Thread.sleep(1.seconds);
    // It should be 19 but some machines are very slow
    // (e.g. Travis Mac testers) so be safe
    assert(node.getCounter() >= 9);
    assert(node.getCounter() == 0);
    node.stop();
    core.thread.Thread.sleep(100.msecs);
    node.ctrl.shutdown();
    writefln("test05");

    cleanupMainThread();
}

// Sane name insurance policy
unittest
{
    writefln("test06, B");
    import geod24.Transceiver;

    static interface API
    {
        public ulong transceiver ();
    }

    static class Node : API
    {
        public override ulong transceiver () { return 42; }
    }

    auto node = RemoteAPI!API.spawn!Node();
    assert(node.transceiver == 42);
    assert(node.ctrl.transceiver !is null);
    node.ctrl.shutdown();

    static interface DoesntWork
    {
        public string ctrl ();
    }
    static assert(!is(typeof(RemoteAPI!DoesntWork)));
    writefln("test06");

    cleanupMainThread();
}

// Simulate temporary outage
unittest
{
    writefln("test07, B");
    __gshared Transceiver n1transceive;

    static interface API
    {
        public ulong call ();
        public void asyncCall ();
    }
    static class Node : API
    {
        public this()
        {
            if (n1transceive !is null)
                this.remote = new RemoteAPI!API(n1transceive, 1.seconds);
        }

        public override ulong call () { return ++this.count; }
        public override void  asyncCall () { runTask(() => cast(void)this.remote.call); }
        size_t count;
        RemoteAPI!API remote;
    }

    writefln("test07, 1");
    auto n1 = RemoteAPI!API.spawn!Node();
    n1transceive = n1.ctrl.transceiver;
    auto n2 = RemoteAPI!API.spawn!Node();

    writefln("test07, 2");
    /// Make sure calls are *relatively* efficient
    auto current1 = MonoTime.currTime();
    writefln("test07, 2-1");
    assert(1 == n1.call());
    writefln("test07, 2-2");
    assert(1 == n2.call());
    auto current2 = MonoTime.currTime();
   // assert(current2 - current1 < 200.msecs);

    writefln("test07, 3");
    // Make one of the node sleep
    n1.sleep(1.seconds);
    // Make sure our main thread is not suspended,
    // nor is the second node
    assert(2 == n2.call());
    auto current3 = MonoTime.currTime();
    assert(current3 - current2 < 400.msecs);

    writefln("test07, 4");
    // Wait for n1 to unblock
    assert(2 == n1.call());
    writefln("test07, 4-1");
    // Check current time >= 1
    auto current4 = MonoTime.currTime();
    writefln("test07, 4-2");
    assert(current4 - current2 >= 1.seconds);

    writefln("test07, 5");
    // Now drop many messages
    n1.sleep(1.seconds, true);
    //for (size_t i = 0; i < 100; i++)
        n2.asyncCall();
    // Make sure we don't end up blocked forever
    Thread.sleep(1.seconds);
    //assert(3 == n1.call());

    // Debug output, uncomment if needed
    version (none)
    {
        import std.stdio;
        writeln("Two non-blocking calls: ", current2 - current1);
        writeln("Sleep + non-blocking call: ", current3 - current2);
        writeln("Delta since sleep: ", current4 - current2);
    }

    n1.ctrl.shutdown();
    n2.ctrl.shutdown();
    writefln("test07");

    cleanupMainThread();
}

// Filter commands
unittest
{
    writefln("test08, B");
    __gshared Transceiver node_tid;

    static interface API
    {
        size_t fooCount();
        size_t fooIntCount();
        size_t barCount ();
        void foo ();
        void foo (int);
        void bar (int);  // not in any overload set
        void callBar (int);
        void callFoo ();
        void callFoo (int);
    }

    static class Node : API
    {
        size_t foo_count;
        size_t foo_int_count;
        size_t bar_count;
        RemoteAPI!API remote;

        public this()
        {
            this.remote = new RemoteAPI!API(node_tid);
        }

        override size_t fooCount() { return this.foo_count; }
        override size_t fooIntCount() { return this.foo_int_count; }
        override size_t barCount() { return this.bar_count; }
        override void foo () { ++this.foo_count; }
        override void foo (int) { ++this.foo_int_count; }
        override void bar (int) { ++this.bar_count; }  // not in any overload set
        // This one is part of the overload set of the node, but not of the API
        // It can't be accessed via API and can't be filtered out
        void bar(string) { assert(0); }

        override void callFoo()
        {
            try
            {
                this.remote.foo();
            }
            catch (Exception ex)
            {
                assert(ex.msg == "Filtered method 'foo()'");
            }
        }

        override void callFoo(int arg)
        {
            try
            {
                this.remote.foo(arg);
            }
            catch (Exception ex)
            {
                assert(ex.msg == "Filtered method 'foo(int)'");
            }
        }

        override void callBar(int arg)
        {
            try
            {
                this.remote.bar(arg);
            }
            catch (Exception ex)
            {
                assert(ex.msg == "Filtered method 'bar(int)'");
            }
        }
    }

    auto filtered = RemoteAPI!API.spawn!Node();
    node_tid = filtered.ctrl.transceiver;

    // caller will call filtered
    auto caller = RemoteAPI!API.spawn!Node();
    caller.callFoo();
    assert(filtered.fooCount() == 1);

    // both of these work
    static assert(is(typeof(filtered.ctrl.filter!(API.foo))));
    static assert(is(typeof(filtered.ctrl.filter!(filtered.foo))));

    // only method in the overload set that takes a parameter,
    // should still match a call to filter with no parameters
    static assert(is(typeof(filtered.ctrl.filter!(filtered.bar))));

    // wrong parameters => fail to compile
    static assert(!is(typeof(filtered.ctrl.filter!(filtered.bar, float))));
    // Only `API` overload sets are considered
    static assert(!is(typeof(filtered.ctrl.filter!(filtered.bar, string))));

    filtered.ctrl.filter!(API.foo);

    caller.callFoo();
    assert(filtered.fooCount() == 1);  // it was not called!

    filtered.clearFilter();  // clear the filter
    caller.callFoo();
    assert(filtered.fooCount() == 2);  // it was called!

    // verify foo(int) works first
    caller.callFoo(1);
    assert(filtered.fooCount() == 2);
    assert(filtered.fooIntCount() == 1);  // first time called

    // now filter only the int overload
    filtered.ctrl.filter!(API.foo, int);

    // make sure the parameterless overload is still not filtered
    caller.callFoo();
    assert(filtered.fooCount() == 3);  // updated

    caller.callFoo(1);
    assert(filtered.fooIntCount() == 1);  // call filtered!

    // not filtered yet
    caller.callBar(1);
    assert(filtered.barCount() == 1);

    filtered.filter!(filtered.bar);
    caller.callBar(1);
    assert(filtered.barCount() == 1);  // filtered!

    // last blocking calls, to ensure the previous calls complete
    filtered.clearFilter();
    caller.foo();
    caller.bar(1);

    filtered.ctrl.shutdown();
    caller.ctrl.shutdown();
    writefln("test08");

    cleanupMainThread();
}

// request timeouts (from main thread)
unittest
{
    writefln("test09, B");
    import core.thread;
    import std.exception;

    static interface API
    {
        size_t sleepFor (long dur);
    }

    static class Node : API
    {
        override size_t sleepFor (long dur)
        {
            Thread.sleep(msecs(dur));
            return 42;
        }
    }

    // node with no timeout
    auto node = RemoteAPI!API.spawn!Node();
    assert(node.sleepFor(80) == 42);  // no timeout

    // node with a configured timeout
    auto to_node = RemoteAPI!API.spawn!Node(500.msecs);

    /// none of these should time out
    assert(to_node.sleepFor(10) == 42);
    assert(to_node.sleepFor(20) == 42);
    assert(to_node.sleepFor(30) == 42);
    assert(to_node.sleepFor(40) == 42);

    assertThrown!Exception(to_node.sleepFor(2000));
    Thread.sleep(2.seconds);  // need to wait for sleep() call to finish before calling .shutdown()
    to_node.ctrl.shutdown();
    node.ctrl.shutdown();
    writefln("test09");

    cleanupMainThread();
}

// test-case for responses to re-used requests (from main thread)
unittest
{
    writefln("test10, B");
    import core.thread;
    import std.exception;

    static interface API
    {
        float getFloat();
        size_t sleepFor (long dur);
    }

    static class Node : API
    {
        override float getFloat() { return 69.69; }
        override size_t sleepFor (long dur)
        {
            Thread.sleep(msecs(dur));
            return 42;
        }
    }

    // node with no timeout
    auto node = RemoteAPI!API.spawn!Node();
    assert(node.sleepFor(80) == 42);  // no timeout

    // node with a configured timeout
    auto to_node = RemoteAPI!API.spawn!Node(500.msecs);

    /// none of these should time out
    assert(to_node.sleepFor(10) == 42);
    assert(to_node.sleepFor(20) == 42);
    assert(to_node.sleepFor(30) == 42);
    assert(to_node.sleepFor(40) == 42);

    assertThrown!Exception(to_node.sleepFor(2000));
    Thread.sleep(2.seconds);  // need to wait for sleep() call to finish before calling .shutdown()

    assert(cast(int)to_node.getFloat() == 69);

    to_node.ctrl.shutdown();
    node.ctrl.shutdown();
    writefln("test10");

    cleanupMainThread();
}

// request timeouts (foreign node to another node)
unittest
{
    writefln("test11, B");
    import geod24.Transceiver;
    import std.exception;

    __gshared Transceiver node_transceiver;

    static interface API
    {
        void check ();
        int ping ();
    }

    static class Node : API
    {
        override int ping () { return 42; }

        override void check ()
        {
            auto node = new RemoteAPI!API(node_transceiver, 500.msecs);

            // no time-out
            node.ctrl.sleep(10.msecs);
            assert(node.ping() == 42);

            // time-out
            node.ctrl.sleep(2000.msecs);
            assertThrown!Exception(node.ping());
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node();
    auto node_2 = RemoteAPI!API.spawn!Node();
    node_transceiver = node_2.ctrl.transceiver;
    node_1.check();
    Thread.sleep(3000.msecs);
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();
    writefln("test11");

    cleanupMainThread();
}

// test-case for zombie responses
unittest
{
    writefln("test12, B");
    import geod24.Transceiver;
    import std.exception;

    __gshared Transceiver node_transceiver;

    static interface API
    {
        void check ();
        int get42 ();
        int get69 ();
    }

    static class Node : API
    {
        override int get42 () { return 42; }
        override int get69 () { return 69; }

        override void check ()
        {
            auto node = new RemoteAPI!API(node_transceiver, 500.msecs);

            // time-out
            node.ctrl.sleep(2000.msecs);
            assertThrown!Exception(node.get42());

            // no time-out
            node.ctrl.sleep(10.msecs);
            assert(node.get69() == 69);
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node();
    auto node_2 = RemoteAPI!API.spawn!Node();
    node_transceiver = node_2.ctrl.transceiver;
    node_1.check();
    Thread.sleep(3000.msecs);
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();
    writefln("test12");

    cleanupMainThread();
}

// request timeouts with dropped messages
unittest
{
    writefln("test13, B");
    import geod24.Transceiver;
    import std.exception;

    __gshared Transceiver node_transceiver;

    static interface API
    {
        void check ();
        int ping ();
    }

    static class Node : API
    {
        override int ping () { return 42; }

        override void check ()
        {
            auto node = new RemoteAPI!API(node_transceiver, 420.msecs);

            // Requests are dropped, so it times out
            assert(node.ping() == 42);
            node.ctrl.sleep(10.msecs, true);
            assertThrown!Exception(node.ping());
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node();
    auto node_2 = RemoteAPI!API.spawn!Node();
    node_transceiver = node_2.ctrl.transceiver;
    node_1.check();
    Thread.sleep(1000.msecs);
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();
    writefln("test13");

    cleanupMainThread();
}

// Test a node that gets a replay while it's delayed
unittest
{
    writefln("test14, B");
    import geod24.Transceiver;
    import std.exception;

    __gshared Transceiver node_transceiver;

    static interface API
    {
        void check ();
        int ping ();
    }

    static class Node : API
    {
        override int ping () { return 42; }

        override void check ()
        {
            auto node = new RemoteAPI!API(node_transceiver, 5000.msecs);
            assert(node.ping() == 42);
            // We need to return immediately so that the main thread
            // puts us to sleep
            runTask(() {
                node.ctrl.sleep(200.msecs);
                assert(node.ping() == 42);
            });
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node(500.msecs);
    auto node_2 = RemoteAPI!API.spawn!Node();
    node_transceiver = node_2.ctrl.transceiver;
    node_1.check();
    node_1.ctrl.sleep(300.msecs);
    assert(node_1.ping() == 42);
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();
    writefln("test14");

    cleanupMainThread();
}

// Test explicit shutdown
unittest
{
    writefln("test15, B");
    import std.exception;

    static interface API
    {
        int myping (int value);
    }

    static class Node : API
    {
        override int myping (int value)
        {
            return value;
        }
    }

    auto node = RemoteAPI!API.spawn!Node(1.seconds);
    assert(node.myping(42) == 42);
    node.ctrl.shutdown();

    try
    {
        node.myping(69);
        assert(0);
    }
    catch (Exception ex)
    {
        assert(ex.msg == `"Request timed-out"`);
    }
    writefln("test15");

    cleanupMainThread();
}
