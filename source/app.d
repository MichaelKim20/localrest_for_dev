module test;

import vibe.data.json;
import geod24.LocalRest;
static import C = geod24.concurrency;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;

import vibe.core.core;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

void main()
{
    //test1();
    //test2();
    //test5();
    //test7();
    //test10();
    //test11();
    //test13();
    //test14();
    test15();
}

void test1()
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
    import std.stdio;
    writeln("test 1");
}

/*
void test2()
{

    import std.stdio;
    writeln("test2 1");
    import std.conv;
    static import geod24.concurrency;

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
        auto tid = geod24.concurrency.locate(name);
        if (tid != tid.init)
            return new RemoteAPI!API(tid);

        switch (type)
        {
        case "normal":
            auto ret =  RemoteAPI!API.spawn!Node(false);
            geod24.concurrency.register(name, ret.tid());
            return ret;
        case "byzantine":
            auto ret =  RemoteAPI!API.spawn!Node(true);
            geod24.concurrency.register(name, ret.tid());
            return ret;
        default:
            assert(0, type);
        }
    }

    auto node1 = factory("normal", 1);
    auto node2 = factory("byzantine", 2);

    static void testFunc(geod24.concurrency.Tid parent)
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
    writeln("test2, 2");

    auto testerFiber = geod24.concurrency.spawn(&testFunc, geod24.concurrency.thisTid);
    // Make sure our main thread terminates after everyone else
    geod24.concurrency.receiveOnly!int();
    import std.stdio;
    writeln("test2, 3");
}

void test3()
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
        this(Tid masterTid)
        {
            this.master = new RemoteAPI!API(masterTid);
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

    writeln("test3 - 1");
    RemoteAPI!API[4] nodes;
    auto master = RemoteAPI!API.spawn!MasterNode();
    nodes[0] = master;
    nodes[1] = RemoteAPI!API.spawn!SlaveNode(master.tid());
    nodes[2] = RemoteAPI!API.spawn!SlaveNode(master.tid());
    nodes[3] = RemoteAPI!API.spawn!SlaveNode(master.tid());

    writeln("test3 - 2");
    foreach (n; nodes)
    {
    writefln("n %s", n);
        writefln("requests   --- %s", n.requests());
        writefln("value      --- %s", n.value());
    }

    writeln("test3 - 3");
    assert(nodes[0].requests() == 4);

    foreach (n; nodes[1 .. $])
    {
        writefln("value      --- %s", n.value());
        writefln("requests   --- %s", n.requests());
    }

    writeln("test3 - 4");
    assert(nodes[0].requests() == 7);
    import std.algorithm;
    nodes.each!(node => node.ctrl.shutdown());
    writeln("test3 - 9");
}
*/

/// Nodes can start tasks
void test5()
{
    static import L = geod24.LocalRest;
    writeln("test 5");
    static import core.thread;
    import core.time;

    static interface API
    {
        public void start ();
        public ulong getCounter ();
    }

    static class Node : API
    {
        public override void start ()
        {
            L.runTask(&this.task);
        }

        public override ulong getCounter ()
        {
            scope (exit) this.counter = 0;
            return this.counter;
        }

        private void task ()
        {
            while (true)
            {
                this.counter++;
                L.sleep(50.msecs);
            }
        }

        private ulong counter;
    }

    import std.format;
    auto node = L.RemoteAPI!API.spawn!Node();
    ulong count;
    writefln("test 5 SSS");
    count = node.getCounter();
    writefln("test 5 %s", count);

    node.start();

    count = node.getCounter();
    writefln("test 5 %s", count);
    assert(count == 1);

    count = node.getCounter();
    writefln("test 5 %s", count);
    assert(count == 0);
    core.thread.Thread.sleep(1.seconds);
    // It should be 19 but some machines are very slow
    // (e.g. Travis Mac testers) so be safe
    count = node.getCounter();
    writefln("test 5 %s", count);
    assert(count >= 9);

    count = node.getCounter();
    writefln("test 5 %s", count);
    assert(count == 0);
    node.ctrl.shutdown();
    writeln("test 5");
}

void test7()
{
    writeln("test 7");
    __gshared C.Tid n1tid;
    static import L = geod24.LocalRest;

    static interface API
    {
        public ulong call ();
        public void asyncCall ();
    }
    static class Node : API
    {
        public this()
        {
            if (n1tid != C.Tid.init)
                this.remote = new RemoteAPI!API(n1tid);
        }

        public override ulong call () { return ++this.count; }
        public override void  asyncCall () { L.runTask(() => cast(void)this.remote.call); }
        size_t count;
        RemoteAPI!API remote;
    }

    auto n1 = RemoteAPI!API.spawn!Node();
    n1tid = n1.tid();
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
    n1.sleep(3.seconds, true);
    for (size_t i = 0; i < 100; i++)
        n2.asyncCall();
    // Make sure we don't end up blocked forever
    Thread.sleep(3.seconds);
    assert(3 == n1.call());

    // Debug output, uncomment if needed
    version (none)
    {
        writeln("Two non-blocking calls: ", current2 - current1);
        writeln("Sleep + non-blocking call: ", current3 - current2);
        writeln("Delta since sleep: ", current4 - current2);
    }

    n1.ctrl.shutdown();
    n2.ctrl.shutdown();
    writeln("test 7");
}

void test10()
{
    writeln("test10");

    import core.thread;
    import std.exception;

    static interface API
    {
        float getFloat();
        size_t sleepFor (long dur);
    }

    static class Node : API
    {
        override float getFloat() 
        { 
            writeln("<<< IN getFloat");
            return 69.69; 
        }
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

    writeln("test10 1");
    /// none of these should time out
    assert(to_node.sleepFor(10) == 42);
    writeln("test10 2");
    assert(to_node.sleepFor(20) == 42);
    writeln("test10 3");
    assert(to_node.sleepFor(30) == 42);
    writeln("test10 4");
    assert(to_node.sleepFor(40) == 42);

    writeln("test10 5");
    assertThrown!Exception(to_node.sleepFor(2000));
    writeln("test10 6");
    
    Thread.sleep(2.seconds);
    writeln("test10 7");
    
    auto v = to_node.getFloat();
    writefln("test10 8 %s", v);
    
    //assert(cast(int) == 69);
    writeln("test10 9");

    to_node.ctrl.shutdown();
    node.ctrl.shutdown();

    writeln("test10 X");
}

void test11()
{
    import std.stdio;
    writeln("test11");
    static import geod24.concurrency;
    import std.exception;

    __gshared C.Tid node_tid;

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
            auto node = new RemoteAPI!API(node_tid, 5000.msecs);

            // no time-out
            writeln("node.ctrl.sleep(10.msecs);");
            node.ctrl.sleep(1.msecs);
            assert(node.ping() == 42);

            // time-out
            writeln("node.ctrl.sleep(2000.msecs);");
            node.ctrl.sleep(2000.msecs);
            assertThrown!Exception(node.ping());
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node();
    auto node_2 = RemoteAPI!API.spawn!Node();
    node_tid = node_2.tid;
    node_1.check();
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();
    import std.stdio;
    writeln("test11");
}

void test13()
{
    import std.stdio;
    writeln("test13");
    static import geod24.concurrency;
    import std.exception;

    __gshared C.Tid node_tid;

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
            auto node = new RemoteAPI!API(node_tid, 420.msecs);

            // Requests are dropped, so it times out
            assert(node.ping() == 42);
            node.ctrl.sleep(10.msecs, true);
            assertThrown!Exception(node.ping());
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node();
    auto node_2 = RemoteAPI!API.spawn!Node();
    node_tid = node_2.tid;
    node_1.check();
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();
    import std.stdio;
    writeln("test13");
}

void test14()
{
    import std.stdio;
    writeln("test14 --- 1");
    static import geod24.concurrency;
    import std.exception;

    __gshared C.Tid node_tid;

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
            auto node = new RemoteAPI!API(node_tid, 5000.msecs);
            assert(node.ping() == 42);
            // We need to return immediately so that the main thread
            // puts us to sleep
            geod24.LocalRest.runTask(() {
                //node.ctrl.sleep(200.msecs);
                assert(node.ping() == 42);
            });
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node(5000.msecs);
    auto node_2 = RemoteAPI!API.spawn!Node(5000.msecs);
    node_tid = node_2.tid;
    node_1.check();
    //writeln("test14 --- 2");
    node_1.ctrl.sleep(300.msecs);
    //writeln("test14 --- 3");
    assert(node_1.ping() == 42);
    //writeln("test14 --- 4");

    //Thread.sleep(dur!("msecs")(1000));
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();

    import std.stdio;
    writeln("test14 --- 5");
}

void test15()
{
    writeln("test15");
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
    writeln("test15");
}
