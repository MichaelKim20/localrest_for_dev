module test;

import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;
import C=std.concurrency;

import vibe.core.core;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

void main()
{
    //case1();
    case2();
}

void case1()
{
    Mutex m = new Mutex();

    new Thread({
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
    }).start();

    new Thread({
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
    }).start();
}

void case2()
{
    Mutex m = new Mutex();
    auto scheduler1 = new C.FiberScheduler();

    new Thread({
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
    }).start();

    new Thread({
            scheduler1.spawn({
                while (true)
                {
                    writeln("T3");
                    scheduler1.yield();
                }
            });

            scheduler1.spawn({
                while (true)
                {
                    writeln("T4");
                    scheduler1.yield();
                }
            });
    }).start();
}
