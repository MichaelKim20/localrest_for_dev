module test;

import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;
import geod24.LocalRest;
import geod24.MessageDispatcher;

void main()
{
    test1();
    test5();
    test4();
    test5();
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

void test4()
{
    writefln("test4");
    import std.format;

    __gshared MessageDispatcher[string] tbn;

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
        public override void start ()
        {
            runTask(&this.task);
        }

        public override ulong getCounter ()
        {
            scope (exit) {
                this.counter = 0;
            }
            return this.counter;
        }

        private void task ()
        {
            while (true)
            {
                this.counter++;
                geod24.MessageDispatcher.sleep(50.msecs);
            }
        }

        private ulong counter;
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
    //thisInfo.cleanup();

    //Thread.sleep(5000.msecs);
}