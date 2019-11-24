module test;

import vibe.data.json;
import geod24.LocalRest;
import std.stdio;
import C = geod24.concurrency;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;


void main()
{
    test1();
    //test2();
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

    writeln("start");
    scope test = RemoteAPI!API.spawn!MockAPI();
    writeln("pubkey");
    ulong v;
    v = test.pubkey();
    writeln("end");
    test.ctrl.shutdown();
}

void test2()
{
    import std.stdio;
    import std.conv;

    auto child = C.spawn({
        bool terminated = false;
        while (!terminated)
        {
            C.process(
                (C.OwnerTerminated e)
                {
                    terminated = true;
                },
                (C.Shutdown e)
                {
                    terminated = true;
                    C.thisTid().shutdowned = true;
                },
                (C.Request req)
                {
                    if (req.method == "pow")
                    {
                        immutable int value = to!int(req.args);
                        return C.Response(C.Status.Success, to!string(value * value));
                    }
                    return C.Response(C.Status.Failed);
                }
            );
        }
    });

    auto req = C.Request(C.thisTid(), "pow", "2");
    auto res = C.query(child, req);
    assert(res.data == "4");

    C.shutdown(child);
}
