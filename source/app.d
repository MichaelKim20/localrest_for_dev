module test;

import vibe.data.json;
import geod24.MessageDispatcher;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;

void main()
{
    //thisInfo.self = new MainDispatcher();
    //writefln("%s", ownerMessageDispatcher);
    //writefln("%s", thisScheduler);
    test2();
}

void test1()
{
    import std.concurrency;
    import std.stdio;

    auto process = ()
    {
        size_t message_count = 1;
        while (message_count--)
        {
            thisMessageDispatcher.receive(
                (int i)
                {
                    writefln("Child thread received int: %s", i);
                    ownerMessageDispatcher.send(i);
                },
                (string s)
                {
                    writefln("Child thread received string: %s", s);
                    ownerMessageDispatcher.send(s);
                }
            );
        }
    };

    auto spawnedMessageDispatcher = spawnThread(process);
    //spawnedMessageDispatcher.send(42);
    spawnedMessageDispatcher.send("string");

    //Thread.sleep(3000.msecs);
    // in new API this will drop all messages from the queue which do not match `string`
    thisMessageDispatcher.receive(
        (string s)
        {
             writefln("Main thread received string: %s", s);
        }
    );
/*
    //Thread.sleep(3000.msecs);
    thisMessageDispatcher.receive(
        (int s)
        {
            writefln("Main thread received int: %s", s);
        }
    );
*/
    writeln("Done");
}

void test2()
{
    import std.concurrency;
    import std.stdio;

    auto process = ()
    {
        size_t message_count = 2;
        while (message_count--)
        {
            thisMessageDispatcher.receive(
                (int i)
                {
                    writefln("Child thread received int: %s", i);
                    ownerMessageDispatcher.send(i);
                },
                (string s)
                {
                    writefln("Child thread received string: %s", s);
                    ownerMessageDispatcher.send(s);
                }
            );
        }
    };


    auto spawnedMessageDispatcher = spawnThread(process);
    spawnedMessageDispatcher.send("string");
    spawnedMessageDispatcher.send(42);

/*
    thisMessageDispatcher.receive(
        (int s)
        {
            writefln("Main thread received int: %s", s);
        },
        (string s)
        {
            writefln("Main thread received string: %s", s);
        }
    );
*/
    thisMessageDispatcher.receive(
        (int s)
        {
            writefln("Main thread received int: %s", s);
        }//,
        //(string s)
        //{
        //    writefln("Main thread received string: %s", s);
        //}
    );
    thisMessageDispatcher.receive(
        //(int s)
        //{
        //    writefln("Main thread received int: %s", s);
        //},
        (string s)
        {
            writefln("Main thread received string: %s", s);
        }
    );
    writeln("Done");
    //Thread.sleep(1000.msecs);

}
