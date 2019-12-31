module geod24.test.RemoteNode;

import geod24.concurrency;

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
};

unittest
{
    ServerTransceiver server1, server2;

    server1 = new ServerTransceiver();
    server2 = new ServerTransceiver();

    auto thread_scheduler = new ThreadScheduler();

    // Thread1
    thread_scheduler.spawn({
        auto fiber_scheduler = new FiberScheduler();
        // Fiber1
        fiber_scheduler.start({
            thisScheduler = fiber_scheduler;
            bool terminate = false;

            //  processing of requests
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                while (!terminate)
                {
                    Request msg = server1.req.receive();
                    if (msg.method == "name")
                    {
                        Response res = Response(Status.Success, 0, "Tom");
                        msg.sender.send(res);
                    }
                    else if (msg.method == "age")
                    {
                        Response res = Response(Status.Success, 0, "25");
                        msg.sender.send(res);
                    }
                    else if (msg.method == "exit")
                    {
                        terminate = true;
                        Response res = Response(Status.Success, 0, "exit");
                        msg.sender.send(res);
                    }
                }
                server1.close();
            });

            //  Response received from another server
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                while (!terminate)
                {
                    Response msg = server1.res.receive();
                    if (msg.data == "exit")
                        terminate = true;
                }
                server1.close();
            });

            //  Request to another server
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                Request msg;
                msg = Request(server1, 0, "name");
                server2.send(msg);
                msg = Request(server1, 0, "age");
                server2.send(msg);
                msg = Request(server1, 0, "exit");
                server2.send(msg);
            });
        });
    });

    // Thread2
    thread_scheduler.spawn({
        auto fiber_scheduler = new FiberScheduler();
        // Fiber2
        fiber_scheduler.start({
            thisScheduler = fiber_scheduler;
            bool terminate = false;

            //  processing of requests
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                while (!terminate)
                {
                    Request msg = server2.req.receive();
                    //writefln("%s %s", server2, msg);
                    if (msg.method == "name")
                    {
                        Response res = Response(Status.Success, 0, "Tom");
                        msg.sender.send(res);
                    }
                    else if (msg.method == "age")
                    {
                        Response res = Response(Status.Success, 0, "25");
                        msg.sender.send(res);
                    }
                    else if (msg.method == "exit")
                    {
                        terminate = true;
                        Response res = Response(Status.Success, 0, "exit");
                        msg.sender.send(res);
                    }
                }
                server2.close();
            });

            //  Response received from another server
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                while (!terminate)
                {
                    Response msg = server2.res.receive();
                    if (msg.data == "exit")
                        terminate = true;
                }
                server2.close();
            });
        });
    });
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

private interface API
{
    string name ();
    string age ();
}

private class NodeAPI : API
{
    public string _name;
    public string _age;

    public this (string name, string age)
    {
        this._name = name;
        this._age = age;
    }

    public string name ()
    {
        return this._name;
    }

    public string age ()
    {
        return this._age;
    }
}

private class Server
{
    private ServerTransceiver _transceiver;
    private WaitManager _wait_manager;
    private shared(bool) terminate;

    private NodeAPI instanseOfAPI;

    public this (string name, string age)
    {
        this.instanseOfAPI = new NodeAPI(name, age);

        this._transceiver = new ServerTransceiver();
        this._wait_manager = new WaitManager();
        this.terminate = false;

        this.spawnNode(this.transceiver);
    }

    @property public ServerTransceiver transceiver ()
    {
        return this._transceiver;
    }

    private void spawnNode (ServerTransceiver local)
    {
        auto thread_scheduler = ThreadScheduler.instance;
        thread_scheduler.spawn({
            auto fiber_scheduler = new FiberScheduler();
            fiber_scheduler.start({
                this.terminate = false;
                thisScheduler.spawn({
                    while (!this.terminate)
                    {
                        Request msg = local.req.receive();

                        if (this.terminate)
                            break;

                        if (msg.method == "name")
                        {
                            thisScheduler.spawn({
                                Response res = Response(Status.Success, msg.id, this.instanseOfAPI.name);
                                msg.sender.send(res);
                            });
                        }
                        else if (msg.method == "age")
                        {
                            thisScheduler.spawn({
                                Response res = Response(Status.Success, msg.id, this.instanseOfAPI.age);
                                msg.sender.send(res);
                            });
                        }
                    }
                });

                thisScheduler.spawn({
                    Condition cond = thisScheduler.newCondition(null);
                    while (!this.terminate)
                    {
                        Response res = local.res.receive();

                        if (this.terminate)
                            break;

                        while (!(res.id in this._wait_manager.waiting))
                            cond.wait(1.msecs);

                        this._wait_manager.pending = res;
                        this._wait_manager.waiting[res.id].c.notify();
                    }
                });
            });
        });
    }

    public void query (ServerTransceiver remote, ref Request req, ref Response res)
    {
        if (thisScheduler is null)
            thisScheduler = new FiberScheduler();

        thisScheduler.spawn({
            remote.send(req);
        });

        thisScheduler.start({
            res = this._wait_manager.waitResponse(req.id, 3000.msecs);
        });
    }

    public string getName (ServerTransceiver remote)
    {
        Request req = Request(this.transceiver, this._wait_manager.getNextResponseId(), "name", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public string getAge (ServerTransceiver remote)
    {
        Request req = Request(this.transceiver, this._wait_manager.getNextResponseId(), "age", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public void shutdown ()
    {
        this.terminate = true;
        this.transceiver.close();
    }
}

private class Client
{
    private ClientTransceiver _transceiver;
    private WaitManager _wait_manager;
    private shared(bool) terminate;

    public this ()
    {
        this._transceiver = new ClientTransceiver;
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
                    while (!(res.id in this._wait_manager.waiting))
                        cond.wait(1.msecs);
                    this._wait_manager.pending = res;
                    this._wait_manager.waiting[res.id].c.notify();
                }
            });

            Response val;
            thisScheduler.start({
                val = this._wait_manager.waitResponse(req.id, 3000.msecs);
                terminate = true;
            });
            return val;
        }();
    }

    public string getName (ServerTransceiver remote)
    {
        Request req = Request(this.transceiver, this._wait_manager.getNextResponseId(), "name", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public string getAge (ServerTransceiver remote)
    {
        Request req = Request(this.transceiver, this._wait_manager.getNextResponseId(), "age", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public void shutdown ()
    {
        this.terminate = true;
        this.transceiver.close();
    }
}

unittest
{
    Server server1, server2;
    server1 = new Server("Tom", "30");
    server2 = new Server("Jain", "24");
    assert (server1.getName(server2.transceiver) == "Jain");
    assert (server1.getAge(server2.transceiver) == "24");
    server1.shutdown();
    server2.shutdown();
}

unittest
{
    Server server;
    Client client;
    server = new Server("Tom", "30");
    client = new Client();
    assert (client.getName(server.transceiver) == "Tom");
    assert (client.getAge(server.transceiver) == "30");
    server.shutdown();
    client.shutdown();
}


