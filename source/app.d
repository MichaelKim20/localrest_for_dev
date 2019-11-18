module test;

import vibe.data.json;
import geod24.LocalRest;
import std.stdio;
import geod24.concurrency;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;


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

/*
void main()
{
    import std.stdio;

    import std.conv;

    auto child = spawn({
        bool terminated = false;
        auto sleep_inteval = dur!("msecs")(1);
        while (!terminated)
        {
            thisTid.process((ref Message msg) {
                Message res_msg;
                if (msg.type == MsgType.shutdown)
                {
                    terminated = true;
                    return Message(MsgType.shutdown, Response(Status.Success));
                }

                if (msg.convertsTo!(Request))
                {
                    auto req = msg.get!(Request);
                    if (req.method == "pow")
                    {
                        immutable int value = to!int(req.args);
                        return Message(MsgType.standard, Response(Status.Success, to!string(value * value)));
                    }
                }
                return Message(MsgType.standard, Response(Status.Failed));
            });
            Thread.sleep(sleep_inteval);
        }
    });

    auto req = Request(thisTid(), "pow", "2");
    auto res = child.query(req);
    assert(res.data == "4");

    child.shutdown();
    thisInfo.cleanup();
}
*/