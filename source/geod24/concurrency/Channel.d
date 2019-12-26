/*******************************************************************************

    This channel has queues that senders and receivers can wait for.
    With these queues, a single thread alone can exchange data with each other.

    Technically, a channel is a data trancontexter pipe where data can be passed
    into or read from.
    Hence one fiber(thread) can send data into a channel, while other fiber(thread)
    can read that data from the same channel

*******************************************************************************/

module geod24.concurrency.Channel;

import geod24.concurrency.Exception;
import geod24.concurrency.Scheduler;

import std.container;
import std.range;
import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;
import core.thread;

/// Ditto
public class Channel (T)
{
    /// closed
    private bool closed;

    /// lock for queue and status
    private Mutex mutex;

    /// lock for wait
    private Mutex waiting_mutex;

    /// size of queue
    private size_t qsize;

    /// queue of data
    private DList!T queue;


    /// collection of send waiters
    private DList!(ChannelContext!T) sendq;

    /// collection of recv waiters
    private DList!(ChannelContext!T) recvq;

    /// Ctor
    public this (size_t qsize = 0)
    {
        this.closed = false;
        this.mutex = new Mutex;
        this.waiting_mutex = new Mutex;
        this.qsize = qsize;
    }

    /***************************************************************************

        Send data `msg`.
        First, check the receiving waiter that is in the `recvq`.
        If there are no targets there, add data to the `queue`.
        If queue is full then stored waiter(fiber) to the `sendq`.

        Params:
            msg = value to send

        Return:
            true if the sending is succescontextul, otherwise false

    ***************************************************************************/

    public bool send (T msg)
    in
    {
        assert(thisScheduler !is null,
            "Cannot put a message until a scheduler was created ");
    }
    do
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();
            return false;
        }

        if (this.recvq[].walkLength > 0)
        {
            ChannelContext!T context = this.recvq.front;
            this.recvq.removeFront();
            *(context.msg_ptr) = msg;
            this.mutex.unlock();

            if (context.condition !is null)
                synchronized(this.waiting_mutex)
                    context.condition.notify();

            return true;
        }

        if (this.queue[].walkLength < this.qsize)
        {
            this.queue.insertBack(msg);
            this.mutex.unlock();
            return true;
        }

        {
            ChannelContext!T new_context;
            new_context.msg_ptr = null;
            new_context.msg = msg;
            new_context.condition = thisScheduler.newCondition(this.waiting_mutex);

            this.sendq.insertBack(new_context);
            this.mutex.unlock();

            synchronized(this.waiting_mutex)
                new_context.condition.wait();
        }

        return true;
    }

    /***************************************************************************

        Return the received message.

        Return:
            msg = value to receive

    ***************************************************************************/

    public T receive ()
    in
    {
        assert(thisScheduler !is null,
            "Cannot get a message until a scheduler was created ");
    }
    do
    {
        T res;
        T *msg = &res;

        this.mutex.lock();

        if (this.closed)
        {
            (*msg) = T.init;
            this.mutex.unlock();
            throw new ChannelClosed();
        }

        if (this.sendq[].walkLength > 0)
        {
            ChannelContext!T context = this.sendq.front;
            this.sendq.removeFront();
            *(msg) = context.msg;
            this.mutex.unlock();

            if (context.condition !is null)
                synchronized(this.waiting_mutex)
                    context.condition.notify();

            return res;
        }

        if (this.queue[].walkLength > 0)
        {
            *(msg) = this.queue.front;
            this.queue.removeFront();

            this.mutex.unlock();

            return res;
        }

        {
            ChannelContext!T new_context;
            new_context.msg_ptr = msg;
            new_context.condition = thisScheduler.newCondition(this.waiting_mutex);

            this.recvq.insertBack(new_context);
            this.mutex.unlock();

            synchronized(this.waiting_mutex)
                new_context.condition.wait();
        }

        return res;
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

        Close Channel

    ***************************************************************************/

    public void close ()
    {
        ChannelContext!T context;

        this.mutex.lock();
        scope (exit) this.mutex.unlock();

        this.closed = true;

        while (true)
        {
            if (this.recvq[].walkLength == 0)
                break;

            context = this.recvq.front;
            this.recvq.removeFront();

            if (context.condition !is null)
                synchronized(this.waiting_mutex)
                    context.condition.notify();
        }

        this.queue.clear();

        while (true)
        {
            if (this.sendq[].walkLength == 0)
                break;

            context = this.sendq.front;
            this.sendq.removeFront();

            if (context.condition !is null)
                synchronized(this.waiting_mutex)
                    context.condition.notify();
        }
    }
}

/// A structure to be stored in a queue. It has information to use in standby.
private struct ChannelContext (T)
{
    /// This is a message. Used in put
    public T  msg;

    /// This is a message point. Used in get
    public T* msg_ptr;

    //  Waiting Condition
    public Condition condition;
}

/// Fiber1 -> [ channel2 ] -> Fiber2 -> [ channel1 ] -> Fiber1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;
    bool done = false;

    auto m = new Mutex;
    auto c = thread_scheduler.newCondition(m);

    // Thread1
    thread_scheduler.spawn({
        auto fiber_scheduler = new FiberScheduler();
        fiber_scheduler.start({
            //  Fiber1
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                channel2.send(2);
                result = channel1.receive();
                synchronized (m)
                {
                    c.notify();
                }
            });
            //  Fiber2
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                int res = channel2.receive();
                channel1.send(res*res);
            });
        });
    });

    synchronized (m)
    {
        assert(c.wait(1000.msecs));
        assert(result == 4);
    }
}

/// Fiber1 in Thread1 -> [ channel2 ] -> Fiber2 in Thread2 -> [ channel1 ] -> Fiber1 in Thread1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result;

    auto m = new Mutex;
    auto c = thread_scheduler.newCondition(m);

    // Thread1
    thread_scheduler.spawn({
        auto fiber_scheduler = new FiberScheduler();
        // Fiber1
        fiber_scheduler.start({
            thisScheduler = fiber_scheduler;
            channel2.send(2);
            result = channel1.receive();
            synchronized (m)
            {
                c.notify();
            }
        });
    });

    // Thread2
    thread_scheduler.spawn({
        auto fiber_scheduler = new FiberScheduler();
        // Fiber2
        fiber_scheduler.start({
            thisScheduler = fiber_scheduler;
            int res = channel2.receive();
            channel1.send(res*res);
        });
    });

    synchronized (m)
    {
        assert(c.wait(1000.msecs));
        assert(result == 4);
    }
}

/// Thread1 -> [ channel2 ] -> Thread2 -> [ channel1 ] -> Thread1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result;
    int max = 100;
    bool terminate = false;

    auto m = new Mutex;
    auto c = thread_scheduler.newCondition(m);

    // Thread1
    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        foreach (idx; 1 .. max+1)
        {
            channel2.send(idx);
            result = channel1.receive();
            assert(result == idx*idx);
        }
        synchronized (m)
        {
            terminate = true;
            c.notify();
        }
    });

    // Thread2
    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        int res;
        while (!terminate)
        {
            res = channel2.receive();
            channel1.send(res*res);
         }
    });

    synchronized (m)
    {
        assert(c.wait(5000.msecs));
        assert(result == max*max);
    }
    channel1.close();
    channel2.close();
}

/// Thread1 -> [ channel2 ] -> Fiber1 in Thread 2 -> [ channel1 ] -> Thread1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result;

    auto m = new Mutex;
    auto c = thread_scheduler.newCondition(m);

    // Thread1
    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        channel2.send(2);
        result = channel1.receive();
        synchronized (m)
        {
            c.notify();
        }
    });

    // Thread2
    thread_scheduler.spawn({
        auto fiber_scheduler = new FiberScheduler();
        // Fiber1
        fiber_scheduler.start({
            thisScheduler = fiber_scheduler;
            auto res = channel2.receive();
            channel1.send(res*res);
        });
    });

    synchronized (m)
    {
        assert(c.wait(3000.msecs));
        assert(result == 4);
    }
}

// If the queue size is 0, it will block when it is sent and received on the same thread.
unittest
{
    auto channel_qs0 = new Channel!int(0);
    auto channel_qs1 = new Channel!int(1);
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;

    auto m = new Mutex;
    auto c = thread_scheduler.newCondition(m);

    // Thread1 - It'll be tangled.
    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        channel_qs0.send(2);
        result = channel_qs0.receive();
        synchronized (m)
        {
            c.notify();
        }
    });

    synchronized (m)
    {
        assert(!c.wait(1000.msecs));
        assert(result == 0);
    }

    // Thread2 - Unravel a tangle
    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        result = channel_qs0.receive();
        channel_qs0.send(2);
    });

    synchronized (m)
    {
        assert(c.wait(1000.msecs));
        assert(result == 2);
    }

    result = 0;
    // Thread3 - It'll not be tangled, because queue size is 1
    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        channel_qs1.send(2);
        result = channel_qs1.receive();
        synchronized (m)
        {
            c.notify();
        }
    });

    synchronized (m)
    {
        assert(c.wait(1000.msecs));
        assert(result == 2);
    }
}

// If the queue size is 0, it will block when it is sent and received on the same fiber.
unittest
{
    auto channel_qs0 = new Channel!int(0);
    auto channel_qs1 = new Channel!int(1);
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;

    // Thread1
    thread_scheduler.spawn({
        auto fiber_scheduler = new FiberScheduler();

        auto m = new Mutex;
        auto c = fiber_scheduler.newCondition(m);

        fiber_scheduler.start({
            //  Fiber1 - It'll be tangled.
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                channel_qs0.send(2);
                result = channel_qs0.receive();
                synchronized (m)
                {
                    c.notify();
                }
            });

            synchronized (m)
            {
                assert(!c.wait(1000.msecs));
                assert(result == 0);
            }

            //  Fiber2 - Unravel a tangle
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                result = channel_qs0.receive();
                channel_qs0.send(2);
            });

            synchronized (m)
            {
                assert(c.wait(1000.msecs));
                assert(result == 2);
            }

            //  Fiber3 - It'll not be tangled, because queue size is 1
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                channel_qs1.send(2);
                result = channel_qs1.receive();
                synchronized (m)
                {
                    c.notify();
                }
            });

            synchronized (m)
            {
                assert(c.wait(1000.msecs));
                assert(result == 2);
            }
        });
    });
}
