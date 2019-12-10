
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
import std.stdio;

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

private void checkops (T...) (T ops)
{
    foreach (i, t1; T)
    {
        static assert(isFunctionPointer!t1 || isDelegate!t1);
        alias a1 = Parameters!(t1);
        alias r1 = ReturnType!(t1);

        static if (i < T.length - 1 && is(r1 == void))
        {
            static assert(a1.length != 1 || !is(a1[0] == Variant),
                            "function with arguments " ~ a1.stringof ~
                            " occludes successive function");

            foreach (t2; T[i + 1 .. $])
            {
                static assert(isFunctionPointer!t2 || isDelegate!t2);
                alias a2 = Parameters!(t2);

                static assert(!is(a1 == a2),
                    "function with arguments " ~ a1.stringof ~ " occludes successive function");
            }
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

                    thisScheduler.yield();
                    wait(1.msecs);
                }
            }
            else
            {
                while (is_waiting)
                {
                    thisScheduler.yield();
                    wait(1.msecs);
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
                thisScheduler.yield();
                wait(1.msecs);
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
            assert(msg.convertsTo!(MessageDispatcher));
            auto tid = msg.get!(MessageDispatcher);

            if (tid == thisInfo.owner)
            {
                thisInfo.owner = null;
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

        bool scan (ref ListT list)
        {
            for (auto range = list[]; !range.empty;)
            {
                // Only the message handler will throw, so if this occurs
                // we can be certain that the message was handled.
                scope (failure)
                    list.removeAt(range);

                if (isControlMsg(range.front))
                {
                    if (onControlMsg(range.front))
                    {
                        // Although the linkDead message is a control message,
                        // it can be handled by the user.  Since the linkDead
                        // message throws if not handled, if we get here then
                        // it has been handled and we can return from receive.
                        // This is a weird special case that will have to be
                        // handled in a more general way if more are added.
                        if (!isLinkDeadMsg(range.front))
                        {
                            list.removeAt(range);
                            continue;
                        }
                        list.removeAt(range);
                        return true;
                    }
                    range.popFront();
                    continue;
                }
                else
                {
                    if (onStandardMsg(range.front))
                    {
                        list.removeAt(range);
                        return true;
                    }
                    range.popFront();
                    continue;
                }
            }
            return false;
        }

        Message msg;
        while (true)
        {
            ListT arrived;

            if (scan(this.localBox))
                return true;

            thisScheduler.yield();

            if (getMessage(&msg))
            {
                arrived.put(msg);

                if (scan(arrived))
                {
                    return true;
                }
                this.localBox.put(arrived);

                return true;
            }
            else
            {
                return false;
            }
        }
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
                thisScheduler.yield();
                wait(1.msecs);
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
        this.localBox.clear();

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

    alias ListT = List!(Message);

    ListT localBox;

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

///
private struct List (T)
{
    struct Range
    {
        import std.exception : enforce;

        @property bool empty () const
        {
            return !m_prev.next;
        }

        @property ref T front ()
        {
            enforce(m_prev.next, "invalid list node");
            return m_prev.next.val;
        }

        @property void front (T val)
        {
            enforce(m_prev.next, "invalid list node");
            m_prev.next.val = val;
        }

        void popFront ()
        {
            enforce(m_prev.next, "invalid list node");
            m_prev = m_prev.next;
        }

        private this (Node* p)
        {
            m_prev = p;
        }

        private Node* m_prev;
    }

    void put (T val)
    {
        put(newNode(val));
    }

    void put (ref List!(T) rhs)
    {
        if (!rhs.empty)
        {
            put(rhs.m_first);
            while (m_last.next !is null)
            {
                m_last = m_last.next;
                m_count++;
            }
            rhs.m_first = null;
            rhs.m_last = null;
            rhs.m_count = 0;
        }
    }

    Range opSlice ()
    {
        return Range(cast(Node*)&m_first);
    }

    void removeAt (Range r)
    {
        import std.exception : enforce;

        assert(m_count);
        Node* n = r.m_prev;
        enforce(n && n.next, "attempting to remove invalid list node");

        if (m_last is m_first)
            m_last = null;
        else if (m_last is n.next)
            m_last = n; // nocoverage
        Node* to_free = n.next;
        n.next = n.next.next;
        freeNode(to_free);
        m_count--;
    }

    @property size_t length ()
    {
        return m_count;
    }

    void clear ()
    {
        m_first = m_last = null;
        m_count = 0;
    }

    @property bool empty ()
    {
        return m_first is null;
    }

private:
    struct Node
    {
        Node* next;
        T val;

        this(T v)
        {
            val = v;
        }
    }

    static shared struct SpinLock
    {
        void lock ()
        {
            while (!cas(&locked, false, true))
            {
                Thread.yield();
            }
        }
        void unlock ()
        {
            atomicStore!(MemoryOrder.rel)(locked, false);
        }
        bool locked;
    }

    static shared SpinLock sm_lock;
    static shared Node* sm_head;

    Node* newNode (T v)
    {
        Node* n;
        {
            sm_lock.lock();
            scope (exit) sm_lock.unlock();

            if (sm_head)
            {
                n = cast(Node*) sm_head;
                sm_head = sm_head.next;
            }
        }
        if (n)
        {
            import std.conv : emplace;
            emplace!Node(n, v);
        }
        else
        {
            n = new Node(v);
        }
        return n;
    }

    void freeNode (Node* n)
    {
        // destroy val to free any owned GC memory
        destroy(n.val);

        sm_lock.lock();
        scope (exit) sm_lock.unlock();

        auto sn = cast(shared(Node)*) n;
        sn.next = sm_head;
        sm_head = sn;
    }

    void put (Node* n)
    {
        m_count++;
        if (!empty)
        {
            m_last.next = n;
            m_last = n;
            return;
        }
        m_first = n;
        m_last = n;
    }

    Node* m_first;
    Node* m_last;
    size_t m_count;
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

/*******************************************************************************


*******************************************************************************/

public class MessageDispatcher
{
    protected MessageBox mbox;

    public this ()
    {
        this.mbox = new MessageBox();
    }

    public void send (T...)  (T vals)
    {
        _send(MsgType.standard, vals);
    }

    private void _send (T...)  (MsgType type, T vals)
    {
        auto msg = Message(type, vals);
        if (Fiber.getThis())
            this.mbox.put(msg);
        else
            spawnChildFiber(
            {
                this.mbox.put(msg);
            });
    }

    public void receive (T...) (T ops)
    {

        checkops(ops);

        if (Fiber.getThis())
        {
            this.mbox.get(ops);
        }
        else
        {
            bool done = false;
            spawnChildFiber({
                this.mbox.get(ops);
                done = true;
            });
            while (!done) thisScheduler.yield();
        }
    }

    public void cleanup ()
    {
        this.mbox.close();
    }
}


/*******************************************************************************


*******************************************************************************/

public struct ThreadInfo
{
    public MessageDispatcher self;
    public MessageDispatcher owner;
    public Scheduler scheduler;
    public bool have_scheduler;
    public bool is_child;

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
        if (!this.is_child)
        {
            if (this.self !is null)
                this.self.cleanup();
            if (this.owner !is null)
                this.owner._send(MsgType.linkDead, this.self);
            if ((this.scheduler !is null) && this.have_scheduler)
                this.scheduler.stop();
            //unregisterMe();
        }
    }
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

private static class InfoFiber : Fiber
{
    ThreadInfo info;

    this (void delegate () op) nothrow
    {
        super(op);
    }
}

private class FiberCondition : Condition
{
    private FiberScheduler owner;

    public this (Mutex m, FiberScheduler s) nothrow
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
        mutex_nothrow.unlock_nothrow();
        scope (exit) mutex_nothrow.lock_nothrow();
        this.owner.yield();
    }

    private bool notified;
}


/*******************************************************************************

    An example Scheduler using Fibers.

    This is an example scheduler that creates a new Fiber per call to spawn
    and multiplexes the execution of all fibers within the main thread.

*******************************************************************************/

public class FiberScheduler : Scheduler
{
    protected Fiber[] m_fibers;
    protected size_t m_pos;

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

    public void stop ()
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
        return new FiberCondition(m, this);
    }

    protected void dispatch ()
    {
        import std.algorithm.mutation : remove;

        while (m_fibers.length > 0)
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
    }

    protected void create (void delegate () op) nothrow
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
}



/*******************************************************************************

    An Main-Thread's Scheduler using Fibers.

*******************************************************************************/

public class NodeScheduler : FiberScheduler
{
    private shared(bool) terminated;
    private shared(MonoTime) terminated_time;
    private shared(bool) stoped;
    private Mutex m;
    private Duration sleep_interval;

    public this ()
    {
        this.sleep_interval = 1.msecs;
        this.m = new Mutex();
        this.terminated = false;
        this.stoped = false;
    }

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

    ***************************************************************************/

    override public void start (void delegate () op)
    {
        create(op);
        dispatch();
    }

    /***************************************************************************

        This calls at the end of the program and commands the scheduler to end.
        This stops the dispatcher.

    ***************************************************************************/

    override public void stop ()
    {
        terminated = true;
        terminated_time = MonoTime.currTime;
        while (!this.stoped)
            Thread.sleep(100.msecs);
    }

    override protected void dispatch ()
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
            done = terminated || (m_fibers.length == 0);
            if (!done && terminated)
            {
                auto elapsed = MonoTime.currTime - terminated_time;
                if (elapsed > 3000.msecs)
                    done = true;
            }
            m.unlock();
            wait(this.sleep_interval);
        }
        this.stoped = true;
    }

    override protected void create (void delegate () op) nothrow
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
}



/*******************************************************************************

    An Main-Thread's Scheduler using Fibers.

*******************************************************************************/

public class MainScheduler : FiberScheduler
{
    private shared(bool) terminated;
    private shared(MonoTime) terminated_time;
    private shared(bool) stoped;
    private Mutex m;
    private Duration sleep_interval;
    private MessageDispatcher fiber_dispatcher;

    public this ()
    {
        this.sleep_interval = 10.msecs;
        this.m = new Mutex();
        this.terminated = false;
        this.stoped = false;

        void exec ()
        {
            this.dispatch();
        }

        thread_scheduler.spawn(&exec);
    }

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

    ***************************************************************************/

    override public void start (void delegate () op)
    {
        create(op);
        yield();
    }

    /***************************************************************************

        This calls at the end of the program and commands the scheduler to end.
        This stops the dispatcher.

    ***************************************************************************/

    override public void stop ()
    {
        terminated = true;
        terminated_time = MonoTime.currTime;
        while (!this.stoped)
            Thread.sleep(100.msecs);
    }

    override protected void dispatch ()
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
            if (!done && terminated)
            {
                auto elapsed = MonoTime.currTime - terminated_time;
                if (elapsed > 3000.msecs)
                    done = true;
            }
            m.unlock();
            wait(this.sleep_interval);
        }
        this.stoped = true;
    }

    override protected void create (void delegate () op) nothrow
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
}

public class MainDispatcher : MessageDispatcher
{

}

public class NodeDispatcher : MessageDispatcher
{

}

/*******************************************************************************

*******************************************************************************/

public @property ref ThreadInfo thisInfo () nothrow
{
    return ThreadInfo.thisInfo;
}


/*******************************************************************************

*******************************************************************************/

public @property MessageDispatcher thisMessageDispatcher () @safe
{
    static auto trus () @trusted
    {
        if (thisInfo.self !is null)
            return thisInfo.self;
        thisInfo.self = new MainDispatcher();
        thisInfo.scheduler = new MainScheduler();
        thisInfo.have_scheduler = true;
        return thisInfo.self;
    }

    return trus();
}


/*******************************************************************************

*******************************************************************************/

public @property MessageDispatcher ownerMessageDispatcher ()
{
    return thisInfo.owner;
}


/*******************************************************************************

*******************************************************************************/

public @property Scheduler thisScheduler () @safe
{
    static auto trus () @trusted
    {
        if (thisInfo.scheduler !is null)
            return thisInfo.scheduler;
        if (thisInfo.self is null)
            thisInfo.self = new MainDispatcher();
        thisInfo.scheduler = new MainScheduler();
        thisInfo.have_scheduler = true;
        return thisInfo.scheduler;
    }

    return trus();
}


/*******************************************************************************

*******************************************************************************/

// Exceptions

/// Thrown on calls to `receive` if the thread that spawned the receiving
/// thread has terminated and no more messages exist.
public class OwnerTerminated : Exception
{
    /// Ctor
    public this (MessageDispatcher d, string msg = "Owner terminated") @safe pure nothrow @nogc
    {
        super(msg);
        dispatcher = d;
    }

    public MessageDispatcher dispatcher;
}

/// Thrown if a linked thread has terminated.
public class LinkTerminated : Exception
{
    /// Ctor
    public this (MessageDispatcher d, string msg = "Link terminated") @safe pure nothrow @nogc
    {
        super(msg);
        dispatcher = d;
    }

    public MessageDispatcher dispatcher;
}


__gshared ThreadScheduler thread_scheduler;

static this ()
{
    if (thread_scheduler is null)
        thread_scheduler = new ThreadScheduler();
}

static ~this ()
{
    thisInfo.cleanup();
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

public MessageDispatcher spawnThread (F, T...) (F fn, T args)
if (isSpawnable!(F, T))
{
    auto spawn_dispatcher = new NodeDispatcher();
    auto owner_dispatcher = thisMessageDispatcher();
    auto spawn_scheduler = new NodeScheduler();
/*
    void exec ()
    {
        thisInfo.self = spawn_dispatcher;
        thisInfo.owner = owner_dispatcher;
        thisInfo.scheduler = owner_scheduler;
        thisInfo.have_scheduler = true;
        thisInfo.is_child = false;
        fn(args);
        thisInfo.scheduler.start({});
        thisInfo.scheduler.start({
            thisInfo.self = spawn_dispatcher;
            thisInfo.owner = spawn_dispatcher;
            thisInfo.scheduler = owner_scheduler;
            thisInfo.have_scheduler = false;
            thisInfo.is_child = true;
            fn(args);
        });
    }

    thread_scheduler.spawn(&exec);
*/
    void execInThread ()
    {
        thisInfo.self = spawn_dispatcher;
        thisInfo.owner = owner_dispatcher;
        thisInfo.scheduler = spawn_scheduler;
        thisInfo.have_scheduler = true;
        thisInfo.is_child = false;

        thisInfo.scheduler.start({
            thisInfo.self = spawn_dispatcher;
            thisInfo.owner = owner_dispatcher;
            thisInfo.scheduler = spawn_scheduler;
            thisInfo.have_scheduler = false;
            thisInfo.is_child = true;
            fn(args);
        });
    }

    auto t = new Thread(&execInThread);
    t.start();

    return spawn_dispatcher;
}

public MessageDispatcher spawnFiber (void delegate () op)
{
    auto spawn_dispatcher = new MessageDispatcher();
    auto owner_dispatcher = thisMessageDispatcher();
    auto owner_scheduler = thisScheduler;

    thisScheduler.spawn(
    {
        thisInfo.self = spawn_dispatcher;
        thisInfo.owner = owner_dispatcher;
        thisInfo.scheduler = owner_scheduler;
        thisInfo.have_scheduler = false;
        thisInfo.is_child = false;
        op();
    });

    return spawn_dispatcher;
}

public void spawnChildFiber (void delegate () op)
{
    auto owner_dispatcher = thisMessageDispatcher();
    auto owner_scheduler = thisScheduler;

    thisScheduler.spawn(
    {
        thisInfo.self = owner_dispatcher;
        thisInfo.owner = owner_dispatcher;
        thisInfo.scheduler = owner_scheduler;
        thisInfo.have_scheduler = false;
        thisInfo.is_child = true;
        op();
    });
}

void wait(Duration val)
{
    /*
    if (thread_scheduler !is null)
    {
        auto condition = thread_scheduler.newCondition(null);
        condition.wait(val);
    }
    else
    */
       Thread.sleep(val);
}


unittest
{
    import std.concurrency;
    import std.stdio;

    auto process = ()
    {
        size_t message_count = 2;
        while (message_count--)
        {
            thisMessageDispatcher.receive(
                (int i)
                {
                    writefln("Child thread received int: %s", i);
                    ownerMessageDispatcher.send(i);
                },
                (string s)
                {
                    writefln("Child thread received string: %s", s);
                    ownerMessageDispatcher.send(s);
                }
            );
        }
    };

    auto spawnedMessageDispatcher = spawnThread(process);
    spawnedMessageDispatcher.send(42);
    spawnedMessageDispatcher.send("string");

    // REQUIRED in new API
    Thread.sleep(100.msecs);

    // in new API this will drop all messages from the queue which do not match `string`
    thisMessageDispatcher.receive(
        (string s)
        {
             writefln("Main thread received string: %s", s);
        }
    );

    thisMessageDispatcher.receive(
        (int s)
        {
            writefln("Main thread received int: %s", s);
        }
    );
    writeln("Done");
}


/*
///
@system unittest
{
    import std.variant : Variant;

    auto process = ()
    {
        thisMessageDispatcher.receive(
            (int i)
            {
                ownerMessageDispatcher.send(1);
            },
            (double f)
            {
                ownerMessageDispatcher.send(2);
            },
            (Variant v)
            {
                ownerMessageDispatcher.send(3);
            }
        );
    };

    {
        auto spawnedMessageDispatcher = spawnThread(process);
        spawnedMessageDispatcher.send(42);
        thisMessageDispatcher.receive((int res) {
            writefln("thisMessageDispatcher.receive %s", res);
            assert(res == 1);
        });
    }

    {
        auto spawnedMessageDispatcher = spawnThread(process);
        spawnedMessageDispatcher.send(3.14);

        thisMessageDispatcher.receive((int res) {
            writefln("thisMessageDispatcher.receive %s", res);
            assert(res == 2);
        });
    }

    {
        auto spawnedMessageDispatcher = spawnThread(process);
        spawnedMessageDispatcher.send("something else");

        thisMessageDispatcher.receive((int res) {
            writefln("thisMessageDispatcher.receive %s", res);
            assert(res == 3);
        });
    }
}
*/
