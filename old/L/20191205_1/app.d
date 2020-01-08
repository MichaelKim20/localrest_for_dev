module test;

import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;
import C=geod24.concurrency;
import geod24.LocalRest;


void main()
{
    bug1();
}

void bug1()
{
    import std.concurrency;
    import std.stdio;

    auto process = ()
    {
        size_t message_count = 2;
        while (message_count--)
        {
            receive(
                (int i)     { writefln("Child thread received int: %s", i);
                              ownerTid.send(i); },
                (string s)  { writefln("Child thread received string: %s", s);
                              ownerTid.send(s); }
            );
        }
    };

    auto tid = spawn(process);
    send(tid, 42);
    send(tid, "string");

    // REQUIRED in new API
    Thread.sleep(10.msecs);

    // in new API this will drop all messages from the queue which do not match `string`
    receive(
        (string s)  { writefln("Main thread received string: %s", s); }
    );

    receive(
        (int s)  { writefln("Main thread received int: %s", s); }
    );

    writeln("Done");
}

// Simulate temporary outage
void u1()
{
    __gshared C.Tid n1tid;

    static interface API
    {
        public ulong call ();
        public void asyncCall ();
    }
    static class Node : API
    {
        public this()
        {
            if (n1tid != C.Tid.init)
                this.remote = new RemoteAPI!API(n1tid);
        }

        public override ulong call () { return ++this.count; }
        public override void  asyncCall () { runTask(() => cast(void)this.remote.call); }
        size_t count;
        RemoteAPI!API remote;
    }

    auto n1 = RemoteAPI!API.spawn!Node();
    n1tid = n1.tid();
    auto n2 = RemoteAPI!API.spawn!Node();

    /// Make sure calls are *relatively* efficient
    auto current1 = MonoTime.currTime();
    assert(1 == n1.call());
    assert(1 == n2.call());
    auto current2 = MonoTime.currTime();
    assert(current2 - current1 < 200.msecs);

    // Make one of the node sleep
    n1.sleep(1.seconds);
    // Make sure our main thread is not suspended,
    // nor is the second node
    assert(2 == n2.call());
    auto current3 = MonoTime.currTime();
    assert(current3 - current2 < 400.msecs);

    // Wait for n1 to unblock
    assert(2 == n1.call());
    // Check current time >= 1 second
    auto current4 = MonoTime.currTime();
    assert(current4 - current2 >= 1.seconds);

    // Now drop many messages
    n1.sleep(3.seconds, true);
    for (size_t i = 0; i < 100; i++)
        n2.asyncCall();
    // Make sure we don't end up blocked forever
    Thread.sleep(3.seconds);
    auto res = n1.call();
    assert(3 == res);

    // Debug output, uncomment if needed
    version (none)
    {
        import std.stdio;
        writeln("Two non-blocking calls: ", current2 - current1);
        writeln("Sleep + non-blocking call: ", current3 - current2);
        writeln("Delta since sleep: ", current4 - current2);
    }

    n1.ctrl.shutdown();
    n2.ctrl.shutdown();
}

// Filter commands
void u2()
{
    __gshared C.Tid node_tid;

    static interface API
    {
        size_t fooCount();
        size_t fooIntCount();
        size_t barCount ();
        void foo ();
        void foo (int);
        void bar (int);  // not in any overload set
        void callBar (int);
        void callFoo ();
        void callFoo (int);
    }

    static class Node : API
    {
        size_t foo_count;
        size_t foo_int_count;
        size_t bar_count;
        RemoteAPI!API remote;

        public this()
        {
            this.remote = new RemoteAPI!API(node_tid);
        }

        override size_t fooCount() { return this.foo_count; }
        override size_t fooIntCount() { return this.foo_int_count; }
        override size_t barCount() { return this.bar_count; }
        override void foo () { ++this.foo_count; }
        override void foo (int) { ++this.foo_int_count; }
        override void bar (int) { ++this.bar_count; }  // not in any overload set
        // This one is part of the overload set of the node, but not of the API
        // It can't be accessed via API and can't be filtered out
        void bar(string) { assert(0); }

        override void callFoo()
        {
            try
            {
                this.remote.foo();
            }
            catch (Exception ex)
            {
                assert(ex.msg == "Filtered method 'foo()'");
            }
        }

        override void callFoo(int arg)
        {
            try
            {
                this.remote.foo(arg);
            }
            catch (Exception ex)
            {
                assert(ex.msg == "Filtered method 'foo(int)'");
            }
        }

        override void callBar(int arg)
        {
            try
            {
                this.remote.bar(arg);
            }
            catch (Exception ex)
            {
                assert(ex.msg == "Filtered method 'bar(int)'");
            }
        }
    }

    auto filtered = RemoteAPI!API.spawn!Node();
    node_tid = filtered.tid();

    // caller will call filtered
    auto caller = RemoteAPI!API.spawn!Node();
    caller.callFoo();
    assert(filtered.fooCount() == 1);

    // both of these work
    static assert(is(typeof(filtered.filter!(API.foo))));
    static assert(is(typeof(filtered.filter!(filtered.foo))));

    // only method in the overload set that takes a parameter,
    // should still match a call to filter with no parameters
    static assert(is(typeof(filtered.filter!(filtered.bar))));

    // wrong parameters => fail to compile
    static assert(!is(typeof(filtered.filter!(filtered.bar, float))));
    // Only `API` overload sets are considered
    static assert(!is(typeof(filtered.filter!(filtered.bar, string))));

    filtered.filter!(API.foo);

    caller.callFoo();
    assert(filtered.fooCount() == 1);  // it was not called!

    filtered.clearFilter();  // clear the filter
    caller.callFoo();
    assert(filtered.fooCount() == 2);  // it was called!

    // verify foo(int) works first
    caller.callFoo(1);
    assert(filtered.fooCount() == 2);
    assert(filtered.fooIntCount() == 1);  // first time called

    // now filter only the int overload
    filtered.filter!(API.foo, int);

    // make sure the parameterless overload is still not filtered
    caller.callFoo();
    assert(filtered.fooCount() == 3);  // updated

    caller.callFoo(1);
    assert(filtered.fooIntCount() == 1);  // call filtered!

    // not filtered yet
    caller.callBar(1);
    assert(filtered.barCount() == 1);

    filtered.filter!(filtered.bar);
    caller.callBar(1);
    assert(filtered.barCount() == 1);  // filtered!

    // last blocking calls, to ensure the previous calls complete
    filtered.clearFilter();
    caller.foo();
    caller.bar(1);

    filtered.ctrl.shutdown();
    caller.ctrl.shutdown();
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

    scope test = RemoteAPI!API.spawn!MockAPI();
    writeln(test.pubkey());
    test.ctrl.shutdown();
}

void test2()
{
    auto tid = C.spawn ({
        int i;
        while (i < 9)
        {
            C.receive((int res) {
                i = res;
            });
        }
        C.send(C.ownerTid, i * 2);
    });

    auto r = new C.Generator!int ({
        foreach (i; 1 .. 10)
            C.yield(i);
    });

    foreach (e; r)
        C.send(tid, e);

    C.receive((int res) {
        assert(res == 18);
    });
}

void case1()
{
    C.spawn({
        auto scheduler1 = new C.FiberScheduler();
        scheduler1.start({
            scheduler1.spawn({
                for (int i = 0; i < 5; i++)
                {
                    writeln("S1");
                    scheduler1.yield();
                }
            });
            scheduler1.spawn({
                for (int i = 0; i < 5; i++)
                {
                    writeln("S2");
                    scheduler1.yield();
                }
            });
        });
    });

    C.spawn({
        auto scheduler2 = new C.FiberScheduler();
        scheduler2.start({
            scheduler2.spawn({
                for (int i = 0; i < 5; i++)
                {
                    writeln("T3");
                    scheduler2.yield();
                }
            });
            scheduler2.spawn({
                for (int i = 0; i < 5; i++)
                {
                    writeln("T4");
                    scheduler2.yield();
                }
            });
        });
    });
}

void test_scheduler()
{
    auto scheduler = new C.AutoDispatchScheduler();

    Thread.sleep(3.seconds);

    scheduler.stop();

    Thread.sleep(3.seconds);
}

void case2()
{
    C.spawn({
        auto scheduler1 = new C.FiberScheduler();
        scheduler1.start({
            scheduler1.spawn({
                for (int i = 0; i < 5; i++)
                {
                    writeln("S1");
                    scheduler1.yield();
                }
            });
            scheduler1.spawn({
                for (int i = 0; i < 5; i++)
                {
                    writeln("S2");
                    scheduler1.yield();
                }
            });
        });
    });
}

void case5()
{
    auto tid1 = C.spawnThread({
        writefln("C.thisInfo.ident1  : %s", C.thisTid);
        C.spawnFiber({
            for (int i = 0; i < 5; i++)
            {
                writeln("S3");
                C.thisScheduler.yield();
            }
        });
        C.spawnFiber({
            for (int i = 0; i < 5; i++)
            {
                writeln("S4");
                C.thisScheduler.yield();
            }
        });
    });
    writefln("tid1  : %s", tid1);
    writeln("case5");
}

void case6()
{
    writeln("case6");
    C.spawnFiber({
        for (int i = 0; i < 5; i++)
        {
            writefln("S3 %s", C.thisScheduler);
            C.thisScheduler.yield();
        }
    });
    C.spawnFiber({
        for (int i = 0; i < 5; i++)
        {
            writefln("S4 %s", C.thisScheduler);
            C.thisScheduler.yield();
        }
    });
    writeln("case6");
}


void utest4()
{
    //writeln("test4");
    //import core.thread : thread_joinAll;

    __gshared string receivedMessage;
    static void f1(string msg)
    {
        //writeln("test4 ", msg);
        receivedMessage = msg;
        //writeln("test4 ", receivedMessage);
    }

    auto tid1 = C.spawn(&f1, "Hello World");
    //writeln("test4");
    //thread_joinAll;
    //Thread.sleep(1.seconds);
    assert(receivedMessage == "Hello World");
    //writeln("test4");
}

