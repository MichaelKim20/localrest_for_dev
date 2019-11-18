module test;

import vibe.data.json;
import geod24.LocalRest;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;

import vibe.core.core;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

/*
void main()
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
        {
            return 42;
        }
        public override Json getValue (ulong idx)
        { assert(0); }
        public override Json getQuorumSet ()
        { assert(0); }
        public override string recv (Json data)
        { assert(0); }
    }

    import std.stdio;

    scope test = RemoteAPI!API.spawn!MockAPI();
    assert(42 == test.pubkey());
    test.ctrl.shutdown();

}
*/
void main()
{
    //test2();
    test11();
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
void test11()
{

    writeln("test3");
    
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

    auto testerFiber = geod24.concurrency.spawn(&testFunc, geod24.concurrency.thisTid);
    // Make sure our main thread terminates after everyone else
    geod24.concurrency.receiveOnly!int();


    writeln("test3");
}