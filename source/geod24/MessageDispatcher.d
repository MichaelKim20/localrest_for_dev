
module geod24.MessageDispatcher;
import std.container;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.traits;
public import std.variant;
import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;
import core.thread;

private enum MsgType
{
    standard,
    linkDead,
}

private struct Message
{
    MsgType type;
    Variant data;
    /// It is necessary to measure the wait time.
    MonoTime create_time;

    this (T...) (MsgType t, T vals)
    if (T.length > 0)
    {
        static if (T.length == 1)
        {
            type = t;
            data = vals[0];
        }
        else
        {
            import std.typecons : Tuple;

            type = t;
            data = Tuple!(T)(vals);
        }
        create_time = MonoTime.currTime;
    }

    @property auto convertsTo (T...) ()
    {
        static if (T.length == 1)
        {
            return is(T[0] == Variant) || data.convertsTo!(T);
        }
        else
        {
            import std.typecons : Tuple;
            return data.convertsTo!(Tuple!(T));
        }
    }

    @property auto get (T...)()
    {
        static if (T.length == 1)
        {
            static if (is(T[0] == Variant))
                return data;
            else
                return data.get!(T);
        }
        else
        {
            import std.typecons : Tuple;
            return data.get!(Tuple!(T));
        }
    }

    auto map (Op) (Op op)
    {
        alias Args = Parameters!(Op);

        static if (Args.length == 1)
        {
            static if (is(Args[0] == Variant))
                return op(data);
            else
                return op(data.get!(Args));
        }
        else
        {
            import std.typecons : Tuple;
            return op(data.get!(Tuple!(Args)).expand);
        }
    }
}

/*******************************************************************************

    A MessageBox is a message queue for one thread.  Other threads may send
    messages to this owner by calling put(), and the owner receives them by
    calling get().  The put() call is therefore effectively shared and the
    get() call is effectively local.

*******************************************************************************/

private class MessageBox
{
    /* TODO: make @safe after relevant druntime PR gets merged */
    this () @trusted nothrow
    {
        this.mutex = new Mutex();
        this.closed = false;
        this.timeout = Duration.init;
    }

    /***************************************************************************

        Sets the time of the timeout.

        Params:
            timeout = if it is closed, return true.

    ***************************************************************************/

    public void setTimeout (Duration timeout) @safe pure nothrow @nogc
    {
        this.timeout = timeout;
    }

    /***************************************************************************

        Returns whether MessageBox is closed or not.

        Returns:
            if it is closed, return true.

    ***************************************************************************/

    public @property bool isClosed () @safe @nogc pure
    {
        synchronized (this.mutex)
        {
            return this.closed;
        }
    }

    /***************************************************************************

        If maxMsgs is not set, the message is added to the queue and the
        owner is notified.  If the queue is full, the message will still be
        accepted if it is a control message, otherwise onCrowdingDoThis is
        called.  If the routine returns true, this call will block until
        the owner has made space available in the queue.  If it returns
        false, this call will abort.

        Params:
            msg = The message to put in the queue.

        Returns:
            If successful return true otherwise return false.

        Throws:
            An exception if the queue is full and onCrowdingDoThis throws.

    ***************************************************************************/

    final bool put (ref Message msg)
    {
        import std.algorithm;
        import std.range : popBackN, walkLength;

        this.mutex.lock();
        if (this.closed)
        {
            this.mutex.unlock();
            return false;
        }

        if (this.recvq[].walkLength > 0)
        {
            SudoFiber sf = this.recvq.front;
            this.recvq.removeFront();
            *(sf.msg_ptr) = msg;

            if (sf.swdg !is null)
                sf.swdg();

            this.mutex.unlock();

            return true;
        }

        {
            shared(bool) is_waiting = true;
            void stopWait1() {
                is_waiting = false;
            }

            SudoFiber new_sf;
            new_sf.msg = msg;
            new_sf.swdg = &stopWait1;
            new_sf.create_time = MonoTime.currTime;

            this.sendq.insertBack(new_sf);
            this.mutex.unlock();

            if (this.timeout > Duration.init)
            {
                auto start = MonoTime.currTime;
                while (is_waiting)
                {
                    auto end = MonoTime.currTime();
                    auto elapsed = end - start;
                    if (elapsed > this.timeout)
                    {
                        // remove timeout element
                        this.mutex.lock();
                        auto range = find(this.sendq[], new_sf);
                        if (!range.empty)
                        {
                            popBackN(range, range.walkLength-1);
                            this.sendq.remove(range);
                        }
                        this.mutex.unlock();
                        return false;
                    }

                    if (Fiber.getThis())
                        Fiber.yield();
                }
            }
            else
            {
                while (is_waiting)
                {
                    if (Fiber.getThis())
                        Fiber.yield();
                }
            }
        }

        return true;
    }

    /***************************************************************************

        Get a message from the queue.

        Params:
            msg = The message to get in the queue.

        Returns:
            If successful, return true.

    ***************************************************************************/

    private bool getMessage (Message* msg)
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();
            return false;
        }

        if (this.sendq[].walkLength > 0)
        {
            SudoFiber sf = this.sendq.front;
            this.sendq.removeFront();

            *msg = sf.msg;

            if (sf.swdg !is null)
                sf.swdg();

            this.mutex.unlock();

            if (this.timed_wait)
            {
                this.waitFromBase(sf.msg.create_time, this.timed_wait_period);
                this.timed_wait = false;
            }

            return true;
        }

        {
            shared(bool) is_waiting1 = true;

            void stopWait1() {
                is_waiting1 = false;
            }

            SudoFiber new_sf;
            new_sf.msg_ptr = msg;
            new_sf.swdg = &stopWait1;
            new_sf.create_time = MonoTime.currTime;

            this.recvq.insertBack(new_sf);
            this.mutex.unlock();

            while (is_waiting1)
            {
                if (Fiber.getThis())
                    Fiber.yield();
                Thread.sleep(1.msecs);
            }

            if (this.timed_wait)
            {
                this.waitFromBase(new_sf.create_time, this.timed_wait_period);
                this.timed_wait = false;
            }
        }

        return true;
    }

    /***************************************************************************

        Matches ops against each message in turn until a match is found.

        Params:
            ops = The operations to match. Each may return a bool to indicate
                whether a message with a matching type is truly a match.

        Returns:
            true if a message was retrieved and false if not (such as if a
            timeout occurred).

        Throws:
            LinkTerminated if a linked thread terminated, or OwnerTerminated
            if the owner thread terminates and no existing messages match the
            supplied ops.

    ***************************************************************************/

    public bool get (T...)(scope T vals)
    {
        import std.meta : AliasSeq;

        static assert(T.length);

        static if (isImplicitlyConvertible!(T[0], Duration))
        {
            alias Ops = AliasSeq!(T[1 .. $]);
            alias ops = vals[1 .. $];

            this.timed_wait = true;
            this.timed_wait_period = vals[0];
        }
        else
        {
            alias Ops = AliasSeq!(T);
            alias ops = vals[0 .. $];

            this.timed_wait = false;
            this.timed_wait_period = Duration.init;
        }

        bool onStandardMsg (ref Message msg)
        {
            foreach (i, t; Ops)
            {
                alias Args = Parameters!(t);
                auto op = ops[i];

                if (msg.convertsTo!(Args))
                {
                    static if (is(ReturnType!(t) == bool))
                    {
                        return msg.map(op);
                    }
                    else
                    {
                        msg.map(op);
                        return true;
                    }
                }
            }
            return false;
        }

        bool onLinkDeadMsg (ref Message msg)
        {
            assert(msg.convertsTo!(Tid));
            auto tid = msg.get!(Tid);

            if (bool* pDepends = tid in thisInfo.links)
            {
                auto depends = *pDepends;
                thisInfo.links.remove(tid);
                // Give the owner relationship precedence.
                if (depends && tid != thisInfo.owner)
                {
                    auto e = new LinkTerminated(tid);
                    auto m = Message(MsgType.standard, e);
                    if (onStandardMsg(m))
                        return true;
                    throw e;
                }
            }
            if (tid == thisInfo.owner)
            {
                thisInfo.owner = Tid.init;
                auto e = new OwnerTerminated(tid);
                auto m = Message(MsgType.standard, e);
                if (onStandardMsg(m))
                    return true;
                throw e;
            }
            return false;
        }

        bool onControlMsg (ref Message msg)
        {
            switch (msg.type)
            {
            case MsgType.linkDead:
                return onLinkDeadMsg(msg);
            default:
                return false;
            }
        }

        bool scan (ref Message msg)
        {
            if (isControlMsg(msg))
            {
                if (onControlMsg(msg))
                {
                    return !isLinkDeadMsg(msg);
                }
            }
            else
            {
                if (onStandardMsg(msg))
                    return true;
            }
            return false;
        }

        Message msg;
        while (true)
        {
            if (this.getMessage(&msg))
            {
                if (scan(msg))
                    break;
                else
                    continue;
            }
            else
                break;
        }

        return false;
    }

    /***************************************************************************

        When operated by a fiber, wait for a specified period of time
        from the base time

        Params:
            base = Base time
            period = Waiting time

    ***************************************************************************/

    private void waitFromBase (MonoTime base, Duration period)
    {
        if (this.timed_wait_period > Duration.zero)
        {
            for (auto limit = base + period;
                !period.isNegative;
                period = limit - MonoTime.currTime)
            {
                if (Fiber.getThis())
                    Fiber.yield();
                Thread.sleep(1.msecs);
            }
        }
    }

    /***************************************************************************

        Called on thread termination. This routine processes any remaining
        control messages, clears out message queues, and sets a flag to
        reject any future messages.

    ***************************************************************************/

    public void close()
    {
        SudoFiber sf;
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
            if (sf.swdg !is null)
                sf.swdg();
        }

        while (true)
        {
            if (this.sendq[].walkLength == 0)
                break;
            sf = this.sendq.front;
            this.sendq.removeFront();
            if (sf.swdg !is null)
                sf.swdg();
        }
    }

private:

    // Routines involving local data only, no lock needed.
    bool isControlMsg (ref Message msg) @safe @nogc pure nothrow
    {
        return msg.type != MsgType.standard;
    }

    bool isLinkDeadMsg (ref Message msg) @safe @nogc pure nothrow
    {
        return msg.type == MsgType.linkDead;
    }

    /// closed
    bool closed;

    /// lock
    Mutex mutex;

    /// collection of send waiters
    DList!SudoFiber sendq;

    /// collection of recv waiters
    DList!SudoFiber recvq;

    /// timeout
    Duration timeout;

    /// use delay time in get
    bool timed_wait;

    /// delay time in get
    Duration timed_wait_period;
}

/// Called when restarting a fiber or thread that is waiting in a queue.
private alias StopWaitDg = void delegate ();

/*******************************************************************************

    It's a structure that has a fiber accessing a queue, a message,
    and a delegate that stops waiting.

*******************************************************************************/

private struct SudoFiber
{
    /// This is a message. Used in put
    public Message  msg;

    /// This is a message point. Used in get
    public Message* msg_ptr;

    /// The delegate that stops waiting.
    public StopWaitDg swdg;

    /// The creating time
    public MonoTime create_time;
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

        Spawns stops the Scheduler.

        This calls at the end of the program and commands the scheduler to end.

    ***************************************************************************/

    void stop ();

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

public class MessageDispatcher
{
    private MessageBox mbox;
    private Scheduler scheduler;

    public this ()
    {

    }

    public void send (T...)  (T vals)
    {
        _send(MsgType.standard, vals);
    }

    private void _send (T...)  (MsgType type, T vals)
    {
        auto msg = Message(type, vals);
        this.mbox.put(msg);
    }

    public void send (Message msg)
    {
        this.mbox.put(msg);
    }

    public void receive (ref Message msg)
    {

    }

    public void cleanup ()
    {
        this.mbox.close();
        if (scheduler !is null)
            scheduler.stop();
    }
}

public struct ThreadInfo
{
    public MessageDispatcher msg_dispatcher;

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
        this.msg_dispatcher.cleanup();
        //unregisterMe();
    }
}

// Thread Creation
private template isSpawnable (F, T...)
{
    template isParamsImplicitlyConvertible (F1, F2, int i = 0)
    {
        alias param1 = Parameters!F1;
        alias param2 = Parameters!F2;
        static if (param1.length != param2.length)
            enum isParamsImplicitlyConvertible = false;
        else static if (param1.length == i)
            enum isParamsImplicitlyConvertible = true;
        else static if (isImplicitlyConvertible!(param2[i], param1[i]))
            enum isParamsImplicitlyConvertible = isParamsImplicitlyConvertible!(F1,
                    F2, i + 1);
        else
            enum isParamsImplicitlyConvertible = false;
    }

    enum isSpawnable = isCallable!F && is(ReturnType!F == void)
            && isParamsImplicitlyConvertible!(F, void function(T))
            && (isFunctionPointer!F || !hasUnsharedAliasing!F);
}

public MessageDispatcher spawn (F, T...) (F fn, T args)
if (isSpawnable!(F, T))
{
    auto spawnTid = new MessageDispatcher(new MessageBox);

    void exec ()
    {
        thisInfo.ident = spawnTid;
        thisInfo.owner = ownerTid;
        fn(args);
    }

    void execInThread ()
    {
        auto ownerScheduler = new AutoDispatchScheduler(1.msecs);
        thisInfo.msg_dispatcher = spawnTid;
        thisInfo.scheduler.spawn({
            fn(args);
        });
    }

    auto t = new Thread(&execInThread);
    t.start();

    return spawnTid;
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

    public void start (void delegate () op)
    {
        op();
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

        Returns ThreadInfo.thisInfo, since it is a thread-local instance of
        ThreadInfo, which is the correct behavior for this scheduler.

    ***************************************************************************/

    public @property ref ThreadInfo thisInfo () nothrow
    {
        return ThreadInfo.thisInfo;
    }

    /***************************************************************************

        Creates a new Condition variable.  No custom behavior is needed here.

    ***************************************************************************/

    public Condition newCondition (Mutex m) nothrow
    {
        return new Condition(m);
    }

    /***************************************************************************

        This calls at the end of the program and commands the scheduler to end.

    ***************************************************************************/

    public void stop ()
    {

    }
}

/*******************************************************************************

    An Main-Thread's Scheduler using Fibers.

*******************************************************************************/

public class NodeScheduler : Scheduler
{
    private shared(bool) terminated;
    private Mutex m;
    private Duration sleep_interval;

    public this (Duration sleep = 10.msecs)
    {
        this.sleep_interval = sleep;
        if (this.sleep_interval < 1.msecs)
            this.sleep_interval = 1.msecs;
        this.m = new Mutex();
        this.terminated = false;
        new Thread({
            this.dispatch();
        }).start();
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
        This stops the dispatcher.

    ***************************************************************************/

    public void stop ()
    {
        terminated = true;
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

        Returns an appropriate ThreadInfo instance.

        Returns a ThreadInfo instance specific to the calling Fiber if the
        Fiber was created by this dispatcher, otherwise it returns
        ThreadInfo.thisInfo.

    ***************************************************************************/

    public @property ref ThreadInfo thisInfo () nothrow
    {
        auto f = cast(InfoFiber) Fiber.getThis();

        if (f !is null)
            return f.info;
        return ThreadInfo.thisInfo;
    }

    /***************************************************************************

        Returns a Condition analog that yields when wait or notify is called.

    ***************************************************************************/

    public Condition newCondition (Mutex m) nothrow
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
            mutex_nothrow.unlock_nothrow();
            scope (exit) mutex_nothrow.lock_nothrow();
            yield();
        }

        private bool notified;
    }

private:

    void dispatch ()
    {
        import std.algorithm.mutation : remove;
        bool done = terminated && (m_fibers.length == 0);

        while (!done)
        {
            m.lock();
            if (m_fibers.length > 0)
            {
                auto t = m_fibers[m_pos].call(Fiber.Rethrow.no);
                if (t !is null && !(cast(OwnerTerminated) t))
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
            m.unlock();
            Thread.sleep(this.sleep_interval);
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

        m.lock_nothrow();
        m_fibers ~= new InfoFiber(&wrap);
        m.unlock_nothrow();
    }

private:
    Fiber[] m_fibers;
    size_t m_pos;
}

/*******************************************************************************

    An Main-Thread's Scheduler using Fibers.

*******************************************************************************/

class MainScheduler : Scheduler
{
    private shared(bool) terminated;
    private Mutex m;
    private Duration sleep_interval;

    public this (Duration sleep = 10.msecs)
    {
        this.sleep_interval = sleep;
        if (this.sleep_interval < 1.msecs)
            this.sleep_interval = 1.msecs;
        this.m = new Mutex();
        this.terminated = false;
        new Thread({
            this.dispatch();
        }).start();
    }

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

    ***************************************************************************/

    public void start (void delegate () op)
    {
        create(op);
        yield();
    }

    /***************************************************************************

        This calls at the end of the program and commands the scheduler to end.
        This stops the dispatcher.

    ***************************************************************************/

    public void stop ()
    {
        terminated = true;
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

        Returns an appropriate ThreadInfo instance.

        Returns a ThreadInfo instance specific to the calling Fiber if the
        Fiber was created by this dispatcher, otherwise it returns
        ThreadInfo.thisInfo.

    ***************************************************************************/

    public @property ref ThreadInfo thisInfo () nothrow
    {
        auto f = cast(InfoFiber) Fiber.getThis();

        if (f !is null)
            return f.info;
        return ThreadInfo.thisInfo;
    }

    /***************************************************************************

        Returns a Condition analog that yields when wait or notify is called.

    ***************************************************************************/

    public Condition newCondition (Mutex m) nothrow
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
            mutex_nothrow.unlock_nothrow();
            scope (exit) mutex_nothrow.lock_nothrow();
            yield();
        }

        private bool notified;
    }

private:

    void dispatch ()
    {
        import std.algorithm.mutation : remove;
        bool done = terminated && (m_fibers.length == 0);

        while (!done)
        {
            m.lock();
            if (m_fibers.length > 0)
            {
                auto t = m_fibers[m_pos].call(Fiber.Rethrow.no);
                if (t !is null && !(cast(OwnerTerminated) t))
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
            m.unlock();
            Thread.sleep(this.sleep_interval);
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

        m.lock_nothrow();
        m_fibers ~= new InfoFiber(&wrap);
        m.unlock_nothrow();
    }

private:
    Fiber[] m_fibers;
    size_t m_pos;
}
