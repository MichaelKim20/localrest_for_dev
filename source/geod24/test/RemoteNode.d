module geod24.test.RemoteNode;

import geod24.concurrency;

import core.sync.condition;
import core.sync.mutex;
import core.thread;

import std.stdio;

private struct Request
{
    INode sender;
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

private interface INode
{
    void send (Request msg);
    void send (Response msg);
}

private class Node : INode
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
        formattedWrite(sink, "Node(%x:%s)", cast(void*) req, cast(void*) res);
    }

    public void send (Request msg)
    {
        if (thisScheduler !is null)
        {
            this.req.send(msg);
        }
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
        {
            this.res.send(msg);
        }
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
    Node node1, node2;

    node1 = new Node();
    node2 = new Node();

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
                    Request msg = node1.req.receive();
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
                node1.close();
            });

            //  Response received from another node
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                while (!terminate)
                {
                    Response msg = node1.res.receive();
                    if (msg.data == "exit")
                        terminate = true;
                }
                node1.close();
            });

            //  Request to another node
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                Request msg;
                msg = Request(node1, 0, "name");
                node2.send(msg);
                msg = Request(node1, 0, "age");
                node2.send(msg);
                msg = Request(node1, 0, "exit");
                node2.send(msg);
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
                    Request msg = node2.req.receive();
                    //writefln("%s %s", node2, msg);
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
                node2.close();
            });

            //  Response received from another node
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                while (!terminate)
                {
                    Response msg = node2.res.receive();
                    if (msg.data == "exit")
                        terminate = true;
                }
                node2.close();
            });
        });
    });
}

private class ClientNode : INode
{
    public Channel!Response res;

    public this ()
    {
        res = new Channel!Response();
    }

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "ClientNode(%x)", cast(void*) res);
    }

    public void send (Request msg)
    {
    }

    public void send (Response msg)
    {
        if (thisScheduler !is null)
        {
            this.res.send(msg);
        }
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

    private Mutex wait_mutex;

    /// Ctor
    public this ()
    {
        this.wait_mutex = new Mutex();
    }

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

private class NodeInterface
{
    private Node local_node;
    private WaitManager wait_manager;
    private shared(bool) terminate;

    private string name;
    private string age;

    public this (string name, string age)
    {
        this.name = name;
        this.age = age;

        this.local_node = new Node();
        this.wait_manager = new WaitManager();
        this.terminate = false;

        this.spawnNode(this.local_node);
    }

    @property public Node node ()
    {
        return this.local_node;
    }

    private void spawnNode (Node local)
    {
        auto thread_scheduler = ThreadScheduler.instance;
        thread_scheduler.spawn({
            auto fiber_scheduler = new FiberScheduler();
            fiber_scheduler.start({
                this.terminate = false;
                thisScheduler.spawn({
                    while (!terminate)
                    {
                        Request msg = local.req.receive();

                        if (this.terminate)
                            break;

                        if (msg.method == "name")
                        {
                            thisScheduler.spawn({
                                Response res = Response(Status.Success, msg.id, this.name);
                                msg.sender.send(res);
                            });
                        }
                        else if (msg.method == "age")
                        {
                            thisScheduler.spawn({
                                Response res = Response(Status.Success, msg.id, this.age);
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

                        while (!(res.id in this.wait_manager.waiting))
                            cond.wait(1.msecs);

                        this.wait_manager.pending = res;
                        this.wait_manager.waiting[res.id].c.notify();
                    }
                });
            });
        });
    }

    public void query (Node remote, ref Request req, ref Response res)
    {
        if (thisScheduler is null)
            thisScheduler = new FiberScheduler();

        thisScheduler.spawn({
            remote.send(req);
        });

        thisScheduler.start({
            res = this.wait_manager.waitResponse(req.id, 3000.msecs);
        });
    }

    public string getName (Node remote)
    {
        Request req = Request(this.local_node, this.wait_manager.getNextResponseId(), "name", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public string getAge (Node remote)
    {
        Request req = Request(this.local_node, this.wait_manager.getNextResponseId(), "age", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public void shutdown ()
    {
        this.terminate = true;
        this.local_node.close();
    }
}

private class ClientInterface
{
    private ClientNode  local_node;
    private WaitManager wait_manager;
    private FiberScheduler query_scheduler;
    private shared(bool) terminate;

    public this ()
    {
        this.local_node = new ClientNode;
        this.wait_manager = new WaitManager();
    }

    @property public ClientNode client ()
    {
        return this.local_node;
    }

    public void query (Node remote, ref Request req, ref Response res)
    {
        res = () @trusted
        {
            this.terminate = false;

            if (this.query_scheduler is null)
                this.query_scheduler = new FiberScheduler();

            Condition cond = this.query_scheduler.newCondition(null);
            this.query_scheduler.spawn({
                remote.send(req);
                while (!this.terminate)
                {
                    Response res = this.local_node.res.receive();

                    if (this.terminate)
                        break;

                    while (!(res.id in this.wait_manager.waiting))
                        cond.wait(1.msecs);

                    this.wait_manager.pending = res;
                    this.wait_manager.waiting[res.id].c.notify();
                }
            });

            Response val;
            this.query_scheduler.start({
                val = this.wait_manager.waitResponse(req.id, 3000.msecs);
                terminate = true;
            });
            return val;
        }();
    }

    public string getName (Node remote)
    {
        Request req = Request(this.local_node, this.wait_manager.getNextResponseId(), "name", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public string getAge (Node remote)
    {
        Request req = Request(this.local_node, this.wait_manager.getNextResponseId(), "age", "");
        Response res;
        this.query(remote, req, res);
        return res.data;
    }

    public void shutdown ()
    {
        this.terminate = true;
        this.local_node.close();
    }
}

unittest
{
    NodeInterface node1, node2;
    node1 = new NodeInterface("Tom", "30");
    node2 = new NodeInterface("Jain", "24");
    assert (node1.getName(node2.node) == "Jain");
    assert (node1.getAge(node2.node) == "24");
    node1.shutdown();
    node2.shutdown();
}

/*
unittest
{
    NodeInterface node;
    ClientInterface client;
    node = new NodeInterface("Tom", "30");
    client = new ClientInterface();
    assert (client.getName(node.node) == "Tom");
    assert (client.getAge(node.node) == "30");
    node.shutdown();
    client.shutdown();
}
*/

unittest
{
    NodeInterface node1, node2;
    node1 = new NodeInterface("Tom", "30");
    node2 = new NodeInterface("Jain", "24");
    assert (node1.getName(node2.node) == "Jain");
    assert (node1.getAge(node2.node) == "24");
    node1.shutdown();
    node2.shutdown();
}

unittest
{
    NodeInterface node1, node2;
    node1 = new NodeInterface("Tom", "30");
    node2 = new NodeInterface("Jain", "24");
    assert (node1.getName(node2.node) == "Jain");
    assert (node1.getAge(node2.node) == "24");
    node1.shutdown();
    node2.shutdown();
}


