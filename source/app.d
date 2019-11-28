module test;

import geod24.LocalRest;
import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;


void main()
{
    test1();
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

    import std.stdio;

    scope test = RemoteAPI!API.spawn!MockAPI();
    auto v = test.pubkey();
    writefln("end %s", v);

    test.ctrl.shutdown();
}

void test9()
{
    import std.stdio;
    writeln("test9");
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
            //writefln("Start API -------- %s", dur);
            Thread.sleep(msecs(dur));
            writefln("End API -------- %s", dur);
            return 42;
        }
    }
    writeln("test9 A");
        import std.stdio;
    // node with no timeout
    auto node = RemoteAPI!API.spawn!Node(500.msecs);
    assertThrown!Exception(node.sleepFor(2000));
    writeln("test9 B");
/*
    // node with a configured timeout
    auto to_node = RemoteAPI!API.spawn!Node(500.msecs);

    writeln("test9 B");
    /// none of these should time out
    assert(to_node.sleepFor(10) == 42);
    writeln("test9 C");
    assert(to_node.sleepFor(20) == 42);
    writeln("test9 D");
    assert(to_node.sleepFor(30) == 42);
    writeln("test9 E");
    assert(to_node.sleepFor(40) == 42);
    writeln("test9 0");
    assert(to_node.sleepFor(2000) == 42);
    //assertThrown!Exception(to_node.sleepFor(2000));
    writeln("test9 1");
    Thread.sleep(2.seconds);  // need to wait for sleep() call to finish before calling .shutdown()
    writeln("test9 2");
    to_node.ctrl.shutdown();
    writeln("test9 3");
*/
    node.ctrl.shutdown();

    writeln("test9 4");
}


// Test explicit shutdown
void test15()
{
    import std.stdio;
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
    import std.stdio;
    writeln("test15");
}