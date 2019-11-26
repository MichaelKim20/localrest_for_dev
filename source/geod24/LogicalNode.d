module geod24.LogicalNode;

import std.container;
import std.datetime;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.traits;
public import std.variant;
public import std.stdio;

import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.thread;

/*******************************************************************************

    Message
    
*******************************************************************************/


public enum MsgType
{
    standard,
    linkDead,
}

public struct Message
{
    MsgType type;
    Variant data;
    MonoTime create_time;

    this (T...)(MsgType t, T vals) if (T.length > 0)
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

    @property auto convertsTo (T...)()
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

    auto map (Op)(Op op)
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

public void checkops (T...)(T ops)
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

    MessageBox

    A MessageBox is a message queue for one thread.  Other threads may send
    messages to this owner by calling put(), and the owner receives them by
    calling get().  The put() call is therefore effectively shared and the
    get() call is effectively local.  setMaxMsgs may be used by any thread
    to limit the size of the message queue.

*******************************************************************************/

private class MessageBox
{
    /// closed
    private bool closed;

    /// lock
    private Mutex mutex;

    /// collection of send waiters
    private DList!SudoFiber sendq;

    /// collection of recv waiters
    private DList!SudoFiber recvq;

    private Duration timeout;

    private bool timed_wait;

    private Duration timed_wait_period;

    private MonoTime limit;

    private alias StopWaitDg = void delegate ();

    private struct SudoFiber
    {
        public Message* req_msg;
        public Message* res_msg;
        public StopWaitDg swdg;
        public MonoTime create_time;
    }

    public this () @trusted nothrow
    {
        this.mutex = new Mutex();
        this.closed = false;
        this.timeout = Duration.init;
    }

    public void setTimeout (Duration d) @safe pure nothrow @nogc
    {
        this.timeout = d;
    }

    ///
    public @property bool isClosed () @safe @nogc pure
    {
        synchronized (this.mutex)
        {
            return this.closed;
        }
    }

    public Message put (ref Message req_msg)
    {
        import std.algorithm;
        import std.range : popBackN, walkLength;

        writefln("request %s %s", Fiber.getThis(), req_msg);

        this.mutex.lock();
        if (this.closed)
        {
            this.mutex.unlock();
            return Message(MsgType.standard, Response(Status.Failed, ""));
        }

        if (this.recvq[].walkLength > 0)
        {
            SudoFiber sf = this.recvq.front;
            this.recvq.removeFront();
            *sf.req_msg = req_msg;

            if (sf.swdg !is null)
                sf.swdg();

            this.mutex.unlock();

            return *sf.res_msg;
        }

        {
            Message res_msg;
            shared(bool) is_waiting = true;
            void stopWait ()
            {
                is_waiting = false;
            }

            SudoFiber new_sf;
            new_sf.req_msg = &req_msg;
            new_sf.res_msg = &res_msg;
            new_sf.swdg = &stopWait;
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
                        this.mutex.lock();
                        auto range = find(this.sendq[], new_sf);
                        if (!range.empty)
                        {
                            popBackN(range, range.walkLength-1);
                            this.sendq.remove(range);
                        }
                        scope(exit) this.mutex.unlock();
                        return Message(MsgType.standard, Response(Status.Timeout, ""));
                    }
                    
                    if (Fiber.getThis() !is null)
                        Fiber.yield();
                    else
                        Thread.sleep(1.msecs);
                }
            }
            else
            {
                while (is_waiting)
                {
                    if (Fiber.getThis() !is null)
                        Fiber.yield();
                    else
                        Thread.sleep(1.msecs);
                }
            }

            if (this.timed_wait)
            {
                this.waitFromBase(new_sf.create_time, this.timed_wait_period);
                this.timed_wait = false;
            }

            return res_msg;
        }
    }

    public bool get (T...) (scope T vals)
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

        writefln("get %s", Fiber.getThis());

        bool onStandardMsg (Message* req_msg, Message* res_msg = null)
        {
            foreach (i, t; Ops)
            {
                alias Args = Parameters!(t);
                auto op = ops[i];

                if (req_msg.convertsTo!(Args))
                {
                    static if (is(ReturnType!(t) == Response))
                    {
                        if (res_msg !is null)
                            *res_msg = Message(MsgType.standard, (*req_msg).map(op));
                        else
                            (*req_msg).map(op);
                        return true;
                    }
                    else if (is(ReturnType!(t) == bool))
                    {
                        (*req_msg).map(op);
                        return true;
                    }
                    else
                    {
                        (*req_msg).map(op);
                        return true;
                    }
                }
            }
            return false;
        }

        bool onLinkDeadMsg(Message* msg)
        {
            assert(msg.convertsTo!(Tid));
            auto tid = msg.get!(Tid);

            if (bool* pDepends = tid in thisInfo.links)
            {
                auto depends = *pDepends;
                thisInfo.links.remove(tid);

                if (depends && tid != thisInfo.owner)
                {
                    auto e = new LinkTerminated(tid);
                    auto m = Message(MsgType.standard, e);
                    if (onStandardMsg(&m))
                        return true;
                    throw e;
                }
            }

            if (tid == thisInfo.owner)
            {
                thisInfo.owner = Tid.init;
                auto e = new OwnerTerminated(tid);
                auto m = Message(MsgType.standard, e);
                if (onStandardMsg(&m))
                    return true;
                throw e;
            }

            return false;
        }

        bool onControlMsg(Message* req_msg, Message* res_msg)
        {
            switch (req_msg.type)
            {
                case MsgType.linkDead:
                    auto result = onLinkDeadMsg(req_msg);
                    if (res_msg !is null)
                        *res_msg = Message(MsgType.standard, Response(Status.Success, ""));
                    return result;
                default:
                    if (res_msg !is null)
                        *res_msg = Message(MsgType.standard, Response(Status.Failed, ""));
                    return false;
            }
        }

        bool processMsg ()
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

                if (isControlMsg(sf.req_msg))
                    onControlMsg(sf.req_msg, sf.res_msg);
                else
                    onStandardMsg(sf.req_msg, sf.res_msg);

                if (sf.swdg !is null)
                    sf.swdg();

                this.mutex.unlock();

                if (this.timed_wait)
                {
                    this.waitFromBase(sf.req_msg.create_time, this.timed_wait_period);
                    this.timed_wait = false;
                }

                return true;
            }

            {
                Message req_msg;
                Message res_msg;
                SudoFiber new_sf;
                new_sf.req_msg = &req_msg;
                new_sf.res_msg = &res_msg;
                new_sf.create_time = MonoTime.currTime;

                shared(bool) is_waiting1 = true;
                void stopWait1() 
                {
                    if (isControlMsg(&req_msg))
                        onControlMsg(&req_msg, &res_msg);
                    else
                        onStandardMsg(&req_msg, &res_msg);

                    is_waiting1 = false;
                }
                new_sf.swdg = &stopWait1;

                this.recvq.insertBack(new_sf);
                this.mutex.unlock();

                while (is_waiting1)
                {
                    if (Fiber.getThis() !is null)
                        Fiber.yield();
                    else
                        Thread.sleep(1.msecs);
                }

                if (this.timed_wait)
                {
                    this.waitFromBase(new_sf.create_time, this.timed_wait_period);
                    this.timed_wait = false;
                }

                return true;
            }
        }

        return processMsg();
    }
    public void close ()
    {
        static void onLinkDeadMsg (Message* msg)
        {
            assert(msg.convertsTo!(Tid));
            auto tid = msg.get!(Tid);

            thisInfo.links.remove(tid);
            if (tid == thisInfo.owner)
                thisInfo.owner = Tid.init;
        }

        writefln("close");

        SudoFiber sf;

        this.mutex.lock();
        scope (exit) this.mutex.unlock();

        this.closed = true;

        writefln("close1");

        while (true)
        {
            if (this.recvq[].walkLength == 0)
                break;
            sf = this.recvq.front;
            this.recvq.removeFront();
                
            *sf.req_msg = Message(MsgType.standard, new LinkTerminated(thisTid));

            if (sf.swdg !is null)
                sf.swdg();
        }

        writefln("close2");

        while (true)
        {
            if (this.sendq[].walkLength == 0)
                break;
            sf = this.sendq.front;
            this.sendq.removeFront();

            if (sf.req_msg.type == MsgType.linkDead)
                onLinkDeadMsg(sf.req_msg);

            if (sf.swdg !is null)
                sf.swdg();
        }

        writefln("close3");
    }

    private void waitFromBase (MonoTime base, Duration period)
    {
        if (this.timed_wait_period > Duration.zero)
        {
            for (auto limit = base + period;
                !period.isNegative;
                period = limit - MonoTime.currTime)
            {
                yield();
            }
        }
    }


    private bool isControlMsg (Message* msg) @safe @nogc pure nothrow
    {
        return msg.type != MsgType.standard;
    }

    private bool isLinkDeadMsg (Message* msg) @safe @nogc pure nothrow
    {
        return msg.type == MsgType.linkDead;
    }

}


/*******************************************************************************

    Thread ID

    An opaque type used to represent a logical thread.

*******************************************************************************/

public struct Tid
{
    private MessageBox mbox;
    private Duration _timeout;
    private bool _shutdowned;

    public this (MessageBox m) @safe pure nothrow @nogc
    {
        this.mbox = m;
        this._timeout = Duration.init;
        this._shutdowned = false;
    }

    public @property void timeout (Duration value) @safe pure nothrow @nogc
    {
        this._timeout = d;
        this.mbox.setTimeout(d);
    }

    public @property Duration timeout () @safe @nogc pure
    {
        return this._timeout;
    }
    
    public @property void shutdown (bool value) @safe pure nothrow @nogc
    {
        this._shutdowned = value;
    }

    public @property bool shutdown () @safe @nogc pure
    {
        return this._shutdowned;
    }

    public void toString(scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "Tid(%x)", cast(void*) mbox);
    }
}

@system unittest
{
    // text!Tid is @system
    import std.conv : text;
    Tid tid;
    assert(text(tid) == "Tid(0)");
    auto tid2 = thisTid;
    assert(text(tid2) != "Tid(0)");
    auto tid3 = tid2;
    assert(text(tid2) == text(tid3));
}


/*******************************************************************************

    Returns: The $(LREF Tid) of the caller's thread.

*******************************************************************************/

@property Tid thisTid() @safe
{
    static auto trus() @trusted
    {
        if (thisInfo.ident != Tid.init)
            return thisInfo.ident;
        thisInfo.ident = Tid(new MessageBox);
        return thisInfo.ident;
    }

    return trus();
}

/**
 * Return the Tid of the thread which spawned the caller's thread.
 *
 * Throws: A `TidMissingException` exception if
 * there is no owner thread.
 */
@property Tid ownerTid()
{
    import std.exception : enforce;

    enforce!TidMissingException(thisInfo.owner.mbox !is null, "Error: Thread has no owner thread.");
    return thisInfo.owner;
}

// Thread Creation

private template isSpawnable(F, T...)
{
    template isParamsImplicitlyConvertible(F1, F2, int i = 0)
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

/**
 * Starts fn(args) in a new logical thread.
 *
 * Executes the supplied function in a new logical thread represented by
 * `Tid`.  The calling thread is designated as the owner of the new thread.
 * When the owner thread terminates an `OwnerTerminated` message will be
 * sent to the new thread, causing an `OwnerTerminated` exception to be
 * thrown on `receive()`.
 *
 * Params:
 *  fn   = The function to execute.
 *  args = Arguments to the function.
 *
 * Returns:
 *  A Tid representing the new logical thread.
 *
 * Notes:
 *  `args` must not have unshared aliasing.  In other words, all arguments
 *  to `fn` must either be `shared` or `immutable` or have no
 *  pointer indirection.  This is necessary for enforcing isolation among
 *  threads.
 */
Tid spawn (F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    return _spawn(true, fn, args);
}

///
@system unittest
{
    static void f(string msg)
    {
        assert(msg == "Hello World");
    }

    auto tid = spawn(&f, "Hello World");
}

/// Fails: char[] has mutable aliasing.
@system unittest
{
    string msg = "Hello, World!";

    static void f1(string msg) {}
    static assert(!__traits(compiles, spawn(&f1, msg.dup)));
    static assert( __traits(compiles, spawn(&f1, msg.idup)));

    static void f2(char[] msg) {}
    static assert(!__traits(compiles, spawn(&f2, msg.dup)));
    static assert(!__traits(compiles, spawn(&f2, msg.idup)));
}


Tid spawnLinked(F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    return _spawn(true, fn, args);
}

/*
 *
 */
private Tid _spawn(F, T...)(bool linked, F fn, T args)
if (isSpawnable!(F, T))
{
    // TODO: MessageList and &exec should be shared.
    auto spawnTid = Tid(new MessageBox);
    auto ownerTid = thisTid;

    void exec()
    {
        thisInfo.ident = spawnTid;
        thisInfo.owner = ownerTid;
        fn(args);
    }

    // TODO: MessageList and &exec should be shared.
    auto t = new Thread(&exec);
    t.start();

    thisInfo.links[spawnTid] = linked;
    return spawnTid;
}

@system unittest
{
    void function() fn1;
    void function(int) fn2;
    static assert(__traits(compiles, spawn(fn1)));
    static assert(__traits(compiles, spawn(fn2, 2)));
    static assert(!__traits(compiles, spawn(fn1, 1)));
    static assert(!__traits(compiles, spawn(fn2)));

    void delegate(int) shared dg1;
    shared(void delegate(int)) dg2;
    shared(void delegate(long) shared) dg3;
    shared(void delegate(real, int, long) shared) dg4;
    void delegate(int) immutable dg5;
    void delegate(int) dg6;
    static assert(__traits(compiles, spawn(dg1, 1)));
    static assert(__traits(compiles, spawn(dg2, 2)));
    static assert(__traits(compiles, spawn(dg3, 3)));
    static assert(__traits(compiles, spawn(dg4, 4, 4, 4)));
    static assert(__traits(compiles, spawn(dg5, 5)));
    static assert(!__traits(compiles, spawn(dg6, 6)));

    auto callable1  = new class{ void opCall(int) shared {} };
    auto callable2  = cast(shared) new class{ void opCall(int) shared {} };
    auto callable3  = new class{ void opCall(int) immutable {} };
    auto callable4  = cast(immutable) new class{ void opCall(int) immutable {} };
    auto callable5  = new class{ void opCall(int) {} };
    auto callable6  = cast(shared) new class{ void opCall(int) immutable {} };
    auto callable7  = cast(immutable) new class{ void opCall(int) shared {} };
    auto callable8  = cast(shared) new class{ void opCall(int) const shared {} };
    auto callable9  = cast(const shared) new class{ void opCall(int) shared {} };
    auto callable10 = cast(const shared) new class{ void opCall(int) const shared {} };
    auto callable11 = cast(immutable) new class{ void opCall(int) const shared {} };
    static assert(!__traits(compiles, spawn(callable1,  1)));
    static assert( __traits(compiles, spawn(callable2,  2)));
    static assert(!__traits(compiles, spawn(callable3,  3)));
    static assert( __traits(compiles, spawn(callable4,  4)));
    static assert(!__traits(compiles, spawn(callable5,  5)));
    static assert(!__traits(compiles, spawn(callable6,  6)));
    static assert(!__traits(compiles, spawn(callable7,  7)));
    static assert( __traits(compiles, spawn(callable8,  8)));
    static assert(!__traits(compiles, spawn(callable9,  9)));
    static assert( __traits(compiles, spawn(callable10, 10)));
    static assert( __traits(compiles, spawn(callable11, 11)));
}


/*******************************************************************************

    Struct of Data 
    

*******************************************************************************/

/// Data sent by the caller
struct Request
{
    /// Tid of the sender thread (cannot be JSON serialized)
    Tid sender;

    /// Method to call
    string method;

    /// Arguments to the method, JSON formatted
    string args;
}

/// Status of a request
enum Status
{
    /// Request failed
    Failed,

    /// Request timed-out
    Timeout,

    /// Request succeeded
    Success
}

/// Data sent by the callee back to the caller
struct Response
{
    /// Final status of a request (failed, timeout, success, etc)
    Status status;

    /// If `status == Status.Success`, the JSON-serialized return value.
    /// Otherwise, it contains `Exception.toString()`.
    string data;
}


/*******************************************************************************

    Exceptions
    

*******************************************************************************/

/**
 * Thrown on calls to `receiveOnly` if a message other than the type
 * the receiving thread expected is sent.
 */
public class MessageMismatch : Exception
{
    ///
    public this (string msg = "Unexpected message type") @safe pure nothrow @nogc
    {
        super(msg);
    }
}

/**
 * Thrown on calls to `receive` if the thread that spawned the receiving
 * thread has terminated and no more messages exist.
 */
public class OwnerTerminated : Exception
{
    ///
    public this (Tid t, string msg = "Owner terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    public Tid tid;
}

/**
 * Thrown if a linked thread has terminated.
 */
public class LinkTerminated : Exception
{
    ///
    public this (Tid t, string msg = "Link terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    public Tid tid;
}

/**
 * Thrown when a Tid is missing, e.g. when `ownerTid` doesn't
 * find an owner thread.
 */
public class TidMissingException : Exception
{
    import std.exception : basicExceptionCtors;
    ///
    mixin basicExceptionCtors;
}

private bool hasLocalAliasing (Types...)()
{
    // Works around "statement is not reachable"
    bool doesIt = false;
    static foreach (T; Types)
    {
        static if (is(T == Tid))
        { /* Allowed */ }
        else static if (is(T == struct))
            doesIt |= hasLocalAliasing!(typeof(T.tupleof));
        else
            doesIt |= std.traits.hasUnsharedAliasing!(T);
    }
    return doesIt;
}

@safe unittest
{
    static struct Container { double t; }
    static assert(!hasLocalAliasing!(Tid, Container, int));
}

