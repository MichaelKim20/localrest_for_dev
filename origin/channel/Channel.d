/*******************************************************************************

    This file contains the implementation of channels.
    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module geod24.Channel;

import std.container;
import std.range;
import std.Variant;

import core.sync.mutex;
import core.thread;

/*******************************************************************************

    This channel has queues that senders and receivers can wait for.
    With these queues, a single thread alone can exchange data with each other.

    This channel use `NonBlockingQueue`. This is not uses `Lock`
    A channel is a communication class using which fiber can communicate
    with each other.
    Technically, a channel is a data transfer pipe where data can be passed
    into or read from.
    Hence one fiber can send data into a channel, while other fiber can read
    that data from the same channel

*******************************************************************************/

public class Channel (T)
{
    /// closed
    private bool closed;

    /// lock
    private Mutex mutex;

    /// size of queue
    private size_t qsize;

    /// queue of data
    private DList!T queue;

    /// collection of send waiters
    private DList!(SudoFiber!(T)) sendq;

    /// collection of recv waiters
    private DList!(SudoFiber!(T)) recvq;


    /// Ctor
    public this (size_t qsize = 0)
    {
        this.closed = false;
        this.mutex = new Mutex;
        this.qsize = qsize;
    }

    /***************************************************************************

        Send data `elem`.
        First, check the receiving waiter that is in the `recvq`.
        If there are no targets there, add data to the `queue`.
        If queue is full then stored waiter(fiber) to the `sendq`.

        Params:
            elem = value to send

        Return:
            true if the sending is successful, otherwise false

    ***************************************************************************/

    public bool send (T elem)
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();
            return false;
        }

        if (this.recvq[].walkLength > 0)
        {
            SudoFiber!T sf = this.recvq.front;
            this.recvq.removeFront();

            this.mutex.unlock();

            *(sf.elem_ptr) = elem;
            
            if (sf.fiber !is null)
                sf.fiber.call();
            else if (sf.swdg !is null)
                sf.swdg();

            return true;
        }

        if (this.queue[].walkLength < this.qsize)
        {
            this.queue.insertBack(elem);
            this.mutex.unlock();
            return true;
        }

        Fiber fiber = Fiber.getThis();
        if (fiber !is null)
        {
            SudoFiber!T new_sf;
            new_sf.fiber = fiber;
            new_sf.elem_ptr = null;
            new_sf.elem = elem;
            this.sendq.insertBack(new_sf);

            this.mutex.unlock();

            Fiber.yield();
        }
        else
        {
            shared(bool) is_waiting = true;
            void stopWait() {
                is_waiting = false;
            }
            SudoFiber!T new_sf;
            new_sf.fiber = null;
            new_sf.elem_ptr = null;
            new_sf.elem = elem;
            new_sf.swdg = &stopWait;

            this.sendq.insertBack(new_sf);

            this.mutex.unlock();

            while (is_waiting)
                Thread.sleep(dur!("msecs")(1));
        }

        return true;
    }

    /***************************************************************************

        Write the data received in `elem`

        Params:
            elem = value to receive

        Return:
            true if the receiving is successful, otherwise false

    ***************************************************************************/

    public bool receive (T* elem)
    {
        this.mutex.lock();

        if (this.closed)
        {
            (*elem) = T.init;
            this.mutex.unlock();

            return false;
        }

        if (this.sendq[].walkLength > 0)
        {
            SudoFiber!T sf = this.sendq.front;
            this.sendq.removeFront();

            this.mutex.unlock();

            *(elem) = sf.elem;

            if (sf.fiber !is null)
                sf.fiber.call();
            else if (sf.swdg !is null)
                sf.swdg();

            return true;
        }

        if (this.queue[].walkLength > 0)
        {
            *(elem) = this.queue.front;
            this.queue.removeFront();

            this.mutex.unlock();

            return true;
        }

        Fiber fiber = Fiber.getThis();
        if (fiber !is null)
        {
            SudoFiber!T new_sf;
            new_sf.fiber = fiber;
            new_sf.elem_ptr = elem;

            this.recvq.insertBack(new_sf);

            this.mutex.unlock();

            Fiber.yield();
        }
        else
        {
            shared(bool) is_waiting = true;
            void stopWait() {
                is_waiting = false;
            }
            SudoFiber!T new_sf;
            new_sf.fiber = fiber;
            new_sf.elem_ptr = elem;
            new_sf.swdg = &stopWait;

            this.recvq.insertBack(new_sf);

            this.mutex.unlock();

            while (is_waiting)
                Thread.sleep(dur!("msecs")(1));
        }

        return true;
    }

    /***************************************************************************

        Return closing status

        Return:
            true if channel is closed, otherwise false

    ***************************************************************************/

    public @property bool isClosed () @safe @nogc pure
    {
        synchronized (this.mutex)
        {
            return this.closed;
        }
    }

    /***************************************************************************

        Close channel

    ***************************************************************************/

    public void close ()
    {
        SudoFiber!T sf;
        bool res;

        this.mutex.lock();
        scope (exit) this.mutex.unlock();

        this.closed = true;

        while (true)
        {
            if (this.recvq[].walkLength == 0)
                break;

            sf = this.recvq.front;
            this.recvq.removeFront();
            //if (sf.fiber !is null)
            //    sf.fiber.call();
            //else if (sf.swdg !is null)
            //    sf.swdg();
        }

        while (true)
        {
            if (this.sendq[].walkLength == 0)
                break;

            sf = this.sendq.front;
            this.sendq.removeFront();
            //if (sf.fiber !is null)
            //    sf.fiber.call();
            //else if (sf.swdg !is null)
            //    sf.swdg();
        }
    }
}

private alias StopWaitDg = void delegate ();

///
private struct SudoFiber (T)
{
    public Fiber fiber;
    public T* elem_ptr;
    public T  elem;
    public StopWaitDg swdg;
}
/*
/// In single thread
/// Call 'receive' first. Then the `Fiber` will  register in the queue.
/// Next, when the send is called, the `Fiber` in the queue receives the data.
/// Without a queue, it's impossible on a single thread.
unittest
{
    Channel!int channel = new Channel!int(10);

    new Fiber(
    {
        int res;
        channel.receive(&res);
        assert(res == 42);
    }).call();

    channel.send(42);
}

/// If the size of the data buffer is zero,
/// It blocks after calling the send.
/// To solve the blocking, there is a way to generate
/// and register Fiber from the Thread.
unittest
{
    Channel!int channel = new Channel!int(0);

    //channel.send(42); // => to be block
    //int res;
    //channel.receive(&res);
}

/// If the size of the data buffer is zero,
/// If you call it using a fiber, it won't block.
unittest
{
    Channel!int channel = new Channel!int(0);

    new Fiber(
    {
        channel.send(42);
    }).call();

    int res;
    channel.receive(&res);
    assert(res == 42);
}

/// The size of the data buffer is 10
unittest
{
    Channel!int channel = new Channel!int(10);

    foreach (int idx; 0 .. 10)
        channel.send(idx);

    int res;
    int expect = 0;
    foreach (int idx; 0 .. 10)
    {
        channel.receive(&res);
        assert(res == expect++);
    }
}

/// Multi-thread data type is int
unittest
{
    Channel!int in_channel = new Channel!int(5);
    Channel!int out_channel = new Channel!int(5);

    new Thread({
        int x;
        in_channel.receive(&x);
        out_channel.send(x * x * x);
    }).start();

    in_channel.send(3);
    int res;
    out_channel.receive(&res);
    assert(res == 27);
}

/// Multi-thread data type is string
unittest
{
    Channel!string in_channel = new Channel!string(5);
    Channel!string out_channel = new Channel!string(5);

    new Thread({
        string name;
        in_channel.receive(&name);
        string greeting = "Hi " ~ name;
        out_channel.send(greeting);
    }).start();

    in_channel.send("Tom");
    string res;
    out_channel.receive(&res);
    assert(res == "Hi Tom");
}

/// When the channel is closed, `receive` returns false;
unittest
{
    Channel!int channel = new Channel!int(5);

    int res;
    channel.send(1);
    assert(channel.receive(&res));

    channel.send(3);
    channel.close();
    assert(!channel.receive(&res));
}

/// Multi fiber, single thread data type is int
unittest
{
    Channel!int in_channel = new Channel!int(5);
    Channel!int out_channel = new Channel!int(5);

    auto fiber1 = new Fiber(
    {
        int res;
        while (true)
        {
            in_channel.receive(&res);
            out_channel.send(res*res);
        }
    });
    fiber1.call();

    auto fiber2 = new Fiber(
    {
        int res;
        foreach (int idx; 1 .. 10)
        {
            in_channel.send(idx);
            out_channel.receive(&res);
            assert(res == idx*idx);
        }
    });
    fiber2.call();
}

/// Send data `Thread` to `Fiber`
unittest
{
    Channel!int channel = new Channel!int(5);

    auto fiber = new Fiber(
    {
        int res;
        int expect = 1;
        while (true)
        {
            channel.receive(&res);
            assert(res == expect++);
        }
    });
    fiber.call();

    auto thread = new Thread(
    {
        foreach (int idx; 1 .. 10)
            channel.send(idx);
        channel.close();
    });
    thread.start();
}

/// Send data `Fiber` to `Thread`
unittest
{
    Channel!int channel = new Channel!int(5);

    auto fiber = new Fiber(
    {
        foreach (int idx; 1 .. 10)
        {
            channel.send(idx);
        }
        channel.close();
    });
    fiber.call();

    auto thread = new Thread(
    {
        int expect = 1;
        while (true)
        {
            int res;
            channel.receive(&res);
            assert(res == expect++);
        }
    });
    thread.start();
}

// Benchmark of NonBlockingChannel and Channel
version (none)
unittest
{
    ///  Start `writers` amount of threads to write into a queue.
    ///  Start `readers` amount of threads to read from the queue.
    ///  Each writer counts from 0 to `count` and sends each number into the queue.
    ///  The sum is checked at the end.
    void test_run(Channel!int channel, uint writers, uint readers, uint count)
    {
        import std.bigint : BigInt;
        import std.range;

        import core.thread;

        immutable(BigInt) correct_sum = BigInt(count) * BigInt(count-1) / 2 * writers;

        BigInt sum = 0;

        auto write_worker = ()
        {
            Thread[] ts;
            foreach (i; 0 .. writers)
            {
                auto t = new Thread(
                    {
                        foreach (n; 1 .. count)
                            channel.send(n);
                    }
                );
                t.start();
                ts ~= t;
            }

            foreach (t; ts)
                t.join();
        };

        auto read_worker = ()
        {
            Thread[] ts;
            foreach (i; 0 .. readers)
            {
                auto t = new Thread(
                    {
                        BigInt s = 0;
                        foreach (_; 1 .. count)
                        {
                            int n;
                            channel.receive(&n);
                            s += n;
                        }
                        synchronized { sum += s; }
                    }
                );
                t.start();
                ts ~= t;
            }

            foreach (t; ts)
                t.join();
        };

        auto w = new Thread(write_worker);
        auto r = new Thread(read_worker);

        w.start();
        r.start();

        w.join();
        r.join();

        assert(sum == correct_sum);
    }
    enum readers = 10;
    enum writers = 10;
    enum count = 1000;

    void f0 ()
    {
        Channel!int channel = new Channel!int(10);
        test_run(channel, writers, readers, count);
    }

    void f1 ()
    {
        Channel!int channel = new Channel!int(20);
        test_run(channel, writers, readers, count);
    }

    void f2 ()
    {
        Channel!int channel = new Channel!int(50);
        test_run(channel, writers, readers, count);
    }

    import std.datetime.stopwatch : benchmark;
    auto r = benchmark!(f0, f1, f2)(3);

    import std.stdio;
    writeln(r[0]);
    writeln(r[1]);
    writeln(r[2]);
}
*/

/// Multi fiber, single thread data type is int
unittest
{
    Channel!Variant in_channel = new Channel!Variant(5);
    Channel!Variant out_channel = new Channel!Variant(5);

    auto fiber1 = new Fiber(
    {
        Variant res;
        while (true)
        {
            in_channel.receive(&res);
            out_channel.send(Variant(res*res));
        }
    });
    fiber1.call();

    auto fiber2 = new Fiber(
    {
        Variant res;
        foreach (int idx; 1 .. 10)
        {
            in_channel.send(Variant(idx));
            out_channel.receive(&res);
            assert(res == idx*idx);
        }
    });
    fiber2.call();
}
