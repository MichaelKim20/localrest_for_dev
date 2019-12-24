module geod24.concurrency;

import std.container;
import std.range.primitives;
import std.range.interfaces : InputRange;

import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;
import core.thread;
import std.typecons : Tuple;

///
public struct ThreadInfo
{
    /// Manages fiber's work schedule inside current thread.
    public Scheduler scheduler;

    public Object[string] members;

    static @property ref thisInfo () nothrow
    {
        static ThreadInfo val;
        return val;
    }

    public void cleanup ()
    {

    }
}

public @property ref ThreadInfo thisInfo () nothrow
{
    return ThreadInfo.thisInfo;
}

/***************************************************************************

    Returns a Scheduler assigned to a called thread.

***************************************************************************/

public @property Scheduler thisScheduler () nothrow
{
    return thisInfo.scheduler;
}

///
public class MessageDispatcher (T)
{
    public FiberScheduler scheduler;
    public Thread thread;

    public this (void function() fn, ulong sz = 0LU) pure nothrow @nogc @safe
    {
        super(fn, sz);
        this.scheduler = new FiberScheduler;
        this.chan = new Channel!T(this.scheduler);
    }

    public this (void delegate() dg, ulong sz = 0LU) pure nothrow @nogc @safe
    {
        super(dg, sz);
        this.scheduler = new FiberScheduler!T();
        this.chan = new Channel!T(this.scheduler, chan_size);
    }

    public void send (T) (T msg)
    {
        auto f = cast(MessageInfoFiber) Fiber.getThis();
        if (f !is null)
            this.chan.put(msg);
        else
        {
            auto cond = this.scheduler.newCondition(null);
            this.spawnFiber(
            {
                this.chan.put(msg);
                cond.notify();
            });
            cond.wait();
        }
    }

    public T receive ()
    {
        auto f = cast(MessageInfoFiber) Fiber.getThis();
        if (f !is null)
            return this.chan.get();
        else
        {
            T res;
            auto cond = this.scheduler.newCondition(null);
            this.spawnFiber(
            {
                this.chan.get(&res);
                cond.notify();
            });
            cond.wait();
            return res;
        }
    }

    public void startFiber (void delegate () op)
    {
        this.scheduler.start(op);
    }

    public void spawnFiber (void delegate () op)
    {
        this.scheduler.spawn(op);
    }
}

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

public class Channel (T)
{
    /// closed
    private bool closed;

    /// lock
    private Mutex mutex;


    /// collection of send waiters
    private DList!(ChannelContext!(T)) sendq;

    /// collection of recv waiters
    private DList!(ChannelContext!(T)) recvq;

    private Scheduler scheduler;


    /// Ctor
    public this (Scheduler sche)
    {
        this.closed = false;
        this.mutex = new Mutex;
        this.scheduler = sche;
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
            new_context.create_time = MonoTime.currTime;
            new_context.condition = this.scheduler.newCondition(null);

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
            new_context.create_time = MonoTime.currTime;
            new_context.condition = this.scheduler.newCondition(null);

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

    /// The creating time
    public MonoTime create_time;

    //  Waiting Condition
    public Condition condition;
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
        logical thread and run the supplied operation.  This thread must call
        thisInfo.cleanup() when the thread terminates if the scheduled thread
        is not a kernel thread--all kernel threads will have their ThreadInfo
        cleaned up automatically by a thread-local destructor.

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

class ThreadScheduler : Scheduler
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
            scope (exit) thisInfo.cleanup();
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
        return ThreadInfo.thisInfo;
    }


    /***************************************************************************

        Returns a Condition analog that yields when wait or notify is called.

    ***************************************************************************/

    Condition newCondition (Mutex m) nothrow
    {
        return new FiberCondition(m);
    }

private:
    static class InfoFiber : Fiber
    {
        ThreadInfo info;

        this (void delegate () op) nothrow
        {
            super(op);
        }
    }

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
                yield();
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
        void switchContext () nothrow
        {
            if (mutex_nothrow is null)
                yield();
            else
            {
                mutex_nothrow.unlock_nothrow();
                scope (exit) mutex_nothrow.lock_nothrow();
                yield();
            }
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
            if (t !is null)
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

    void create (void delegate () op) nothrow
    {
        void wrap ()
        {
            scope (exit)
            {
                thisInfo.cleanup();
            }
            op();
        }

        m_fibers ~= new InfoFiber(&wrap);
    }

private:
    Fiber[] m_fibers;
    size_t m_pos;
}
