module test;

import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;
import C=geod24.concurrency;
//import geod24.LocalRest;

import vibe.core.core;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

void main()
{
    //test1();
    //case1();
    //case2();
    //case3();
    //case4();
    case5();
    //case6();
}
/*
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
*/
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
/*
void case2()
{
    Mutex m = new Mutex();

    C.spawn({
        C.scheduler1 = new C.FiberScheduler();
        C.scheduler1.start({
            C.scheduler1.spawn({
                auto cond = C.scheduler1.newCondition(null);
                for (int i = 0; i < 1000; i++)
                {
                    writeln("S111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111");
                    C.scheduler1.yield();
                    cond.wait(10.msecs);
                }
            });
        });
    });

    C.spawn({
        C.scheduler2 = new C.FiberScheduler();
        C.scheduler2.start({
            C.scheduler2.spawn({
                auto cond = C.scheduler2.newCondition(null);
                for (int i = 0; i < 1000; i++)
                {
                    writeln("T33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333");
                    C.scheduler2.yield();
                    cond.wait(10.msecs);
                }
            });
        });
    });
}

void case3()
{
    C.scheduler1 = new C.FiberScheduler();
    C.scheduler1.start({
        {
            C.scheduler1.spawn({
                for (int i = 0; i < 1000; i++)
                {
                    writeln("S1");
                    C.scheduler1.yield();
                }
            });
            C.scheduler1.spawn({
                for (int i = 0; i < 1000; i++)
                {
                    writeln("S2");
                    C.scheduler1.yield();
                }
            });
        }
    });
}
*/

void case5()
{
    writeln("case5");

    C.scheduler1 = new C.NodeScheduler();

    auto tid1 = C.spawnThread({
        writefln("C.thisInfo.ident1  : %s", C.thisTid);
        auto a = C.spawnFiber({
            for (int i = 0; i < 5; i++)
            {
                writeln("S3");
                C.scheduler1.yield();
            }
        });
    });
    writefln("tid1  : %s", tid1);


    writeln("case5");
}

void case6()
{
    writeln("case5");

    C.scheduler1 = new C.NodeScheduler();

    auto tid1 = C.spawn({
        C.scheduler1.start({
            C.scheduler1.spawn({
                writefln("C.thisInfo.ident1  : %s", C.thisTid);
                for (int i = 0; i < 5; i++)
                {
                    C.scheduler1.yield();
                }
            });
        });
    });
    writefln("tid1  : %s", tid1);
    auto tid2 = C.spawn({
        C.scheduler1.start({
            C.scheduler1.spawn({
                writefln("C.thisInfo.ident2  : %s", C.thisTid);
                for (int i = 0; i < 5; i++)
                {
                    C.scheduler1.yield();
                }
            });
        });
    });
    writefln("tid2  : %s", tid2);
}