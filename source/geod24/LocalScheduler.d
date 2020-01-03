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
class LocalFiberScheduler : Scheduler
{
    private Mutex mutex;
    private shared(bool) terminated;
    private shared(MonoTime) terminated_time;
    private shared(bool) stoped;

    this ()
    {
        this.mutex = new Mutex();
    }

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

    ***************************************************************************/

    void start (void delegate () op)
    {
        terminated = false;
        create(op);
        dispatch();
    }


    /***************************************************************************

        This commands the scheduler to shut down at the end of the program.

    ***************************************************************************/

    void stop ()
    {
        terminated = true;
        terminated_time = MonoTime.currTime;

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


    /***************************************************************************

        Wait until notified.

        Params:
            c = A condition variable analog which is used to check for and
                to signal the addition of messages to a fiber's message queue

    ***************************************************************************/

    void wait (Condition c)
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

    bool wait (Condition c, Duration period)
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

    void notify (Condition c)
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

    void notifyAll (Condition c)
    {
        if (c.mutex !is null)
            c.mutex.lock();

        scope (exit)
             if (c.mutex !is null)
                c.mutex.unlock();

        c.notifyAll();
    }

protected:


    /***************************************************************************

        Creates a new Fiber which calls the given delegate.

        Params:
            op = The delegate the fiber should call

    ***************************************************************************/

    void create(void delegate() op) nothrow
    {
        auto owner_scheduler = this;
        auto owner_objects = thisInfo.objectValues;

        void wrap()
        {
            scope (exit)
            {
                thisInfo.cleanup();
            }

            foreach (key, ref value; owner_objects)
                if (!(key in thisInfo.objectValues))
                    thisInfo.objectValues[key] = value;

            thisScheduler = owner_scheduler;

            op();
        }

        this.mutex.lock_nothrow();
        m_fibers ~= new InfoFiber(&wrap);
        this.mutex.unlock_nothrow();
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

        /***********************************************************************

            Wait until notified.

        ***********************************************************************/

        override void wait () nothrow
        {
            scope (exit) notified = false;

            while (!notified)
                switchContext();
        }


        /***********************************************************************

            Suspends the calling thread until a notification occurs or until
            the supplied time period has elapsed.

            Params:
                period = The time to wait.

        ***********************************************************************/

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


        /***********************************************************************

            Notifies one waiter.

        ***********************************************************************/

        override void notify () nothrow
        {
            notified = true;
            switchContext();
        }


        /***********************************************************************

            Notifies all waiters.

        ***********************************************************************/

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
        import std.math;
        Duration limit = 1000.msecs;

        auto condition = ThreadScheduler.instance.newCondition(this.mutex);
        ulong count = 0;
        bool done = false;

        ulong getWaitInterval(ulong length)
        {
            return ((length) / 5) + 1;
        }

        while (!done)
        {
            this.mutex.lock_nothrow();
            scope (exit) this.mutex.unlock_nothrow();

            auto t = m_fibers[m_pos].call(Fiber.Rethrow.no);
            if (t !is null && !(cast(ChannelClosed) t))
                throw t;

            if (m_fibers[m_pos].state == Fiber.State.TERM)
            {
                if (m_pos >= (m_fibers = remove(m_fibers, m_pos)).length)
                    m_pos = 0;
            }
            else if (m_pos++ >= m_fibers.length - 1)
            {
                m_pos = 0;
            }

            if (m_fibers.length == 0)
                done = true;

            if (terminated && (m_fibers.length > 0))
            {
                auto elapsed = MonoTime.currTime - terminated_time;
                if (elapsed > limit)
                    done = true;
            }

            if (++count % getWaitInterval(m_fibers.length) == 0)
                ThreadScheduler.instance.wait(condition, 100.nsecs);
        }
    }

private:
    Fiber[] m_fibers;
    size_t m_pos;
}
