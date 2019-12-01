module test;

import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;
import C=geod24.concurrency;

import vibe.core.core;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

void main()
{
//    case1();
    //case2();
    //case3();
    case4();
}

void case1()
{
    Mutex m = new Mutex();
    C.spawn({
        auto scheduler1 = new C.FiberScheduler();
        scheduler1.start({
            scheduler1.spawn({
                while (true)
                {
                    writeln("S1");
                    scheduler1.yield();
                }
            });
            scheduler1.spawn({
                while (true)
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
                while (true)
                {
                    writeln("T3");
                    scheduler2.yield();
                }
            });
            scheduler2.spawn({
                while (true)
                {
                    writeln("T4");
                    scheduler2.yield();
                }
            });
        });
    });
}

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

void case4()
{
    C.scheduler1 = new C.FiberScheduler();

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
            writeln("S3");
            C.scheduler1.yield();
        }
    });

    C.scheduler1.start({
        for (int i = 0; i < 1000; i++)
        {
            writeln("S2");
            C.scheduler1.yield();
        }
    });
}
