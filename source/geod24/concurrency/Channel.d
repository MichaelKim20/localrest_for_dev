/*******************************************************************************

    This channel has queues that senders and receivers can wait for.
    With these queues, a single thread alone can exchange data with each other.

    This channel use `NonBlockingQueue`. This is not uses `Lock`
    A channel is a communication class using which fiber can communicate
    with each other.
    Technically, a channel is a data trancontexter pipe where data can be passed
    into or read from.
    Hence one fiber can send data into a channel, while other fiber can read
    that data from the same channel

*******************************************************************************/

module geod24.concurrency.Channel;

import geod24.concurrency.Scheduler;

import std.container;
import std.range;
import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;

/// Ditto
public class Channel (T)
{
    /// closed
    private bool closed;

    /// lock
    private Mutex mutex;


    /// collection of send waiters
    private DList!(ChannelContext!T) sendq;

    /// collection of recv waiters
    private DList!(ChannelContext!T) recvq;

    /// Ctor
    public this ()
    {
        this.closed = false;
        this.mutex = new Mutex;
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

    public bool put (T msg)
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

            this.mutex.unlock();

            *(context.msg_ptr) = msg;

            if (context.condition !is null)
                context.condition.notify();

            return true;
        }

        {
            ChannelContext!T new_context;
            new_context.msg_ptr = null;
            new_context.msg = msg;
            new_context.condition = thisScheduler.newCondition(null);

            this.sendq.insertBack(new_context);
            this.mutex.unlock();

            new_context.condition.wait();
        }

        return true;
    }

    /***************************************************************************

        Write the data received in `msg`

        Params:
            msg = value to receive

        Return:
            true if the receiving is succescontextul, otherwise false

    ***************************************************************************/

    public bool get (T* msg)
    in
    {
        assert(thisScheduler !is null,
            "Cannot get a message until a scheduler was created ");
    }
    do
    {
        this.mutex.lock();

        if (this.closed)
        {
            (*msg) = T.init;
            this.mutex.unlock();

            return false;
        }

        if (this.sendq[].walkLength > 0)
        {
            ChannelContext!T context = this.sendq.front;
            this.sendq.removeFront();

            *(msg) = context.msg;

            if (context.condition !is null)
                context.condition.notify();

            this.mutex.unlock();

            return true;
        }

        {
            ChannelContext!T new_context;
            new_context.msg_ptr = msg;
            new_context.condition = thisScheduler.newCondition(null);

            this.recvq.insertBack(new_context);
            this.mutex.unlock();

            new_context.condition.wait();
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
                context.condition.notify();
        }

        while (true)
        {
            if (this.sendq[].walkLength == 0)
                break;

            context = this.sendq.front;
            this.sendq.removeFront();
            if (context.condition !is null)
                context.condition.notify();
        }
    }
}

///
private struct ChannelContext (T)
{
    /// This is a message. Used in put
    public T  msg;

    /// This is a message point. Used in get
    public T* msg_ptr;

    //  Waiting Condition
    public Condition condition;
}


/*
unittest
{
    import std.stdio;

    Channel!int chan = new Channel!int();
    ThreadScheduler thread_scheduler = new ThreadScheduler();

    thread_scheduler.spawn({
        FiberScheduler fiber_scheduler = new FiberScheduler();
        fiber_scheduler.start({
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;

                writefln("send %s", 1);
                chan.put(1);

            });
            fiber_scheduler.spawn({
                thisScheduler = fiber_scheduler;
                int res;
                chan.get(&res);
                writefln("receive %s", res);
            });
        });
    });
}
*/

unittest
{
    import std.stdio;
    import core.thread;

    Channel!int chan = new Channel!int();
    ThreadScheduler thread_scheduler = new ThreadScheduler();

    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        writefln("send %s", 1);
        chan.put(1);
    });

    thread_scheduler.spawn({
        thisScheduler = thread_scheduler;
        int res;
        chan.get(&res);
        writefln("receive %s", res);
    });

    Thread.sleep(10000.msecs);
}