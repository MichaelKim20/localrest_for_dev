module test;

import std.stdio;
import core.atomic;
import core.time;

import core.sync.condition;
import core.thread;
import core.sync.mutex;
import core.sync.semaphore;

import geod24.tinfo;

void testWaitTimeout()
{
	auto mutex      = new Mutex;
	auto condReady  = new Condition( mutex );
	bool waiting    = false;
	bool alertedOne = true;
	bool alertedTwo = true;

	void waiter()
	{
		synchronized( mutex )
		{
			waiting    = true;
			writeln("wait 1");
			// we never want to miss the notification (30s)
			alertedOne = condReady.wait( dur!"seconds"(30) );
			writeln("wait 2");
			// but we don't want to wait long for the timeout (10ms)
			alertedTwo = condReady.wait( dur!"msecs"(10) );
			writeln("wait 3");
		}
	}

	auto thread = new Thread( &waiter );
	thread.start();

	int count = 0;
	while ( true )
	{
		synchronized( mutex )
		{
			if ( waiting )
			{
				writefln("notify - %s", ++count);
				condReady.notify();
				break;
			}
		}
		Thread.yield();
	}
	thread.join();
	assert( waiting );
	assert( alertedOne );
	assert( !alertedTwo );
}

void test1 ()
{
	auto thread1 = new Thread({
		tinfo.id = "hello";
		while (true)
		{
			writefln("%s", tinfo.id);
		}
	});
	thread1.start();

	auto thread2 = new Thread({
		tinfo.id = "kim";
		while (true)
		{
			writefln("%s", tinfo.id);
		}
	});
	thread2.start();
}

void main()
{
	test1();
}
