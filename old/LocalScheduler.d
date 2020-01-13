/*******************************************************************************

    An Local Fiber Scheduler.

    This is an scheduler that creates a new Fiber per call to spawn and
    multiplexes the execution of all fibers within a thread.

*******************************************************************************/

module geod24.LocalScheduler;

import geod24.concurrency;

import core.sync.condition;
import core.sync.mutex;
import core.thread;

/// Ditto
public class LocalFiberScheduler : FiberScheduler
{
    private Mutex mutex;
    private bool terminated;
    private MonoTime terminated_time;
    private bool stoped;
    private Duration stop_delay_time;
    private Thread dispatcher;

    public this ()
    {
        super();

        this.mutex = new Mutex();
        this.terminated = false;
        this.stoped = false;
        this.stop_delay_time = 1000.msecs;

        if (thread_isMainThread())
        {
            auto spawn_scheduler = this;
            void exec ()
            {
                thisScheduler = spawn_scheduler;
                this.dispatch();
            }
            dispatcher = new Thread(&exec);
            dispatcher.start();
        }
    }

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

    ***************************************************************************/

    override public void start (void delegate () op, ulong sz = 0LU)
    {
        create(op, sz);
        yield();
    }


    /***************************************************************************

        This commands the scheduler to shut down at the end of the program.

    ***************************************************************************/

    override public void stop ()
    {
        terminated = true;
        terminated_time = MonoTime.currTime;

        while (!this.stoped)
        {
            Thread.sleep(10.msecs);
            auto elapsed = MonoTime.currTime - terminated_time;
            if (elapsed > this.stop_delay_time)
                break;
        }
    }


    /***************************************************************************

        This created a new Fiber for the supplied op and adds it to the
        dispatch list.

    ***************************************************************************/

    override public void spawn (void delegate() op, ulong sz = 0LU) nothrow
    {
        create(op, sz);
        yield();
    }



    /***************************************************************************

        If the caller is a scheduled Fiber, this yields execution to another
        scheduled Fiber.

    ***************************************************************************/

    override public void yield () nothrow
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

    override public @property ref ThreadInfo thisInfo () nothrow
    {
        auto f = cast(InfoFiber) Fiber.getThis();

        if (f !is null)
            return f.info;
        return ThreadInfo.thisInfo;
    }


    /***************************************************************************

        Returns a Condition analog that yields when wait or notify is called.

        Params:
            m = The Mutex that will be associated with this condition.

    ***************************************************************************/

    override public Condition newCondition (Mutex m) nothrow
    {
        return new FiberCondition(this, m);
    }

    /***************************************************************************

        Cleans up this FiberScheduler.
        This must be called when a thread terminates.

        Params:
            root = The top is a Thread and the fibers exist below it.
                   Thread is root, if this value is true,
                   then it is to clean the value that Thread had.

    ***************************************************************************/

    override public void cleanup (bool root)
    {
        if (terminated)
            return;

        if (root)
            this.stop();
    }


    /***************************************************************************

        Wait until notified.

        Params:
            c = A condition variable analog which is used to check for and
                to signal the addition of messages to a fiber's message queue

    ***************************************************************************/

    override public void wait (Condition c)
    {
        if (c.mutex !is null)
            c.mutex.lock();

        scope (exit)
             if (c.mutex !is null)
                c.mutex.unlock();

        c.wait();
    }


    /***************************************************************************

        Suspends the calling thread until a notification occurs or until
        the supplied time period has elapsed.

        Params:
            c = A condition variable analog which is used to check for and
                to signal the addition of messages to a fiber's message queue
            period = The time to wait.

    ***************************************************************************/

    override public bool wait (Condition c, Duration period)
    {
        if (c.mutex !is null)
            c.mutex.lock();

        scope (exit)
             if (c.mutex !is null)
                c.mutex.unlock();

        return c.wait(period);
    }


    /***************************************************************************

        Notifies one waiter.

        Params:
            c = A condition variable analog which is used to check for and
                to signal the addition of messages to a fiber's message queue

    ***************************************************************************/

    override public void notify (Condition c)
    {
        if (c.mutex !is null)
            c.mutex.lock();

        scope (exit)
             if (c.mutex !is null)
                c.mutex.unlock();

        c.notify();
    }


    /***************************************************************************

        Notifies all waiters.

        Params:
            c = A condition variable analog which is used to check for and
                to signal the addition of messages to a fiber's message queue

    ***************************************************************************/

    override public void notifyAll (Condition c)
    {
        if (c.mutex !is null)
            c.mutex.lock();

        scope (exit)
             if (c.mutex !is null)
                c.mutex.unlock();

        c.notifyAll();
    }

    /***************************************************************************

        Creates a new Fiber which calls the given delegate.

        Params:
            op = The delegate the fiber should call

    ***************************************************************************/

    override protected void create(void delegate() op, size_t sz = 0) nothrow
    {
        auto owner_scheduler = this;
        auto owner_objects = thisInfo.objectValues;

        void wrap()
        {
            scope (exit)
            {
                thisInfo.cleanup(false);
            }

            foreach (key, ref value; owner_objects)
                if (!(key in thisInfo.objectValues))
                    thisInfo.objectValues[key] = value;

            thisScheduler = owner_scheduler;

            op();
        }

        this.mutex.lock_nothrow();
        scope(exit) this.mutex.unlock_nothrow();

        if (sz == 0)
            m_fibers ~= new InfoFiber(&wrap);
        else
            m_fibers ~= new InfoFiber(&wrap, sz);
    }

    override protected void dispatch ()
    {
        import std.algorithm.mutation : remove;
        bool done = terminated && (m_fibers.length == 0);

        while (!done)
        {
            this.mutex.lock();
            if (m_fibers.length > 0)
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

            done = terminated && (m_fibers.length == 0);
            if (!done && terminated)
            {
                auto elapsed = MonoTime.currTime - terminated_time;
                if (elapsed > this.stop_delay_time)
                    done = true;
            }
            this.mutex.unlock();
        }
        this.stoped = true;
    }
}
