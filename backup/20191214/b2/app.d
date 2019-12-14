module test;

import vibe.data.json;
import geod24.LocalRest;
static import C = geod24.concurrency;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;


void main()
{
    test1();
   // test4();
    //test5();
}

void test1()
{
    writeln("test1");
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
    writeln("test1");
}

/// In a real world usage, users will most likely need to use the registry
void test2()
{
    writefln("test2");
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

    auto parent = C.thisTid;
    void testFunc()
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
        //geod24.concurrency.send(parent, 42);
    }

    auto testerFiber = C.spawnFiber(&testFunc);
    // Make sure our main thread terminates after everyone else
    //geod24.concurrency.receive((int val) {});
}

void test4()
{
    writefln("test4");
    static import geod24.concurrency;
    import std.format;

    __gshared C.Tid[string] tbn;

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
        tbn[format("node%d", idx)] = api.tid();
    nodes[0].setNext("node1");
    nodes[1].setNext("node2");
    nodes[2].setNext("node0");

    // 7 level of re-entrancy
    assert(210 == nodes[0].call(20, 0));

    import std.algorithm;
    nodes.each!(node => node.ctrl.shutdown());
    writefln("test4");
}

void test5()
{
    writefln("test5");
    static import core.thread;
    import core.time;
    import core.sync.mutex;
    import std.process;

    static interface API
    {
        public void start ();
        public ulong getCounter ();
    }

    static class Node : API
    {
        public this ()
        {
            this.m = new Mutex();
        }
        public override void start ()
        {
            //writefln("%s %s", thisThreadID(),  C.thisScheduler);
            runTask(&this.task);
        }

        public override ulong getCounter ()
        {
            //this.m.lock;
            scope (exit) {
                this.counter = 0;
                //this.m.unlock;
            }
            //writefln("%s getCounter -- %s %s", thisThreadID(), this.counter, C.thisScheduler);
            return this.counter;
        }

        private void task ()
        {
            while (true)
            {
                this.counter++;
                sleep(50.msecs);
            }
        }

        private ulong counter;
        private Mutex m;
    }

    writefln("test5 - 0");
    import std.format;
    auto node = RemoteAPI!API.spawn!Node();
    writefln("test5 - 1");
    assert(node.getCounter() == 0);
    node.start();
    writefln("test5 - 2");
    assert(node.getCounter() == 1);
    assert(node.getCounter() == 0);
    writefln("test5 - 3 - %s", thisThreadID);
    //auto cond = C.thisScheduler.newCondition(null);
    //cond.wait(1.seconds);
    Thread.sleep(1.seconds);
    writefln("test5 - 4 - %s", thisThreadID);
    // It should be 19 but some machines are very slow
    // (e.g. Travis Mac testers) so be safe
    assert(node.getCounter() >= 9);
    writefln("test5 - 5");
    assert(node.getCounter() == 0);
    //writefln("test5 - 6");
    node.ctrl.shutdown();
    writefln("test5");
}