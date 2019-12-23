


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

module geod24.concurrency;

import std.container;
import std.range.primitives;
import std.range.interfaces : InputRange;

import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;
import core.thread;
import std.typecons : Tuple;

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

        Spawns stops the Scheduler.

        This calls at the end of the program and commands the scheduler to end.

    ***************************************************************************/

    void stop (void delegate () op, bool forced = false);

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

    An Scheduler using kernel threads.

    This is an Scheduler that mirrors the default scheduling behavior
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

    public void start (void delegate () op)
    {
        op();
    }

    /***************************************************************************

        This calls at the end of the program and commands the scheduler to end.

    ***************************************************************************/

    public void stop (void delegate () op, bool forced = false)
    {

    }

    /***************************************************************************

        Creates a new kernel thread and assigns it to run the supplied op.

    ***************************************************************************/

    public void spawn (void delegate () op)
    {
        auto t = new Thread(op);
        t.start();
    }

    /***************************************************************************

        This scheduler does no explicit multiplexing, so this is a no-op.

    ***************************************************************************/

    public void yield () nothrow
    {
        // no explicit yield needed
    }

    /***************************************************************************

        Creates a new Condition variable.  No custom behavior is needed here.

    ***************************************************************************/

    public Condition newCondition (Mutex m) nothrow
    {
        return new Condition(m);
    }
}


/*******************************************************************************

    A Fiber using FiberScheduler.

*******************************************************************************/

public class MessageFiber (T) : Fiber
{
    protected MessageThread!T thread;
    protected FiberScheduler scheduler;

    public this (MessageThread!T t, FiberScheduler s, void delegate () op) nothrow
    {
        this.thread = t;
        this.scheduler = s;
        super(op);
    }

    public void cleanup ()
    {

    }
}


/*******************************************************************************

    A Condition using FiberScheduler.

*******************************************************************************/

public class FiberCondition (T) : Condition
{
    /// Owner
    private FiberScheduler!T owner;

    public this (FiberScheduler s, Mutex m) nothrow
    {
        super(m);
        this.owner = s;
        notified = false;
    }

    override public void wait () nothrow
    {
        scope (exit) notified = false;

        while (!notified)
            switchContext();
    }

    override public bool wait (Duration period) nothrow
    {
        import core.time : MonoTime;

        scope (exit) notified = false;

        for (auto limit = MonoTime.currTime + period;
                !notified && !period.isNegative;
                period = limit - MonoTime.currTime)
        {
            this.owner.yield();
        }
        return notified;
    }

    override public void notify () nothrow
    {
        notified = true;
        switchContext();
    }

    override public void notifyAll () nothrow
    {
        notified = true;
        switchContext();
    }

    private void switchContext () nothrow
    {
        if (this.mutex_nothrow is null)
            this.owner.yield();
        else
        {
            mutex_nothrow.unlock_nothrow();
            scope (exit) mutex_nothrow.lock_nothrow();
            this.owner.yield();
        }
    }

    private bool notified;
}


/*******************************************************************************

    An example Scheduler using Fibers.

    This is an example scheduler that creates a new Fiber per call to spawn
    and multiplexes the execution of all fibers within the main thread.

*******************************************************************************/

public class FiberScheduler (T) : Scheduler
{
    protected MessageThread!T thread;
    protected Fiber[] m_fibers;
    protected size_t m_pos;

    public this (MessageThread!T t)
    {
        this.thread = t;
    }

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

    ***************************************************************************/

    public void start (void delegate () op)
    {
        create(op);
        dispatch();
    }

    /***************************************************************************

        This calls at the end of the program and commands the scheduler to end.

    ***************************************************************************/

    public void stop (void delegate () op, bool forced = false)
    {

    }

    /***************************************************************************

        This created a new Fiber for the supplied op and adds it to the
        dispatch list.

    ***************************************************************************/

    public void spawn (void delegate() op) nothrow
    {
        create(op);
        yield();
    }

    /***************************************************************************

        If the caller is a scheduled Fiber, this yields execution to another
        scheduled Fiber.

    ***************************************************************************/

    public void yield () nothrow
    {
        // NOTE: It's possible that we should test whether the calling Fiber
        //       is an InfoFiber before yielding, but I think it's reasonable
        //       that any (non-Generator) fiber should yield here.
        if (Fiber.getThis())
            Fiber.yield();
    }

    /***************************************************************************

        Returns a Condition analog that yields when wait or notify is called.

    ***************************************************************************/

    public Condition newCondition (Mutex m) nothrow
    {
        return new FiberCondition!T(this, m);
    }

    /***************************************************************************

        Manages fiber's work schedule.

    ***************************************************************************/

    protected void dispatch ()
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

    /***************************************************************************

        Create a new fiber and add it to the array.

    ***************************************************************************/

    protected void create (void delegate () op) nothrow
    {
        m_fibers ~= new MessageFiber!T(this.thread, this, op);
    }
}


public class Channel (T)
{
    public this (size)
    {

    }

    public void put (T) (T msg)
    {

    }

    public T get (T) ()
    {

    }
}

public class MessageThread (T) : Thread
{
    public FiberScheduler!T scheduler;
    public Channel!T chan;

    this (void function() fn, ulong sz = 0LU, ulong chan_size = 0LU) pure nothrow @nogc @safe
    {
        super(fn, sz);
        scheduler = new FiberScheduler!T();
        chan = new Channel!T(chan_size);
    }

    this (void delegate() dg, ulong sz = 0LU, ulong chan_size = 0LU) pure nothrow @nogc @safe
    {
        super(dg, sz);
        scheduler = new FiberScheduler!T();
        chan = new Channel!T(chan_size);
    }

    public void send (T) (T msg)
    {
        this.chan.put(msg);
    }

    public T receive ()
    {
        return this.chan.get();
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
