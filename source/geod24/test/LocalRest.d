module geod24.test.LocalRest;

import geod24.concurrency;

import std.traits : Parameters, ReturnType;

import core.sync.condition;
import core.sync.mutex;
import core.thread;

private struct Request
{
    ITransceiver sender;
    size_t id;
    string method;
    string args;
};

private enum Status
{
    Failed,
    Timeout,
    Success
};

private struct Response
{
    Status status;
    size_t id;
    string data;
};

/// Filter out requests before they reach a node
private struct FilterAPI
{
    /// the mangled symbol name of the function to filter
    string func_mangleof;

    /// used for debugging
    string pretty_func;
}

private interface ITransceiver
{
    void send (Request msg);
    void send (Response msg);
}

private class ServerTransceiver : ITransceiver
{
    public Channel!Request  req;
    public Channel!Response res;

    public this ()
    {
        req = new Channel!Request();
        res = new Channel!Response();
    }

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "STR(%x:%s)", cast(void*) req, cast(void*) res);
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
        this.req.close();
        this.res.close();
    }
}

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

private class Server (API)
{
    public static Server spawn (Implementation) (CtorParams!Implementation args)
    {
        auto res = spawned!Implementation(args);
        return new Server(res);
    }

    /// Helper template to get the constructor's parameters
    private static template CtorParams (Impl)
    {
        static if (is(typeof(Impl.__ctor)))
            private alias CtorParams = Parameters!(Impl.__ctor);
        else
            private alias CtorParams = AliasSeq!();
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
                            req.sender.send(
                                Response(
                                    Status.Success,
                                    req.id,
                                    node.%1$s(args.args).serializeToJsonString()));
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
            assert(0, "Unmatched method name: " ~ cmd.method);
        }
    }

    private static ServerTransceiver spawned (Implementation) (CtorParams!Implementation cargs)
    {
        ServerTransceiver transceiver = new ServerTransceiver();
        scope node = new Implementation(cargs);
        auto thread_scheduler = ThreadScheduler.instance;

        // used for controling filtering / sleep
        struct Control
        {
            FilterAPI filter;    // filter specific messages
            SysTime sleep_until; // sleep until this time
            bool drop;           // drop messages if sleeping
        }

        Control control;

        thread_scheduler.spawn({

            auto fiber_scheduler = new FiberScheduler();
            fiber_scheduler.start({
                this._terminate = false;
                thisScheduler.spawn({
                    while (!this._terminate)
                    {
                        Request req = transceiver.req.receive();

                        if (this._terminate)
                            break;

                        thisScheduler.spawn({
                            handleRequest(req, node, control.filter);
                        });
                    }
                });
            });
        });

        return transceiver;
    }

    /// Where to send message to
    private ServerTransceiver _transceiver;

    private shared(bool) _terminate;

    /// Timeout to use when issuing requests
    private const Duration _timeout;

    public this (ServerTransceiver transceiver, Duration timeout = Duration.init)
    {
        this._transceiver = transceiver;
        this._timeout = timeout;
        this._terminate = false;
    }

    @property public ServerTransceiver transceiver ()
    {
        return this._transceiver;
    }

    public void shutdown ()
    {
        this._terminate = true;
        this.transceiver.close();
    }
}

private class Client
{
    /// Where to send message to
    private ClientTransceiver _transceiver;
    private WaitManager _wait_manager;
    /// Timeout to use when issuing requests
    private const Duration _timeout;
    private shared(bool) _terminate;

    public this (Duration timeout = Duration.init)
    {
        this._transceiver = new ClientTransceiver;
        this._timeout = timeout;
        this._wait_manager = new WaitManager();
    }

    @property public ClientTransceiver transceiver ()
    {
        return this._transceiver;
    }

    public void query (ServerTransceiver remote, ref Request req, ref Response res)
    {
        res = () @trusted
        {
            this._terminate = false;

            if (thisScheduler is null)
                thisScheduler = new FiberScheduler();

            Condition cond = thisScheduler.newCondition(null);
            thisScheduler.spawn({
                remote.send(req);
                while (!this._terminate)
                {
                    Response res = this.transceiver.res.receive();
                    if (this._terminate)
                        break;
                    while (!(res.id in this._wait_manager.waiting))
                        cond.wait(1.msecs);
                    this._wait_manager.pending = res;
                    this._wait_manager.waiting[res.id].c.notify();
                }
            });

            Response val;
            thisScheduler.start({
                val = this._wait_manager.waitResponse(req.id, this._timeout);
                this._terminate = true;
            });
            return val;
        }();
    }

    public void shutdown ()
    {
        this._terminate = true;
        this.transceiver.close();
    }
}

struct ResultOfSpawan
{
    ServerTransceiver transceiver;
    WaitManager manager;
}

private class RemoteAPI (API) : API
{
    public static Server!(API) spawn (Implementation) (CtorParams!Implementation args)
    {
        auto res = spawned!Implementation(args);
        return new Server(res.transceiver, res.wait_manager);
    }

    /// Helper template to get the constructor's parameters
    private static template CtorParams (Impl)
    {
        static if (is(typeof(Impl.__ctor)))
            private alias CtorParams = Parameters!(Impl.__ctor);
        else
            private alias CtorParams = AliasSeq!();
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
                            req.sender.send(
                                Response(
                                    Status.Success,
                                    req.id,
                                    node.%1$s(args.args).serializeToJsonString()));
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
            assert(0, "Unmatched method name: " ~ cmd.method);
        }
    }

    private static ResultOfSpawan spawned (Implementation) (CtorParams!Implementation cargs)
    {
        ServerTransceiver transceiver = new ServerTransceiver();
        WaitManager wait_manager = new WaitManager();
        scope node = new Implementation(cargs);
        auto thread_scheduler = ThreadScheduler.instance;

        // used for controling filtering / sleep
        struct Control
        {
            FilterAPI filter;    // filter specific messages
            SysTime sleep_until; // sleep until this time
            bool drop;           // drop messages if sleeping
        }

        Control control;

        thread_scheduler.spawn({

            auto fiber_scheduler = new FiberScheduler();
            fiber_scheduler.start({
                this._terminate = false;
                thisScheduler.spawn({
                    while (!this._terminate)
                    {
                        Request req = transceiver.req.receive();

                        if (this._terminate)
                            break;

                        thisScheduler.spawn({
                            handleCommand(req, node, control.filter);
                        });
                    }
                });

                thisScheduler.spawn({
                    Condition cond = thisScheduler.newCondition(null);
                    while (!this._terminate)
                    {
                        Response res = transceiver.res.receive();

                        if (this._terminate)
                            break;

                        while (!(res.id in this.wait_manager.waiting))
                            cond.wait(1.msecs);

                        wait_manager.pending = res;
                        wait_manager.waiting[res.id].c.notify();
                        wait_manager.remove(res.id);
                    }
                });
            });
        });

        return ResultOfSpawan(transceiver, wait_manager);
    }

    /// Where to send message to
    private ServerTransceiver _transceiver;
    private WaitManager _wait_manager;
    private shared(bool) _terminate;

    /// Timeout to use when issuing requests
    private const Duration _timeout;


    public this (ServerTransceiver transceiver, WaitManager wait_manager, Duration timeout = Duration.init)
    {
        this._transceiver = transceiver;
        this._wait_manager = wait_manager;
        this._timeout = timeout;
        this._terminate = false;
    }

    @property public ServerTransceiver transceiver ()
    {
        return this._transceiver;
    }

    public void shutdown ()
    {
        this._terminate = true;
        this.transceiver.close();
    }

    static foreach (member; __traits(allMembers, API))
        static foreach (ovrld; __traits(getOverloads, API, member))
        {
            mixin(q{
                override ReturnType!(ovrld) } ~ member ~ q{ (Parameters!ovrld params)
                {
                    if (thisScheduler is null)
                        thisScheduler = new FiberScheduler();

                    auto res = () @trusted {
                        auto serialized = ArgWrapper!(Parameters!ovrld)(params)
                            .serializeToJsonString();

                        auto req = Request(this.transceiver, scheduler.getNextResponseId(), ovrld.mangleof, serialized);

                        thisScheduler.spawn({
                            this.transceiver.send(req);
                        });

                        thisScheduler.start({
                            res = this._wait_manager.waitResponse(req.id, this._timeout);
                        });
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
        public @property ulong getValue ();
    }

    static class MyAPI : API
    {
        @safe:
        public override @property ulong getValue ()
        { return 42; }
    }

    scope test = RemoteAPI!API.spawn!MyAPI();
    assert(test.getValue() == 42);
}
*/