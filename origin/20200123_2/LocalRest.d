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

import vibe.data.json;

import std.meta : AliasSeq;
import std.traits : Parameters, ReturnType;

import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time;


/// Data sent by the caller
private struct Request
{
    /// Transceiver of the sender thread
    LocalTransceiver sender;

    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response`
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id;

    /// Method to call
    string method;

    /// Arguments to the method, JSON formatted
    string args;
};


/// Status of a request
private enum Status
{
    /// Request failed
    Failed,

    /// Request timed-out
    Timeout,

    /// Request droped
    Dropped,

    /// Request succeeded
    Success
}


/// Data sent by the callee back to the caller
private struct Response
{
    /// Final status of a request (failed, timeout, success, etc)
    Status status;
    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response` so the scheduler can
    /// properly dispatch this event
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id;
    /// If `status == Status.Success`, the JSON-serialized return value.
    /// Otherwise, it contains `Exception.toString()`.
    string data;
}


/// Filter out requests before they reach a node
private struct FilterAPI
{
    /// the mangled symbol name of the function to filter
    string func_mangleof;

    /// used for debugging
    string pretty_func;
}


/// Ask the node to exhibit a certain behavior for a given time
private struct TimeCommand
{
    /// For how long our remote node apply this behavior
    Duration dur;
    /// Whether or not affected messages should be dropped
    bool drop = false;

    bool send_response_msg = true;
}


/// Ask the node to shut down
private struct ShutdownCommand
{
}


/// Status of a request
private enum MessageType
{
    request,
    response,
    filter,
    time_command,
    shutdown_command
}


// very simple & limited variant, to keep it performant.
// should be replaced by a real Variant later
private struct Message
{
    this (Request msg) { this.req = msg; this.tag = MessageType.request; }
    this (Response msg) { this.res = msg; this.tag = MessageType.response; }
    this (FilterAPI msg) { this.filter = msg; this.tag = MessageType.filter; }
    this (TimeCommand msg) { this.time = msg; this.tag = MessageType.time_command; }
    this (ShutdownCommand msg) { this.shutdown = msg; this.tag = MessageType.shutdown_command; }

    union
    {
        Request req;
        Response res;
        FilterAPI filter;
        TimeCommand time;
        ShutdownCommand shutdown;
    }

    ubyte tag;
}

/*******************************************************************************

    Transceiver device required for message exchange between threads.
    Send and receive data requests, responses, commands, etc.

*******************************************************************************/

private class LocalTransceiver : Transceiver
{

    /// Channel of Request
    public Channel!Message chan;


    /// Ctor
    public this () @safe nothrow
    {
        chan = new Channel!Message(64*1024);
    }


    /***************************************************************************

        It is a function that accepts Message

        Params:
            msg = The message to send.

    ***************************************************************************/

    public void send (T) (T msg) @trusted
    {
        if (is (T == Message))
            this.chan.send(cast(Message)msg);
        else
            this.chan.send(Message(msg));
    }


    /***************************************************************************

        Return the received message.

        Returns:
            A received `Message`

    ***************************************************************************/

    public bool receive (Message *msg) @trusted
    {
        return this.chan.receive(msg);
    }


    /***************************************************************************

        Return the received message.

        Params:
            msg = The `Message` pointer to receive.

        Returns:
            Returns true when message has been received. Otherwise false

    ***************************************************************************/

    public bool tryReceive (Message *msg) @trusted
    {
        return this.chan.tryReceive(msg);
    }


    /***************************************************************************

        Close the `Channel`

    ***************************************************************************/

    override public void close () @trusted
    {
        this.chan.close();
    }


    /***************************************************************************

        Return closing status

        Return:
            true if channel is closed, otherwise false

    ***************************************************************************/

    override public @property bool isClosed () @safe @nogc pure
    {
        return false;
    }


    /***************************************************************************

        Generate a convenient string for identifying this LocalTransceiver.

    ***************************************************************************/

    override public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "TR(%x)", cast(void*) chan);
    }
}

/***************************************************************************

    Getter of LocalTransceiver assigned to a called thread.

    Returns:
        Returns instance of `LocalTransceiver` that is created by top thread.

***************************************************************************/

private @property LocalTransceiver thisLocalTransceiver () nothrow
{
    return cast(LocalTransceiver)thisInfo.transceiver;
}


/***************************************************************************

    Setter of TransceLocalTransceiveriver assigned to a called thread.

    Params:
        value = The instance of `LocalTransceiver`.

***************************************************************************/

private @property void thisLocalTransceiver (LocalTransceiver value) nothrow
{
    thisInfo.transceiver = value;
}


/*******************************************************************************

    After making the request, wait until the response comes,
    and find the response that suits the request.

*******************************************************************************/

private class LocalWaitingManager : WaitingManager
{
    /// Just a Condition with a state
    public struct Waiting
    {
        Condition c;
        bool busy;
    }

    /// Request IDs waiting for a response
    public Waiting[ulong] waiting;

    /// The 'Response' we are currently processing, if any
    public Response pending;

    protected bool stoped;

    /// Ctor
    public this ()
    {
        this.stoped = false;
    }

    /***************************************************************************

        Get the next available request ID

        Returns:
            request ID

    ***************************************************************************/

    public size_t getNextResponseId () @safe nothrow
    {
        static size_t last_idx;
        return last_idx++;
    }


    /***************************************************************************

        Called when a waiting condition was handled and can be safely removed

        Params:
            id = request ID

    ***************************************************************************/

    public void remove (size_t id) @safe nothrow
    {
        this.waiting.remove(id);
    }


    /***************************************************************************

        Check that a value such as the request ID already exists.

        Params:
            id = request ID

        Returns:
            Returns true if a key value equal to id exists.

    ***************************************************************************/

    public bool exist (size_t id) @safe nothrow
    {
        return ((id in this.waiting) !is null);
    }

    /***************************************************************************

        Stop all waiting

    ***************************************************************************/

    public void stop ()
    {
        this.stoped = true;
    }


    /***************************************************************************

        Wait for a response.
        When time out, return the response that means time out.

        Params:
            id = request ID
            duration = Maximum time to wait

        Returns:
            Returns response data.

    ***************************************************************************/

    public Response waitResponse (size_t id, Duration duration) @trusted nothrow
    {
        try
        {
            if (id !in this.waiting)
                this.waiting[id] = Waiting(thisScheduler.newCondition(null), false);

            Waiting* ptr = &this.waiting[id];
            if (ptr.busy)
                assert(0, "Trying to override a pending request");

            ptr.busy = true;

            if (duration == Duration.init)
            {
                while (!this.stoped)
                {
                    if (ptr.c.wait(10.msecs))
                        break;
                }
                if (this.stoped)
                    this.pending = Response(Status.Timeout, id, "");
            }
            else if (!ptr.c.wait(duration))
            {
                import core.time : MonoTime;
                Duration period = duration;
                for (auto limit = MonoTime.currTime + period;
                    !period.isNegative && !this.stoped;
                    period = limit - MonoTime.currTime)
                {
                    if (ptr.c.wait(10.msecs))
                        break;
                }
                if ((period.isNegative) || this.stoped)
                    this.pending = Response(Status.Timeout, id, "");
            }

            ptr.busy = false;

            scope(exit) this.pending = Response.init;
            return this.pending;
        }
        catch (Exception e)
        {
            import std.format;
            assert(0, format("Exception - %s", e.message));
        }
    }
}

/***************************************************************************

    Getter of WaitingManager assigned to a called thread.

***************************************************************************/

private @property LocalWaitingManager thisLocalWaitingManager () nothrow
{
    return cast(LocalWaitingManager)thisInfo.wmanager;
}


/***************************************************************************

    Setter of WaitingManager assigned to a called thread.

***************************************************************************/

private @property void thisLocalWaitingManager (LocalWaitingManager value) nothrow
{
    thisInfo.wmanager = value;
}


/// Simple wrapper to deal with tuples
/// Vibe.d might emit a pragma(msg) when T.length == 0
private struct ArgWrapper (T...)
{
    static if (T.length == 0)
        size_t dummy;
    T args;
}

/// Helper template to get the constructor's parameters
private static template CtorParams (Impl)
{
    static if (is(typeof(Impl.__ctor)))
        private alias CtorParams = Parameters!(Impl.__ctor);
    else
        private alias CtorParams = AliasSeq!();
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

    A reference to an alread-instantiated node

    This class serves the same purpose as a `RestInterfaceClient`:
    it is a client for an already instantiated rest `API` interface.

    In order to instantiate a new server (in a remote thread), use the static
    `spawn` function.

    Params:
      API = The interface defining the API to implement

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
        auto transceiver = spawned!Impl(args);
        return new RemoteAPI(transceiver, timeout);
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
        which is a struct with the sender's LocalTransceiver, the method's mangleof,
        and the method's arguments as a tuple, serialized to a JSON string.

        Params:
            Implementation = Type of the implementation to instantiate
            args = Arguments to `Implementation`'s constructor

    ***************************************************************************/

    private static LocalTransceiver spawned (Implementation) (CtorParams!Implementation cargs)
    {
        import std.container;
        import std.datetime.systime : Clock, SysTime;
        import std.algorithm : each;
        import std.range;

        LocalTransceiver transceiver;

        // used for controling filtering / sleep
        struct Control
        {
            FilterAPI filter;        // filter specific messages
            SysTime sleep_until;     // sleep until this time
            bool drop;               // drop messages if sleeping
            bool send_response_msg;  // send drop message
        }

        bool started = false;

        auto thread_scheduler = new ThreadScheduler();
        thread_scheduler.spawn({
            Message msg;
            auto node = new Implementation(cargs);
            Control control;
            Request[] await_req;
            Response[] await_res;
            Request[] await_drop_req;
            bool terminate = false;

            thisScheduler.start({
                thisLocalTransceiver = new LocalTransceiver();
                thisLocalWaitingManager = new LocalWaitingManager();
                thisInfo.tag = 1;
                transceiver = thisLocalTransceiver;

                started = true;

                bool isSleeping ()
                {
                    return control.sleep_until != SysTime.init
                        && Clock.currTime < control.sleep_until;
                }

                void handleReq (Request req)
                {
                    thisScheduler.spawn({
                        handleRequest(req, node, control.filter);
                    });
                }

                void handleDropReq (Request req)
                {
                    thisScheduler.spawn({
                        req.sender.send(Response(Status.Dropped, req.id));
                    });
                }

                void handleRes (Response res)
                {
                    thisLocalWaitingManager.pending = res;
                    thisLocalWaitingManager.waiting[res.id].c.notify();
                    thisLocalWaitingManager.remove(res.id);
                }

                while (!terminate)
                {
                    if (thisLocalTransceiver.tryReceive(&msg))
                    {
                        switch (msg.tag)
                        {
                            case MessageType.request :
                                if (!isSleeping())
                                    handleReq(msg.req);
                                else if (!control.drop)
                                    await_req ~= msg.req;
                                else if (control.send_response_msg)
                                    await_drop_req ~= msg.req;
                                break;

                            case MessageType.response :
                                auto c = thisScheduler.newCondition(null);
                                foreach (_; 0..10)
                                {
                                    if (thisLocalWaitingManager.exist(msg.res.id))
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
                                control.send_response_msg = msg.time.send_response_msg;
                                break;

                            case MessageType.shutdown_command :
                                thisLocalWaitingManager.stop();
                                thisLocalTransceiver.close();
                                terminate = true;
                                throw new OwnerTerminate();

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

                        if (await_drop_req.length > 0)
                        {
                            await_drop_req.each!(req => handleDropReq(req));
                            await_drop_req.length = 0;
                            assumeSafeAppend(await_drop_req);
                        }
                    }

                    if (thisScheduler !is null)
                        thisScheduler.yield();
                }
            }, 16 * 1024 * 1024);
        });

        //  Wait for the node to be created.
        while (!started)
            Thread.sleep(1.msecs);

        return transceiver;
    }

    /// A device that can requests.
    private LocalTransceiver _transceiver;


    /// Timeout to use when issuing requests
    private Duration _timeout;


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

    public this (Transceiver transceiver, Duration timeout = Duration.init) @nogc pure nothrow
    {
        this._transceiver = cast(LocalTransceiver)transceiver;
        this._timeout = timeout;
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

            Returns the `LocalTransceiver`

        ***********************************************************************/

        @property public LocalTransceiver transceiver () @safe nothrow
        {
            return this._transceiver;
        }


        /***********************************************************************

            Send an async message to the thread to immediately shut down.

        ***********************************************************************/

        public void shutdown () @trusted
        {
            this._transceiver.send(ShutdownCommand());
        }


        /***********************************************************************

            Make the remote node sleep for `Duration`

            The remote node will call `Thread.sleep`, becoming completely
            unresponsive, potentially having multiple tasks hanging.
            This is useful to simulate a delay or a network outage.

            Params:
              delay = Duration the node will sleep for
              drop = Whether to process the pending requests when the
                    node come back online (the default), or to drop
                    pending traffic
              send_drop_msg = Responds that the message was dropped.

        ***********************************************************************/

        public void sleep (Duration d, bool drop = false, bool send_response_msg = true) @trusted
        {
            this._transceiver.send(TimeCommand(d, drop, send_response_msg));
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

            this._transceiver.send(FilterAPI(mangled, pretty));
        }


        /***********************************************************************

            Clear out any filtering set by a call to filter()

        ***********************************************************************/

        public void clearFilter () @trusted
        {
            this._transceiver.send(FilterAPI(""));
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

                    auto res = () @trusted
                    {
                        Request req;
                        Response res;

                        // from Node to Node
                        if (thisInfo.tag == 1)
                        {
                            req = Request(thisLocalTransceiver, thisLocalWaitingManager.getNextResponseId(), ovrld.mangleof, serialized);
                            this._transceiver.send(req);

                            res = thisLocalWaitingManager.waitResponse(req.id, this._timeout);
                        }

                        // from Non-Node to Node
                        else
                        {
                            if (thisScheduler is null)
                                thisScheduler = new FiberScheduler();

                            if (thisLocalWaitingManager is null)
                                thisLocalWaitingManager = new LocalWaitingManager();

                            if (thisLocalTransceiver is null)
                                thisLocalTransceiver = new LocalTransceiver();

                            bool terminated = false;
                            req = Request(thisLocalTransceiver, thisLocalWaitingManager.getNextResponseId(), ovrld.mangleof, serialized);

                            thisScheduler.spawn({
                                this._transceiver.send(req);
                            });

                            thisScheduler.spawn({
                                Message msg;
                                while (!terminated)
                                {
                                    if (thisLocalTransceiver.tryReceive(&msg))
                                    {
                                        scope c = thisScheduler.newCondition(null);
                                        foreach (_; 0..10)
                                        {
                                            if (thisLocalWaitingManager.exist(msg.res.id))
                                                break;
                                            thisScheduler.wait(c, 1.msecs);
                                        }

                                        if (thisLocalWaitingManager.exist(msg.res.id))
                                        {
                                            thisLocalWaitingManager.pending = msg.res;
                                            thisLocalWaitingManager.waiting[msg.res.id].c.notify();
                                            thisLocalWaitingManager.remove(res.id);
                                        }

                                        if (msg.res.id == req.id)
                                            break;
                                    }
                                    thisScheduler.yield();
                                }
                            });

                            thisScheduler.start({
                                res = thisLocalWaitingManager.waitResponse(req.id, this._timeout);
                                terminated = true;
                            });
                        }
                        return res;
                    } ();

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
/*
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

    thread_joinAll();
}

/// In a real world usage, users will most likely need to use the registry
unittest
{
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
            registry.register(name, ret.ctrl.transceiver);
            return ret;
        case "byzantine":
            auto ret =  RemoteAPI!API.spawn!Node(true);
            registry.register(name, ret.ctrl.transceiver);
            return ret;
        default:
            assert(0, type);
        }
    }

    auto node1 = factory("normal", 1);
    auto node2 = factory("byzantine", 2);
    auto chan = new Channel!int;

    auto thread_scheduler = new ThreadScheduler();
    thread_scheduler.spawn({
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

    int msg;
    bool result = chan.receive(&msg);

    node1.ctrl.shutdown();
    node2.ctrl.shutdown();

    thread_joinAll();
}

/// This network have different types of nodes in it
unittest
{
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

    thread_joinAll();
}

/// Support for circular nodes call
unittest
{
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
        tbn[format("node%d", idx)] = api.ctrl.transceiver;
    nodes[0].setNext("node1");
    nodes[1].setNext("node2");
    nodes[2].setNext("node0");

    // 7 level of re-entrancy
    assert(210 == nodes[0].call(20, 0));

    import std.algorithm;
    nodes.each!(node => node.ctrl.shutdown());

    thread_joinAll();
}

/// Nodes can start tasks
unittest
{
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

    thread_joinAll();
}

// Sane name insurance policy
unittest
{
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

    thread_joinAll();
}

// Simulate temporary outage
unittest
{
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

    auto n1 = RemoteAPI!API.spawn!Node();
    n1transceive = n1.ctrl.transceiver;
    auto n2 = RemoteAPI!API.spawn!Node();

    /// Make sure calls are *relatively* efficient
    auto current1 = MonoTime.currTime();
    assert(1 == n1.call());
    assert(1 == n2.call());
    auto current2 = MonoTime.currTime();
    assert(current2 - current1 < 200.msecs);

    // Make one of the node sleep
    n1.sleep(1.seconds);
    // Make sure our main thread is not suspended,
    // nor is the second node
    assert(2 == n2.call());
    auto current3 = MonoTime.currTime();
    assert(current3 - current2 < 400.msecs);

    // Wait for n1 to unblock
    assert(2 == n1.call());
    // Check current time >= 1 second
    auto current4 = MonoTime.currTime();
    assert(current4 - current2 >= 1.seconds);

    // Now drop many messages
    n1.sleep(1.seconds, true, true);
    for (size_t i = 0; i < 10; i++)
        n2.asyncCall();
    // Make sure we don't end up blocked forever
    Thread.sleep(1.seconds);
    assert(3 == n1.call());
    Thread.sleep(1.seconds);

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

    thread_joinAll();
}

// Filter commands
unittest
{
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

    thread_joinAll();
}

// request timeouts (from main thread)
unittest
{
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

    thread_joinAll();
}

// test-case for responses to re-used requests (from main thread)
unittest
{
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

    thread_joinAll();
}

// request timeouts (foreign node to another node)
unittest
{
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

    thread_joinAll();
}

// test-case for zombie responses
unittest
{
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

    thread_joinAll();
}

// request timeouts with dropped messages
unittest
{
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
            node.ctrl.sleep(10.msecs, true, false);
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

    thread_joinAll();
}

// Test a node that gets a replay while it's delayed
unittest
{
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

    thread_joinAll();
}

// Test explicit shutdown
unittest
{
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

    thread_joinAll();
}
*/

import std.stdio;

// Simulate temporary outage
unittest
{
    writefln("test07, B");
    __gshared LocalTransceiver n1transceive;

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

    auto n1 = RemoteAPI!API.spawn!Node();
    n1transceive = n1.ctrl.transceiver;
    auto n2 = RemoteAPI!API.spawn!Node();

    writefln("test07, 1");
    /// Make sure calls are *relatively* efficient
    auto current1 = MonoTime.currTime();
    assert(1 == n1.call());
    assert(1 == n2.call());
    auto current2 = MonoTime.currTime();
    assert(current2 - current1 < 200.msecs);

    writefln("test07, 2");
    // Make one of the node sleep
    n1.sleep(1.seconds);
    // Make sure our main thread is not suspended,
    // nor is the second node
    assert(2 == n2.call());
    auto current3 = MonoTime.currTime();
    assert(current3 - current2 < 400.msecs);

    writefln("test07, 3");
    // Wait for n1 to unblock
    assert(2 == n1.call());
    // Check current time >= 1 second
    auto current4 = MonoTime.currTime();
    assert(current4 - current2 >= 1.seconds);

    writefln("test07, 4");
    // Now drop many messages
    n1.sleep(1.seconds, true, true);
    for (size_t i = 0; i < 10; i++)
        n2.asyncCall();
    // Make sure we don't end up blocked forever
    Thread.sleep(3000.msecs);
    assert(3 == n1.call());

    writefln("test07, 5");
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

    thread_joinAll();
}
