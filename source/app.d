module test;

import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;
import C=geod24.concurrency;
import geod24.LocalRest;

import vibe.core.core;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

void main()
{
/*
    writeln(Thread.getThis().id);
    new Thread({
        writeln(Thread.getThis().id);
    }).start();

    C.spawn({
        writeln(Thread.getThis().id);
    });
    */
    //case1();
    //test_scheduler();
    //case2();
    //case5();
    //case6();
    //utest4();

    test1();
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