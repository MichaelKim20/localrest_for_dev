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
    writeln("sample");
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
    //test.ctrl.shutdown();
}