module test;

import vibe.data.json;
import geod24.LocalRest;
import std.stdio;
import geod24.RequestService;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
    import std.variant;

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
*/

void main()
{
    import std.stdio;
    import std.conv;
    import std.variant;

    //writeln(Message2(MsgType.standard, "data").data.type);
    //writeln(Message2(MsgType.standard, Command2("method", "args")).data.type);
    //auto t = Clock.currTime();

    auto child = spawn({
        bool terminated = false;
        while (!terminated)
        {
            thisTid.process((ref Message msg) {
                Message res_msg;
                if (msg.type == MsgType.standard)
                {
                    if (msg.data.type.toString() == "geod24.RequestService.Request")
                    {
                        auto req = msg.data.peek!(Request);
                        if (req.method == "pow")
                        {
                            int value = to!int(req.args);
                            res_msg = Message(
                                MsgType.standard,
                                Variant(Response(Status.Success, to!string(value * value)))
                            );
                        }
                    }
                }
                return res_msg;
            });
            terminated = true;
            Thread.sleep(dur!("msecs")(1));
        }
    });

    Message msg;
    msg = Message(MsgType.standard, Variant(Request(thisTid(), "pow", "2")));
    auto res = child.request(msg);
    writeln(res.data.type.toString());
    writeln(res.data.peek!(Response).data);
}
