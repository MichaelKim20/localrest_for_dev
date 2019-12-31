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

    Author:         Mathias 'Geod24' Lang
    License:        MIT (See LICENSE.txt)
    Copyright:      Copyright (c) 2018-2019 Mathias Lang. All rights reserved.

*******************************************************************************/

module geod24.test.LocalRest;

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
    /// ITransceiver of the sender thread
    ITransceiver sender;
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

    /// Request succeeded
    Success
};

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
};

/// Simple wrapper to deal with tuples
/// Vibe.d might emit a pragma(msg) when T.length == 0
private struct ArgWrapper (T...)
{
    static if (T.length == 0)
        size_t dummy;
    T args;
}

/// Filter out requests before they reach a node
private struct FilterAPI
{
    /// the mangled symbol name of the function to filter
    string func_mangleof;

    /// used for debugging
    string pretty_func;
}

/// Receve request and respanse
private interface ITransceiver
{
    void send (Request msg);
    void send (Response msg);
}

/// Receive request
private class ServerTransceiver : ITransceiver
{
    public Channel!Request  req;

    public this ()
    {
        req = new Channel!Request();
    }

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "STR(%x:0)", cast(void*) req);
    }

    public void send (Request msg)
    {
        if (thisScheduler !is null)
            this.req.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.req.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }

    public void send (Response msg)
    {
    }

    public void close ()
    {
        this.req.close();
    }
}

/// Receive response
private class ClientTransceiver : ITransceiver
{
    public Channel!Response res;

    public this ()
    {
        res = new Channel!Response();
    }

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "CTR(0:%x)", cast(void*) res);
    }

    public void send (Request msg)
    {
    }

    public void send (Response msg)
    {
        if (thisScheduler !is null)
            this.res.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.res.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }

    public void close ()
    {
        this.res.close();
    }
}

/// It's a class to wait for a response.
private class WaitManager
{
    /// Just a FiberCondition with a state
    struct Waiting
    {
        Condition c;
        bool busy;
    }

    /// The 'Response' we are currently processing, if any
    public Response pending;

    /// Request IDs waiting for a response
    public Waiting[ulong] waiting;

    /// Get the next available request ID
    public size_t getNextResponseId ()
    {
        static size_t last_idx;
        return last_idx++;
    }

    /// Wait for a response.
    public Response waitResponse (size_t id, Duration duration)
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

    /// Called when a waiting condition was handled and can be safely removed
    public void remove (size_t id)
    {
        this.waiting.remove(id);
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

/// Receive requests, To obtain and return results by passing
/// them to an instance of the Node.
private class Server (API)
{
    public static Server!API spawn (Implementation) (CtorParams!Implementation args)
    {
        auto res = spawned!Implementation(args);
        return new Server(res);
    }

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

                        auto args = req.args.deserializeJson!(ArgWrapper!(Parameters!ovrld));

                        static if (!is(ReturnType!ovrld == void))
                        {
                            auto res = Response(Status.Success, req.id, node.%1$s(args.args).serializeToJsonString());
                            req.sender.send(res);
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

    private static ServerTransceiver spawned (Implementation) (CtorParams!Implementation cargs)
    {
        import std.datetime.systime : Clock, SysTime;
        import std.algorithm : each;
        import std.range;

        ServerTransceiver transceiver = new ServerTransceiver();
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

            auto fiber_scheduler = new FiberScheduler();
            fiber_scheduler.start({
                bool terminate = false;
                thisScheduler.spawn({
                    while (!terminate)
                    {
                        Request req = transceiver.req.receive();

                        if (req.method == "shutdown@command")
                            terminate = true;

                        if (terminate)
                            break;

                        thisScheduler.spawn({
                            Server!(API).handleRequest(req, node, control.filter);
                        });
                    }
                });
            });
        });

        return transceiver;
    }

    /// Where to send message to
    private ServerTransceiver trsrecv;

    /// Timeout to use when issuing requests
    private const Duration timeout;

    public this (ServerTransceiver transceiver, Duration timeout = Duration.init)
    {
        this.trsrecv = transceiver;
        this.timeout = timeout;
    }

    @property public ServerTransceiver transceiver ()
    {
        return this.trsrecv;
    }

    public void shutdown ()
    {
        this.transceiver.send(Request(null, 0, "shutdown@command", ""));
        this.transceiver.close();
    }
}

/// Request to the `Server`, receive a response
private class Client
{
    /// Where to send message to
    private ClientTransceiver trsrecv;
    private WaitManager wait_manager;
    /// Timeout to use when issuing requests
    private const Duration timeout;
    private shared(bool) terminate;

    public this (Duration timeout = Duration.init)
    {
        this.trsrecv = new ClientTransceiver;
        this.timeout = timeout;
        this.wait_manager = new WaitManager();
    }

    @property public ClientTransceiver transceiver ()
    {
        return this.trsrecv;
    }

    public void query (ServerTransceiver remote, ref Request req, ref Response res)
    {
        res = () @trusted
        {
            this.terminate = false;

            if (thisScheduler is null)
                thisScheduler = new FiberScheduler();

            Condition cond = thisScheduler.newCondition(null);
            thisScheduler.spawn({
                remote.send(req);
                while (!this.terminate)
                {
                    Response res = this.transceiver.res.receive();

                    if (this.terminate)
                        break;

                    while (!(res.id in this.wait_manager.waiting))
                        cond.wait(1.msecs);

                    this.wait_manager.pending = res;
                    this.wait_manager.waiting[res.id].c.notify();
                    this.wait_manager.remove(res.id);
                }
            });

            Response val;
            thisScheduler.start({
                val = this.wait_manager.waitResponse(req.id, this.timeout);
                this.terminate = true;
            });
            return val;
        }();
    }

    public void shutdown ()
    {
        this.terminate = true;
        this.transceiver.close();
    }

    public size_t getNextResponseId ()
    {
        return this.wait_manager.getNextResponseId();
    }
}

///
public class RemoteAPI (API) : API
{
    public static RemoteAPI!(API) spawn (Implementation) (CtorParams!Implementation args)
    {
        auto server = Server!API.spawn!Implementation(args);
        return new RemoteAPI(server.transceiver);
    }

    private ServerTransceiver trsrecv;
    private Server!API server;
    private Client client;

    public this (Server!API sv, Duration timeout = Duration.init)
    {
        this.server = sv;
        this.trsrecv = this.server.transceiver;
        this.client = new Client(timeout);
    }

    public this (ServerTransceiver trsrecv, Duration timeout = Duration.init)
    {
        this.server = null;
        this.trsrecv = trsrecv;
        this.client = new Client(timeout);
    }

    @property public ServerTransceiver transceiver ()
    {
        return this.trsrecv;
    }

    public void shutdown () @trusted
    {
        this.transceiver.send(Request(null, 0, "shutdown@command", ""));
        this.transceiver.close();
        this.client.shutdown();
    }

    static foreach (member; __traits(allMembers, API))
        static foreach (ovrld; __traits(getOverloads, API, member))
        {
            mixin(q{
                override ReturnType!(ovrld) } ~ member ~ q{ (Parameters!ovrld params)
                {
                    auto serialized = ArgWrapper!(Parameters!ovrld)(params)
                        .serializeToJsonString();

                    auto req = Request(this.client.transceiver, this.client.getNextResponseId(), ovrld.mangleof, serialized);
                    Response res;
                    this.client.query(this.transceiver, req, res);

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
        public @property ulong getValue ();
    }

    static class MyAPI : API
    {
        public override @property ulong getValue ()
        { return 42; }
    }

    scope test = RemoteAPI!API.spawn!MyAPI();
    assert(test.getValue() == 42);

    test.shutdown();
}
