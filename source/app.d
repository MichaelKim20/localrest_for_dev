/+ dub.sdl:
	name "test"
	description "Tests vibe.d's std.concurrency integration"
	dependency "vibe-core" path="../"
+/
module test;

import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

import core.atomic;
import core.time;
import core.stdc.stdlib : exit;

//import agora.common.LocalRest;
import std.stdio;
import vibe.data.json;
/*
void main()
{
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

    scope test = new RemoteAPI!(API, MockAPI)();

    auto value = test.pubkey();
    
    import std.stdio;
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