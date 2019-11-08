/+ dub.sdl:
	name "test"
	description "Tests vibe.d's std.concurrency integration"
	dependency "vibe-core" path="../"
+/
module test;
/*
import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

import core.atomic;
import core.time;
import core.stdc.stdlib : exit;
*/

import vibe.data.json;
import geod24.LocalRest;
import std.stdio;
import geod24.concurrency;
/*
void main()
{
    import core.exception;
    import std.exception;

    static void testScheduler(Scheduler s)
    {
        scheduler = s;
        scheduler.start({
            auto tid = spawn({
                int i;

                try
                {
                    for (i = 1; i < 10; i++)
                    {
                        assertNotThrown!AssertError(assert(receiveOnly!int() == i));
                    }
                }
                catch (OwnerTerminated e)
                {
                        writefln("OwnerTerminated");
                }

                // i will advance 1 past the last value expected
                assert(i == 10);
            });

            auto r = new Generator!int({
                assertThrown!Exception(yield(2.0));
                yield(); // ensure this is a no-op
                yield(1);
                yield(); // also once something has been yielded
                yield(2);
                yield(3);
                yield(4);
                yield(5);
                yield(6);
                yield(7);
                yield(8);
                yield(9);
            });

            foreach (e; r)
            {
                tid.send(e);
            }
        });
        scheduler = null;
    }

    //testScheduler(new ThreadScheduler);
    testScheduler(new FiberScheduler);
}
*/
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
    test.getValue(v);
    writeln("end");
    test.ctrl.shutdown();
}

/*
import std.stdio;
import std.digest;
import std.digest.sha;
import core.thread;
import core.time;

int main (string[] args)
{
    if (args.length < 2)
    {
        writeln("Missing 'secret' argument to program");
        return 1;
    }
    ubyte[32] start = sha256Of(args[1]);
    round(start, 100);
    return 0;
}

void round (ubyte[32] preimage, size_t n)
{
    ubyte[32] image = sha256Of(preimage);
    if (n)
        round(image, n - 1);
    else
        writeln("Registering validator with nth (n=100) image");
    writeln("[", 100 - n, "]: ", toHexString(image));
    Thread.sleep(500.msecs);
}
*/