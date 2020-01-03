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
	test12();
}

void test12()
{
// Simulate temporary outage
	__gshared ServerTransceiver n1transceive;

	static interface API
	{
		public ulong call ();
		public void asyncCall ();
	}
	static class Node : API
	{
		public this()
		{
			writefln("n1transceive : %s", n1transceive);
			if (n1transceive !is null)
			{
				writefln("create remote");
				this.remote = new RemoteAPI!API(n1transceive);
			}
		}

		public override ulong call ()
		{
			return ++this.count;
		}

		public override void asyncCall ()
		{
			thisScheduler.spawn({
				this.remote.call();
			});
		}

		size_t count;
		RemoteAPI!API remote;
	}

	writeln("test 1-1");
	n1transceive = null;

	writeln("test 1-2");
	auto n1 = RemoteAPI!API.spawn!Node();
	writeln("test 1-3");
	n1transceive = n1.ctrl.transceiver;
	writeln("test 1-4");
	auto n2 = RemoteAPI!API.spawn!Node();
	writeln("test 1-5");

	writeln("test 2");
	/// Make sure calls are *relatively* efficient
	auto current1 = MonoTime.currTime();
	assert(1 == n1.call());
	assert(1 == n2.call());
	auto current2 = MonoTime.currTime();
	assert(current2 - current1 < 200.msecs);

	writeln("test 3");
	// Make one of the node sleep
	n1.sleep(1.seconds);
	// Make sure our main thread is not suspended,
	// nor is the second node
	assert(2 == n2.call());
	auto current3 = MonoTime.currTime();
	assert(current3 - current2 < 400.msecs);

	writeln("test 4");
	// Wait for n1 to unblock
	assert(2 == n1.call());
	writeln("test 4-1");
	// Check current time >= 1 second
	auto current4 = MonoTime.currTime();
	writeln("test 4-2");
	assert(current4 - current2 >= 1.seconds);

	writeln("test 5");
	// Now drop many messages
	n1.sleep(1.seconds, true);
	for (size_t i = 0; i < 500; i++)
		n2.asyncCall();
	writeln("test 5-1");
	// Make sure we don't end up blocked forever
	Thread.sleep(1.seconds);
	//assert(3 == n1.call());

	writeln("test 6");
	// Debug output, uncomment if needed
	version (none)
	{
		import std.stdio;
		writeln("Two non-blocking calls: ", current2 - current1);
		writeln("Sleep + non-blocking call: ", current3 - current2);
		writeln("Delta since sleep: ", current4 - current2);
	}

	writeln("test 7");
	//n1.stopRemote();
	//n2.stopRemote();
	n1.ctrl.shutdown();
	n2.ctrl.shutdown();
	writeln("test 8");

}

void test13 ()
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
        this(ServerTransceiver masterTransceiver)
        {
            this.master = new RemoteAPI!API(masterTransceiver);
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

    RemoteAPI!API[4] nodes;
    auto master = RemoteAPI!API.spawn!MasterNode();
    nodes[0] = master;
    nodes[1] = RemoteAPI!API.spawn!SlaveNode(master.transceiver);
    nodes[2] = RemoteAPI!API.spawn!SlaveNode(master.transceiver);
    nodes[3] = RemoteAPI!API.spawn!SlaveNode(master.transceiver);

    foreach (n; nodes)
    {
        assert(n.requests() == 0);
        assert(n.value() == 42);
    }

    assert(nodes[0].requests() == 4);

    foreach (n; nodes[1 .. $])
    {
        assert(n.value() == 42);
        assert(n.requests() == 2);
    }

    assert(nodes[0].requests() == 7);
    import std.algorithm;
    nodes.each!(node => node.ctrl.shutdown());

}

void test14()
{
    import geod24.Transceiver;
    import std.exception;

    __gshared ServerTransceiver node_transceiver;

    static interface API
    {
        void check ();
        int ping ();
    }

    static class Node : API
    {
        override int ping () { return 42; }

        override void check ()
        {
            auto node = new RemoteAPI!API(node_transceiver, 500.msecs);

            // no time-out
            node.ctrl.sleep(10.msecs);
            assert(node.ping() == 42);

            // time-out
            //node.ctrl.sleep(2000.msecs);
            //assertThrown!Exception(node.ping());
        }
    }

    auto node_1 = RemoteAPI!API.spawn!Node();
    auto node_2 = RemoteAPI!API.spawn!Node();
    node_transceiver = node_2.ctrl.transceiver;
    node_1.check();
    node_1.ctrl.shutdown();
    node_2.ctrl.shutdown();
}