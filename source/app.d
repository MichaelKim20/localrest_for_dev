module test;

import std.stdio;
import core.atomic;
import core.time;

import core.sync.condition;
import core.thread;
import core.sync.mutex;
import core.sync.semaphore;

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

void test2 ()
{
	auto m = new Mutex();
	auto cond = new Condition(m);
	auto thread1 = new Thread({
			writefln("wait");
			m.lock();
			cond.wait();
			m.unlock();
			writefln("doing");
	});
	thread1.start();

	Thread.sleep(1.seconds);
	writefln("notify");
	cond.notifyAll();

	Thread.sleep(5.seconds);
}

void main()
{
	test2();
}
