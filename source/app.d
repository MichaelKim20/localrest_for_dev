module test;

import geod24.concurrency;
import geod24.Transceiver;
import geod24.LocalRest;

import vibe.data.json;

import std.meta : AliasSeq;
import std.traits : Parameters, ReturnType;

import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time;

import std.stdio;

void main()
{
	test07();
}

// Simulate temporary outage
void test07()
{
    __gshared Transceiver n1transceive;

    static interface API
    {
        public ulong call ();
        public void asyncCall ();
    }
    static class Node : API
    {
        public this()
        {
            if (n1transceive !is null)
                this.remote = new RemoteAPI!API(n1transceive);
        }

        public override ulong call () { return ++this.count; }
        public override void  asyncCall () { runTask(() => cast(void)this.remote.call); }
        size_t count;
        RemoteAPI!API remote;
    }

    writefln("test07-1");
    auto n1 = RemoteAPI!API.spawn!Node();
    n1transceive = n1.ctrl.transceiver;
    auto n2 = RemoteAPI!API.spawn!Node();

    writefln("test07-2");
    /// Make sure calls are *relatively* efficient
    auto current1 = MonoTime.currTime();
    assert(1 == n1.call());
    assert(1 == n2.call());
    auto current2 = MonoTime.currTime();
    assert(current2 - current1 < 200.msecs);

    writefln("test07-3");
    // Make one of the node sleep
    n1.sleep(1.seconds);
    // Make sure our main thread is not suspended,
    // nor is the second node
    assert(2 == n2.call());
    auto current3 = MonoTime.currTime();
    assert(current3 - current2 < 400.msecs);

    writefln("test07-4");
    // Wait for n1 to unblock
    assert(2 == n1.call());
    writefln("test07-4-1");
    // Check current time >= 1 second
    auto current4 = MonoTime.currTime();
    writefln("test07-4-2");
    assert(current4 - current2 >= 1.seconds);

    writefln("test07-5");
    // Now drop many messages
    n1.sleep(1.seconds, true);
    for (size_t i = 0; i < 500; i++)
        n2.asyncCall();
    // Make sure we don't end up blocked forever
    Thread.sleep(1.seconds);
    assert(3 == n1.call());

    writefln("test07-6");
    // Debug output, uncomment if needed
    version (none)
    {
        import std.stdio;
        writeln("Two non-blocking calls: ", current2 - current1);
        writeln("Sleep + non-blocking call: ", current3 - current2);
        writeln("Delta since sleep: ", current4 - current2);
    }

    writefln("test07-7");
    n1.ctrl.shutdown();
    n2.ctrl.shutdown();
    writefln("test07");
}


