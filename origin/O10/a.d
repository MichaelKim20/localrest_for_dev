
/**
 * Copied from geod24.concurrency.FiberScheduler, increased the stack size to 16MB.
 */
class BaseFiberScheduler : C.Scheduler
{
    static class InfoFiber : Fiber
    {
        C.ThreadInfo info;

        this(void delegate() op) nothrow
        {
            super(op, 16 * 1024 * 1024);  // 16Mb
        }
    }

    /**
     * This creates a new Fiber for the supplied op and then starts the
     * dispatcher.
     */
    void start(void delegate() op)
    {
        create(op);
        dispatch();
    }

    /**
     * This created a new Fiber for the supplied op and adds it to the
     * dispatch list.
     */
    void spawn(void delegate() op) nothrow
    {
        create(op);
        yield();
    }

    /**
     * If the caller is a scheduled Fiber, this yields execution to another
     * scheduled Fiber.
     */
    void yield() nothrow
    {
        // NOTE: It's possible that we should test whether the calling Fiber
        //       is an InfoFiber before yielding, but I think it's reasonable
        //       that any (non-Generator) fiber should yield here.
        if (Fiber.getThis())
            Fiber.yield();
    }

    /**
     * Returns an appropriate ThreadInfo instance.
     *
     * Returns a ThreadInfo instance specific to the calling Fiber if the
     * Fiber was created by this dispatcher, otherwise it returns
     * ThreadInfo.thisInfo.
     */
    @property ref C.ThreadInfo thisInfo() nothrow
    {
        auto f = cast(InfoFiber) Fiber.getThis();

        if (f !is null)
            return f.info;
        return C.ThreadInfo.thisInfo;
    }

    /**
     * Returns a Condition analog that yields when wait or notify is called.
     */
    C.Condition newCondition(C.Mutex m) nothrow
    {
        return new FiberCondition(m);
    }

private:

    class FiberCondition : C.Condition
    {
        this(C.Mutex m) nothrow
        {
            super(m);
            notified = false;
        }

        override void wait() nothrow
        {
            scope (exit) notified = false;

            while (!notified)
                switchContext();
        }

        override bool wait(Duration period) nothrow
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

        override void notify() nothrow
        {
            notified = true;
            switchContext();
        }

        override void notifyAll() nothrow
        {
            notified = true;
            switchContext();
        }

    private:
        void switchContext() nothrow
        {
            mutex_nothrow.unlock_nothrow();
            scope (exit) mutex_nothrow.lock_nothrow();
            yield();
        }

        private bool notified;
    }

private:
    void dispatch()
    {
        import std.algorithm.mutation : remove;

        while (m_fibers.length > 0)
        {
            auto t = m_fibers[m_pos].call(Fiber.Rethrow.no);
            if (t !is null && !(cast(C.OwnerTerminated) t))
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

private:
    Fiber[] m_fibers;
    size_t m_pos;
}

/// Our own little scheduler
private final class LocalScheduler : BaseFiberScheduler
{
    import core.sync.condition;
    import core.sync.mutex;

    /// Just a FiberCondition with a state
    private struct Waiting { FiberCondition c; bool busy; }

    /// The 'Response' we are currently processing, if any
    private Response pending;

    /// Request IDs waiting for a response
    private Waiting[ulong] waiting;

    /// Should never be called from outside
    public override Condition newCondition(Mutex m = null) nothrow
    {
        assert(0);
    }

    /// Get the next available request ID
    public size_t getNextResponseId ()
    {
        static size_t last_idx;
        return last_idx++;
    }

    public Response waitResponse (size_t id, Duration duration) nothrow
    {
        if (id !in this.waiting)
            this.waiting[id] = Waiting(new FiberCondition, false);

        Waiting* ptr = &this.waiting[id];
        if (ptr.busy)
            assert(0, "Trying to override a pending request");

        // We yield and wait for an answer
        ptr.busy = true;

        if (duration == Duration.init)
            ptr.c.wait();
        else if (!ptr.c.wait(duration))
            this.pending = Response(Status.Timeout, this.pending.id);

        ptr.busy = false;
        // After control returns to us, `pending` has been filled
        scope(exit) this.pending = Response.init;
        return this.pending;
    }

    /// Called when a waiting condition was handled and can be safely removed
    public void remove (size_t id)
    {
        this.waiting.remove(id);
    }

    /// Override `FiberScheduler.FiberCondition` to avoid mutexes
    /// and usage of global state
    private class FiberCondition : Condition
    {
        this() nothrow
        {
            super(null);
            notified = false;
        }

        override void wait() nothrow
        {
            scope (exit) notified = false;
            while (!notified)
                this.outer.yield();
        }

        override bool wait(Duration period) nothrow
        {
            scope (exit) notified = false;

            for (auto limit = MonoTime.currTime + period;
                 !notified && !period.isNegative;
                 period = limit - MonoTime.currTime)
            {
                this.outer.yield();
            }
            return notified;
        }

        override void notify() nothrow
        {
            notified = true;
            this.outer.yield();
        }

        override void notifyAll() nothrow
        {
            notified = true;
            this.outer.yield();
        }

        private bool notified;
    }
}
