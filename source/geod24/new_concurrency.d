/*******************************************************************************

    This is a low-level messaging API upon which more structured or restrictive
    APIs may be built.  The general idea is that every messageable entity is
    represented by a common handle type called a Tid, which allows messages to
    be sent to logical threads that are executing in both the current process
    and in external processes using the same interface.  This is an important
    aspect of scalability because it allows the components of a program to be
    spread across available resources with few to no changes to the actual
    implementation.

    A logical thread is an execution context that has its own stack and which
    runs asynchronously to other logical threads.  These may be preemptively
    scheduled kernel threads, fibers (cooperative user-space threads), or some
    other concept with similar behavior.

    he type of concurrency used when logical threads are created is determined
    by the Scheduler selected at initialization time.  The default behavior is
    currently to create a new kernel thread per call to spawn, but other
    schedulers are available that multiplex fibers across the main thread or
    use some combination of the two approaches.

    Note:
    Copied (almost verbatim) from Phobos at commit 3bfccf4f1 (2019-11-27)
    Changes are this notice, and the module rename, from `std.concurrency`
    to `geod24.concurrency`.
    Removed Tid, spawn
    Added Channel

    Copyright: Copyright Sean Kelly 2009 - 2014.
    License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
    Authors:   Sean Kelly, Alex Rønne Petersen, Martin Nowak
    Source:    $(PHOBOSSRC std/concurrency.d)

    Copyright Sean Kelly 2009 - 2014.
    Distributed under the Boost Software License, Version 1.0.
    (See accompanying file LICENSE_1_0.txt or copy at
    http://www.boost.org/LICENSE_1_0.txt)

*******************************************************************************/

module geod24.new_concurrency;

public import std.variant;

import std.container;
import std.range;

import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;
import core.thread;

/*******************************************************************************

    Encapsulates all implementation-level data needed for scheduling.

    When defining a Scheduler, an instance of this struct must be associated
    with each logical thread.  It contains all implementation-level information
    needed by the internal API.

*******************************************************************************/

public struct ThreadInfo
{
    ///
    public Object[string] objectValues;

    /***************************************************************************

        Gets a thread-local instance of ThreadInfo.

        Gets a thread-local instance of ThreadInfo, which should be used as the
        default instance when info is requested for a thread not created by the
        Scheduler.

    ***************************************************************************/

    static @property ref thisInfo () nothrow
    {
        static ThreadInfo val;
        return val;
    }

    /***************************************************************************

        Cleans up this ThreadInfo.

        This must be called when a scheduled thread terminates.  It tears down
        the messaging system for the thread and notifies interested parties of
        the thread's termination.

    ***************************************************************************/

    public void cleanup ()
    {

    }
}

public @property ref ThreadInfo thisInfo () nothrow
{
    return ThreadInfo.thisInfo;
}


/*******************************************************************************

    A Scheduler controls how threading is performed by spawn.

    Implementing a Scheduler allows the concurrency mechanism used by this
    module to be customized according to different needs.  By default, a call
    to spawn will create a new kernel thread that executes the supplied routine
    and terminates when finished.  But it is possible to create Schedulers that
    reuse threads, that multiplex Fibers (coroutines) across a single thread,
    or any number of other approaches.  By making the choice of Scheduler a
    user-level option, std.concurrency may be used for far more types of
    application than if this behavior were predefined.

    Example:
    ---
    import std.concurrency;
    import std.stdio;

    void main()
    {
        scheduler = new FiberScheduler;
        scheduler.start(
        {
            writeln("the rest of main goes here");
        });
    }
    ---

    Some schedulers have a dispatching loop that must run if they are to work
    properly, so for the sake of consistency, when using a scheduler, start()
    must be called within main().  This yields control to the scheduler and
    will ensure that any spawned threads are executed in an expected manner.

*******************************************************************************/

interface Scheduler
{
    /***************************************************************************

        Spawns the supplied op and starts the Scheduler.

        This is intended to be called at the start of the program to yield all
        scheduling to the active Scheduler instance.  This is necessary for
        schedulers that explicitly dispatch threads rather than simply relying
        on the operating system to do so, and so start should always be called
        within main() to begin normal program execution.

        Params:
            op = A wrapper for whatever the main thread would have done in the
                absence of a custom scheduler. It will be automatically executed
                via a call to spawn by the Scheduler.

    ***************************************************************************/

    void start (void delegate() op);


    /***************************************************************************

        Assigns a logical thread to execute the supplied op.

        This routine is called by spawn.  It is expected to instantiate a new
        logical thread and run the supplied operation.

        Params:
            op = The function to execute. This may be the actual function passed
                by the user to spawn itself, or may be a wrapper function.

    ***************************************************************************/

    void spawn (void delegate() op);


    /***************************************************************************

        Yields execution to another logical thread.

        This routine is called at various points within concurrency-aware APIs
        to provide a scheduler a chance to yield execution when using some sort
        of cooperative multithreading model.  If this is not appropriate, such
        as when each logical thread is backed by a dedicated kernel thread,
        this routine may be a no-op.

    ***************************************************************************/

    void yield () nothrow;


    /***************************************************************************

        Returns an appropriate ThreadInfo instance.

        Returns an instance of ThreadInfo specific to the logical thread that
        is calling this routine or, if the calling thread was not create by
        this scheduler, returns ThreadInfo.thisInfo instead.

    ***************************************************************************/

    @property ref ThreadInfo thisInfo () nothrow;


    /***************************************************************************

        Creates a Condition variable analog for signaling.

        Creates a new Condition variable analog which is used to check for and
        to signal the addition of messages to a thread's message queue.  Like
        yield, some schedulers may need to define custom behavior so that calls
        to Condition.wait() yield to another thread when no new messages are
        available instead of blocking.

        Params:
            m = The Mutex that will be associated with this condition. It will be
                locked prior to any operation on the condition, and so in some
                cases a Scheduler may need to hold this reference and unlock the
                mutex before yielding execution to another logical thread.

    ***************************************************************************/

    Condition newCondition (Mutex m) nothrow;
}


/*******************************************************************************

    An example Scheduler using kernel threads.

    This is an example Scheduler that mirrors the default scheduling behavior
    of creating one kernel thread per call to spawn.  It is fully functional
    and may be instantiated and used, but is not a necessary part of the
    default functioning of this module.

*******************************************************************************/

public class ThreadScheduler : Scheduler
{

    /***************************************************************************

        This simply runs op directly, since no real scheduling is needed by
        this approach.

    ***************************************************************************/

    void start (void delegate () op)
    {
        op();
    }

    /***************************************************************************

        Creates a new kernel thread and assigns it to run the supplied op.

    ***************************************************************************/

    void spawn (void delegate () op)
    {
        auto t = new Thread({
            scope (exit) {
                thisInfo.cleanup();
            }
            op();
        });
        t.start();
    }

    /***************************************************************************

        This scheduler does no explicit multiplexing, so this is a no-op.

    ***************************************************************************/

    void yield () nothrow
    {
        // no explicit yield needed
    }

    /***************************************************************************

        Returns ThreadInfo.thisInfo, since it is a thread-local instance of
        ThreadInfo, which is the correct behavior for this scheduler.

    ***************************************************************************/

    @property ref ThreadInfo thisInfo () nothrow
    {
        return ThreadInfo.thisInfo;
    }

    /***************************************************************************

        Creates a new Condition variable.  No custom behavior is needed here.

    ***************************************************************************/

    Condition newCondition (Mutex m) nothrow
    {
        return new Condition(m);
    }
}

/*******************************************************************************

    An example Scheduler using Fibers.

    This is an example scheduler that creates a new Fiber per call to spawn
    and multiplexes the execution of all fibers within the main thread.

*******************************************************************************/

class FiberScheduler : Scheduler
{

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

    ***************************************************************************/

    void start (void delegate () op)
    {
        create(op);
        dispatch();
    }

    /***************************************************************************

        This created a new Fiber for the supplied op and adds it to the
        dispatch list.

    ***************************************************************************/

    void spawn (void delegate() op) nothrow
    {
        create(op);
        yield();
    }

    /***************************************************************************

        If the caller is a scheduled Fiber, this yields execution to another
        scheduled Fiber.

    ***************************************************************************/

    void yield () nothrow
    {
        // NOTE: It's possible that we should test whether the calling Fiber
        //       is an InfoFiber before yielding, but I think it's reasonable
        //       that any (non-Generator) fiber should yield here.
        if (Fiber.getThis())
            Fiber.yield();
    }

    /***************************************************************************

        Returns an appropriate ThreadInfo instance.

        Returns a ThreadInfo instance specific to the calling Fiber if the
        Fiber was created by this dispatcher, otherwise it returns
        ThreadInfo.thisInfo.

    ***************************************************************************/

    @property ref ThreadInfo thisInfo () nothrow
    {
        auto f = cast(InfoFiber) Fiber.getThis();

        if (f !is null)
            return f.info;
        return ThreadInfo.thisInfo;
    }

    /***************************************************************************

        Returns a Condition analog that yields when wait or notify is called.

    ***************************************************************************/

    Condition newCondition (Mutex m) nothrow
    {
        return new FiberCondition(m);
    }

protected:

    /***************************************************************************

        Creates a new Fiber which calls the given delegate.

        Params:
            op = The delegate the fiber should call

    ***************************************************************************/

    void create(void delegate() op) nothrow
    {
        void wrap()
        {
            scope (exit)
            {
                thisInfo.cleanup();
            }
            op();
        }

        m_fibers ~= new InfoFiber(&wrap);
    }

    /***************************************************************************

        Fiber which embeds a ThreadInfo

    ***************************************************************************/

    static class InfoFiber : Fiber
    {
        ThreadInfo info;

        this (void delegate () op) nothrow
        {
            super(op);
        }

        this (void delegate () op, size_t sz) nothrow
        {
            super (op, sz);
        }
    }

private:
    class FiberCondition : Condition
    {
        this (Mutex m) nothrow
        {
            super(m);
            notified = false;
        }

        override void wait () nothrow
        {
            scope (exit) notified = false;

            while (!notified)
                switchContext();
        }

        override bool wait (Duration period) nothrow
        {
            import core.time : MonoTime;

            scope (exit) notified = false;

            for (auto limit = MonoTime.currTime + period;
                 !notified && !period.isNegative;
                 period = limit - MonoTime.currTime)
            {
                this.outer.yield();
            }
            return notified;
        }

        override void notify () nothrow
        {
            notified = true;
            switchContext();
        }

        override void notifyAll () nothrow
        {
            notified = true;
            switchContext();
        }

    private:
        void switchContext() nothrow
        {
            if (mutex_nothrow) mutex_nothrow.unlock_nothrow();
            scope (exit)
                if (mutex_nothrow)
                    mutex_nothrow.lock_nothrow();
            this.outer.yield();
        }

        private bool notified;
    }

private:
    void dispatch ()
    {
        import std.algorithm.mutation : remove;

        while (m_fibers.length > 0)
        {
            auto t = m_fibers[m_pos].call(Fiber.Rethrow.no);
            if (t !is null && !(cast(ChannelClosed) t))
            {
                throw t;
            }
            if (m_fibers[m_pos].state == Fiber.State.TERM)
            {
                if (m_pos >= (m_fibers = remove(m_fibers, m_pos)).length)
                    m_pos = 0;
            }
            else if (m_pos++ >= m_fibers.length - 1)
            {
                m_pos = 0;
            }
        }
    }

private:
    Fiber[] m_fibers;
    size_t m_pos;
}

/***************************************************************************

    Returns a Scheduler assigned to a called thread.

***************************************************************************/

public @property Scheduler thisScheduler () nothrow
{
    if (auto p = "scheduler" in thisInfo.objectValues)
        return cast(Scheduler)(*p);
    else
        return null;
}

public @property void thisScheduler (Scheduler value) nothrow
{
    thisInfo.objectValues["scheduler"] = cast(Object)value;
}



/*******************************************************************************

    When the channel is closed, it is thrown when the `receive` is called.

*******************************************************************************/

public class ChannelClosed : Exception
{
    /// Ctor
    public this (string msg = "Channel Closed") @safe pure nothrow @nogc
    {
        super(msg);
    }
}


/*******************************************************************************

    This channel has queues that senders and receivers can wait for.
    With these queues, a single thread alone can exchange data with each other.

    Technically, a channel is a data trancontexter pipe where data can be passed
    into or read from.
    Hence one fiber(thread) can send data into a channel, while other fiber(thread)
    can read that data from the same channel

*******************************************************************************/

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
