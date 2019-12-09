
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
    this () @trusted nothrow /* TODO: make @safe after relevant druntime PR gets merged */
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

public class MessageDispatcher
{
    private MessageBox mbox;

    public void send (MessageDispatcher dispatcher, Message msg)
    {

    }

    public void receive (ref Message msg)
    {

    }

    void cleanup ()
    {

    }
}

public struct ThreadInfo
{
    MessageDispatcher msg_dispatcher;

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

    void cleanup ()
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
    return _spawn(false, fn, args);
}

private MessageDispatcher _spawn (F, T...) (bool linked, F fn, T args)
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
