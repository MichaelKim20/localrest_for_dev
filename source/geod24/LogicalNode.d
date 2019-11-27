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

///
public enum MsgType
{
    standard,
    linkDead,
    close,
}

///
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

    ///
    private Duration _timeout;

    ///
    private alias StopWaitDg = void delegate ();

    ///
    private struct SudoFiber
    {
        public Message* req_msg;
        public Message* res_msg;
        public StopWaitDg swdg;
        public MonoTime create_time;
    }

    ///
    public this () @trusted nothrow
    {
        this.mutex = new Mutex();
        this.closed = false;
        this._timeout = Duration.init;
    }


    /***************************************************************************



    ***************************************************************************/

    public @property void timeout (Duration value) @safe pure nothrow @nogc
    {
        this._timeout = value;
    }

    /***************************************************************************



    ***************************************************************************/

    public @property bool isClosed () @safe @nogc pure
    {
        synchronized (this.mutex)
        {
            return this.closed;
        }
    }

    /***************************************************************************



    ***************************************************************************/

    public Message put (ref Message req_msg)
    {
        import std.algorithm;

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

            if (this._timeout > Duration.init)
            {
                auto start = req_msg.create_time;
                while (is_waiting)
                {
                    auto end = MonoTime.currTime();
                    auto elapsed = end - start;
                    if (elapsed > this._timeout)
                    {
                        this.mutex.lock();
                        auto range = find(this.sendq[], new_sf);
                        if (!range.empty)
                        {
                            popBackN(range, range.walkLength-1);
                            this.sendq.remove(range);
                        }
                        this.mutex.unlock();
                        return Message(MsgType.standard, Response(Status.Timeout, ""));
                    }

                    if (Fiber.getThis())
                        Fiber.yield();
                    else
                        Thread.sleep(1.msecs);
                }
            }
            else
            {
                while (is_waiting)
                {
                    if (Fiber.getThis())
                        Fiber.yield();
                    else
                        Thread.sleep(1.msecs);
                }
            }

            return res_msg;
        }
    }

    /***************************************************************************



    ***************************************************************************/

    public bool get (T...) (scope T vals)
    {
        import std.meta : AliasSeq;

        static assert(T.length);

        alias Ops = AliasSeq!(T);
        alias ops = vals[0 .. $];

        /***********************************************************************



        ***********************************************************************/

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
                        {
                            /*
                            *res_msg = Message(MsgType.standard, (*req_msg).map(op));
                            if (this._timeout > Duration.init)
                            {
                                auto elapsed = MonoTime.currTime() - req_msg.create_time;
                                if (elapsed > this._timeout)
                                {
                                    writefln("F 0");
                                    *res_msg = Message(MsgType.standard, Response(Status.Timeout, ""));
                                }
                            }
                            */

                            writefln("Fiber %s", Fiber.getThis());

                            if (this._timeout > Duration.init)
                            {
                                shared(bool) timeovered = false; 
                                shared(bool) done = false;
                                auto start = req_msg.create_time;

                                new Thread({
                                    new Fiber({
                                        auto res = Message(MsgType.standard, (*req_msg).map(op));
                                        if (!timeovered) *res_msg = res;
                                        done = true;
                                    }).call();
                                }).start();

                                while (!done)
                                {
                                    auto end = MonoTime.currTime();
                                    auto elapsed = end - start;

                                    if (elapsed > this._timeout)
                                    {
                                        timeovered = true;
                                        *res_msg = Message(MsgType.standard, Response(Status.Timeout, ""));
                                        break;
                                    }

                                    if (Fiber.getThis())
                                        Fiber.yield();
                                }
                            }
                            else
                            {
                                *res_msg = Message(MsgType.standard, (*req_msg).map(op));
                            }
                        }
                        else
                        {
                            (*req_msg).map(op);
                        }

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


        /***********************************************************************



        ***********************************************************************/

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

        /***********************************************************************



        ***********************************************************************/

        bool onControlMsg(Message* req_msg, Message* res_msg)
        {
            switch (req_msg.type)
            {
                case MsgType.linkDead:
                    auto result = onLinkDeadMsg(req_msg);
                    if (res_msg !is null)
                        *res_msg = Message(MsgType.standard, Response(Status.Success, ""));
                    return result;

                case MsgType.close:
                    if (res_msg !is null)
                        *res_msg = Message(MsgType.standard, Response(Status.Success, ""));
                    return false;

                default:
                    if (res_msg !is null)
                        *res_msg = Message(MsgType.standard, Response(Status.Failed, ""));
                    return false;
            }
        }

        /***********************************************************************



        ***********************************************************************/

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
                if (isControlMsg(sf.req_msg))
                    onControlMsg(sf.req_msg, sf.res_msg);
                else
                    onStandardMsg(sf.req_msg, sf.res_msg);

                if (sf.swdg !is null)
                    sf.swdg();

                this.sendq.removeFront();
                this.mutex.unlock();

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
                    if (Fiber.getThis())
                        Fiber.yield();
                    else
                        Thread.sleep(1.msecs);
                }

                return true;
            }
        }

        return processMsg();
    }


    /***************************************************************************



    ***************************************************************************/

    public void close ()
    {
        ///
        static void onLinkDeadMsg (Message* msg)
        {
            assert(msg.convertsTo!(Tid));
            auto tid = msg.get!(Tid);

            thisInfo.links.remove(tid);
            if (tid == thisInfo.owner)
                thisInfo.owner = Tid.init;
        }

        SudoFiber sf;

        this.mutex.lock();
        scope (exit) this.mutex.unlock();

        this.closed = true;

        while (true)
        {
            if (this.recvq[].walkLength == 0)
                break;
            sf = this.recvq.front;
            this.recvq.removeFront();

            *sf.req_msg = Message(MsgType.close, "");

            if (sf.swdg !is null)
                sf.swdg();
        }

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
    }


    /***************************************************************************



    ***************************************************************************/

    private bool isControlMsg (Message* msg) @safe @nogc pure nothrow
    {
        return msg.type != MsgType.standard;
    }

    /***************************************************************************



    ***************************************************************************/

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


    /***************************************************************************



    ***************************************************************************/

    public this (MessageBox m) @safe pure nothrow @nogc
    {
        this.mbox = m;
        this._timeout = Duration.init;
        this._shutdowned = false;
    }


    /***************************************************************************



    ***************************************************************************/

    public @property void timeout (Duration value) @safe pure nothrow @nogc
    {
        this._timeout = value;
        this.mbox.timeout = value;
    }

    /***************************************************************************



    ***************************************************************************/

    public @property Duration timeout () @safe @nogc pure
    {
        return this._timeout;
    }


    /***************************************************************************



    ***************************************************************************/

    public @property void shutdown (bool value) @safe pure nothrow @nogc
    {
        this._shutdowned = value;
    }


    /***************************************************************************



    ***************************************************************************/

    public @property bool shutdown () @safe @nogc pure
    {
        return this._shutdowned;
    }


    /***************************************************************************



    ***************************************************************************/

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

/*******************************************************************************
 * Return the Tid of the thread which spawned the caller's thread.
 *
 * Throws: A `TidMissingException` exception if
 * there is no owner thread.
 *******************************************************************************/

@property Tid ownerTid()
{
    import std.exception : enforce;

    enforce!TidMissingException
        (thisInfo.owner.mbox !is null, "Error: Thread has no owner thread.");
    return thisInfo.owner;
}

/*******************************************************************************

    Thread Creation

*******************************************************************************/

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

/*******************************************************************************
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
*******************************************************************************/

public Tid spawn (F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T),
        "Aliases to mutable thread-local data not allowed.");
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

/*******************************************************************************



*******************************************************************************/

public Tid spawnLinked(F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T),
        "Aliases to mutable thread-local data not allowed.");
    return _spawn(true, fn, args);
}

/*******************************************************************************


*******************************************************************************/

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

    Places the values as a message at the back of tid's message queue.
    Sends the supplied value to the thread represented by tid.  As with
    $(REF spawn, std,concurrency), `T` must not have unshared aliasing.

*******************************************************************************/

public void send (T...)(Tid tid, T vals)
{
    static assert(!hasLocalAliasing!(T),
        "Aliases to mutable thread-local data not allowed.");
    _send(tid, vals);
}

/*******************************************************************************

    Places the values as a message at the back of tid's message queue.
    Sends the supplied value to the thread represented by tid.  As with
    $(REF spawn, std,concurrency), `T` must not have unshared aliasing.

*******************************************************************************/

private void _send (T...)(Tid tid, T vals)
{
    _send(MsgType.standard, tid, vals);
}

/*******************************************************************************

    Implementation of send.  This allows parameter checking to be different for
    both Tid.send() and .send().

*******************************************************************************/

private void _send (T...)(MsgType type, Tid tid, T vals)
{
    auto msg = Message(type, vals);

    if (Fiber.getThis())
        tid.mbox.put(msg);
    else
    {
        auto condition = scheduler.newCondition();
        scheduler.start(() {
            tid.mbox.put(msg);
            condition.notify();
        });
        condition.wait();
    }
}

/*******************************************************************************

    Receives a message from another thread.

    Receive a message from another thread, or block if no messages of the
    specified types are available.  This function works by pattern matching
    a message against a set of delegates and executing the first match found.

    If a delegate that accepts a $(REF Variant, std,variant) is included as
    the last argument to `receive`, it will match any message that was not
    matched by an earlier delegate.  If more than one argument is sent,
    the `Variant` will contain a $(REF Tuple, std,typecons) of all values
    sent.

*******************************************************************************/

public void receive (T...)( T ops )
in
{
    assert(thisInfo.ident.mbox !is null,
           "Cannot receive a message until a thread was spawned "
           ~ "or thisTid was passed to a running thread.");
}
do
{
    checkops( ops );

    if (Fiber.getThis())
        thisInfo.ident.mbox.get(ops);
    else
    {
        auto condition = scheduler.newCondition();
        scheduler.start(
        {
            thisInfo.ident.mbox.get(ops);
            condition.notify();
        });
        condition.wait();
    }
}


/*******************************************************************************



*******************************************************************************/

public Response query (Tid tid, ref Request data)
{
    auto req = Message(MsgType.standard, data);
    auto res = request(tid, req);
    return *res.data.peek!(Response);
}


/*******************************************************************************



*******************************************************************************/

public Message request (Tid tid, ref Message msg)
{
    if (Fiber.getThis())
        return tid.mbox.put(msg);
    else
    {
        Message res;
        auto condition = scheduler.newCondition();
        scheduler.start(
        {
            res = tid.mbox.put(msg);
            condition.notify();
        });
        condition.wait();

        return res;
    }
}


/*******************************************************************************

    Register of Tid's name

*******************************************************************************/

private
{
    ///
    __gshared Tid[string] tidByName;

    ////
    __gshared string[][Tid] namesByTid;
}


/*******************************************************************************



*******************************************************************************/

private @property Mutex registryLock ()
{
    __gshared Mutex impl;
    initOnce!impl(new Mutex);
    return impl;
}


/*******************************************************************************



*******************************************************************************/

private void unregisterMe ()
{
    auto me = thisInfo.ident;
    if (thisInfo.ident != Tid.init)
    {
        synchronized (registryLock)
        {
            if (auto allNames = me in namesByTid)
            {
                foreach (name; *allNames)
                    tidByName.remove(name);
                namesByTid.remove(me);
            }
        }
    }
}


/*******************************************************************************

    Associates name with tid.

    Associates name with tid in a process-local map.  When the thread
    represented by tid terminates, any names associated with it will be
    automatically unregistered.

    Params:
        name = The name to associate with tid.
        tid  = The tid register by name.

    Returns:
        true if the name is available and tid is not known to represent a
        defunct thread.

*******************************************************************************/

bool register (string name, Tid tid)
{
    synchronized (registryLock)
    {
        if (name in tidByName)
            return false;
        if (tid.mbox.isClosed)
            return false;
        namesByTid[tid] ~= name;
        tidByName[name] = tid;
        return true;
    }
}


/*******************************************************************************

    Removes the registered name associated with a tid.

    Params:
        name = The name to unregister.

    Returns:
        true if the name is registered, false if not.

*******************************************************************************/

bool unregister (string name)
{
    import std.algorithm.mutation : remove, SwapStrategy;
    import std.algorithm.searching : countUntil;

    synchronized (registryLock)
    {
        if (auto tid = name in tidByName)
        {
            auto allNames = *tid in namesByTid;
            auto pos = countUntil(*allNames, name);
            remove!(SwapStrategy.unstable)(*allNames, pos);
            tidByName.remove(name);
            return true;
        }
        return false;
    }
}

/*******************************************************************************

    Gets the Tid associated with name.

    Params:
        name = The name to locate within the registry.

    Returns:
        The associated Tid or Tid.init if name is not registered.

*******************************************************************************/

Tid locate (string name)
{
    synchronized (registryLock)
    {
        if (auto tid = name in tidByName)
            return *tid;
        return Tid.init;
    }
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

    /// 
    MonoTime create_time;

    ///
    this (Tid s, string m, string a)
    {
        this.sender = s;
        this.method = m;
        this.args = a;
        this.create_time = MonoTime.currTime;
    }
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


/*******************************************************************************

    Thrown on calls to `receiveOnly` if a message other than the type
    the receiving thread expected is sent.

 *******************************************************************************/

public class MessageMismatch : Exception
{
    public this (string msg = "Unexpected message type") @safe pure nothrow @nogc
    {
        super(msg);
    }
}

/*******************************************************************************

    Thrown on calls to `receive` if the thread that spawned the receiving
    thread has terminated and no more messages exist.

 *******************************************************************************/

public class OwnerTerminated : Exception
{
    public this (Tid t, string msg = "Owner terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    public Tid tid;
}


/*******************************************************************************

    Thrown if a linked thread has terminated.

 *******************************************************************************/

public class LinkTerminated : Exception
{
    public this (Tid t, string msg = "Link terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    public Tid tid;
}

/*******************************************************************************

    Thrown when a Tid is missing, e.g. when `ownerTid` doesn't
    find an owner thread.

 *******************************************************************************/

public class TidMissingException : Exception
{
    import std.exception : basicExceptionCtors;
    mixin basicExceptionCtors;
}

/*******************************************************************************


 *******************************************************************************/

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


/*******************************************************************************

    ThreadInfo

    Encapsulates all implementation-level data needed for scheduling.
    When defining a Scheduler, an instance of this struct must be associated
    with each logical thread.  It contains all implementation-level information
    needed by the internal API.

 *******************************************************************************/

struct ThreadInfo
{
    Tid ident;
    bool[Tid] links;
    Tid owner;

    /**
     * Gets a thread-local instance of ThreadInfo.
     *
     * Gets a thread-local instance of ThreadInfo, which should be used as the
     * default instance when info is requested for a thread not created by the
     * Scheduler.
     */
    static @property ref thisInfo() nothrow
    {
        static ThreadInfo val;
        return val;
    }

    /**
     * Cleans up this ThreadInfo.
     *
     * This must be called when a scheduled thread terminates.  It tears down
     * the messaging system for the thread and notifies interested parties of
     * the thread's termination.
     */
    void cleanup ()
    {
        if (ident.mbox !is null)
            ident.mbox.close();
        foreach (tid; links.keys)
            _send(MsgType.linkDead, tid, ident);
        if (owner != Tid.init)
            _send(MsgType.linkDead, owner, ident);
        unregisterMe(); // clean up registry entries
    }
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
    /**
     * Spawns the supplied op and starts the Scheduler.
     *
     * This is intended to be called at the start of the program to yield all
     * scheduling to the active Scheduler instance.  This is necessary for
     * schedulers that explicitly dispatch threads rather than simply relying
     * on the operating system to do so, and so start should always be called
     * within main() to begin normal program execution.
     *
     * Params:
     *  op = A wrapper for whatever the main thread would have done in the
     *       absence of a custom scheduler.  It will be automatically executed
     *       via a call to spawn by the Scheduler.
     */
    void start (void delegate() op);

    /**
     * Assigns a logical thread to execute the supplied op.
     *
     * This routine is called by spawn.  It is expected to instantiate a new
     * logical thread and run the supplied operation.  This thread must call
     * thisInfo.cleanup() when the thread terminates if the scheduled thread
     * is not a kernel thread--all kernel threads will have their ThreadInfo
     * cleaned up automatically by a thread-local destructor.
     *
     * Params:
     *  op = The function to execute.  This may be the actual function passed
     *       by the user to spawn itself, or may be a wrapper function.
     */
    void spawn (void delegate() op);

    /**
     * Yields execution to another logical thread.
     *
     * This routine is called at various points within concurrency-aware APIs
     * to provide a scheduler a chance to yield execution when using some sort
     * of cooperative multithreading model.  If this is not appropriate, such
     * as when each logical thread is backed by a dedicated kernel thread,
     * this routine may be a no-op.
     */
    void yield() nothrow;

    /**
     * Returns an appropriate ThreadInfo instance.
     *
     * Returns an instance of ThreadInfo specific to the logical thread that
     * is calling this routine or, if the calling thread was not create by
     * this scheduler, returns ThreadInfo.thisInfo instead.
     */
    @property ref ThreadInfo thisInfo () nothrow;

    /**
     * Creates a Condition variable analog for signaling.
     *
     * Creates a new Condition variable analog which is used to check for and
     * to signal the addition of messages to a thread's message queue.  Like
     * yield, some schedulers may need to define custom behavior so that calls
     * to Condition.wait() yield to another thread when no new messages are
     * available instead of blocking.
     *
     * Params:
     *  m = The Mutex that will be associated with this condition.  It will be
     *      locked prior to any operation on the condition, and so in some
     *      cases a Scheduler may need to hold this reference and unlock the
     *      mutex before yielding execution to another logical thread.
     */
    Condition newCondition (Mutex m = null) nothrow;
}

/*******************************************************************************

    FiberScheduler

    Scheduler using Fibers.

 *******************************************************************************/

public class FiberScheduler : Scheduler
{
    static class InfoFiber : Fiber
    {
        this (void delegate() op) nothrow
        {
            super(op, 16 * 1024 * 1024);  // 16Mb
        }
    }

    /**
     * This creates a new Fiber for the supplied op and then starts the
     * dispatcher.
     */
    void start (void delegate() op)
    {
        create(op);
        dispatch();
    }

    /**
     * This created a new Fiber for the supplied op and adds it to the
     * dispatch list.
     */
    void spawn (void delegate() op) nothrow
    {
        create(op);
        yield();
    }

    /**
     * If the caller is a scheduled Fiber, this yields execution to another
     * scheduled Fiber.
     */
    void yield () nothrow
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
    @property ref ThreadInfo thisInfo () nothrow
    {
        return ThreadInfo.thisInfo;
    }

    /**
     * Returns a Condition analog that yields when wait or notify is called.
     */
    Condition newCondition (Mutex m = null) nothrow
    {
        return new FiberCondition(m);
    }

private:
    class FiberCondition : Condition
    {
        this (Mutex m = null) nothrow
        {
            super(m);
            notified = false;
        }

        override void wait () nothrow
        {
            scope (exit) notified = false;

            while (!notified)
                this.outer.yield();
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
            this.outer.yield();
        }

        override void notifyAll () nothrow
        {
            notified = true;
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

    void create (void delegate() op) nothrow
    {
        void wrap()
        {
            op();
        }

        m_fibers ~= new InfoFiber(&wrap);
    }

private:
    Fiber[] m_fibers;
    size_t m_pos;
}

/**
 * Sets the Scheduler behavior within the program.
 *
 * This variable sets the Scheduler behavior within this program.  Typically,
 * when setting a Scheduler, scheduler.start() should be called in main.  This
 * routine will not return until program execution is complete.
 */
public Scheduler scheduler;

public void createScheduler () @safe
{
    if (scheduler is null)
        scheduler = new FiberScheduler();
}

/**
 * A Generator is a Fiber that periodically returns values of type T to the
 * caller via yield.  This is represented as an InputRange.
 */
class Generator(T) :
    Fiber, IsGenerator, InputRange!T
{
    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *
     * In:
     *  fn must not be null.
     */
    this (void function () fn)
    {
        super(fn);
        call();
    }

    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  fn must not be null.
     */
    this (void function () fn, size_t sz)
    {
        super(fn, sz);
        call();
    }

    /**
     * Initializes a generator object which is associated with a static
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  fn = The fiber function.
     *  sz = The stack size for this fiber.
     *  guardPageSize = size of the guard page to trap fiber's stack
     *                  overflows. Refer to $(REF Fiber, core,thread)'s
     *                  documentation for more details.
     *
     * In:
     *  fn must not be null.
     */
    this (void function () fn, size_t sz, size_t guardPageSize)
    {
        super(fn, sz, guardPageSize);
        call();
    }

    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *
     * In:
     *  dg must not be null.
     */
    this (void delegate () dg)
    {
        super(dg);
        call();
    }

    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  dg must not be null.
     */
    this (void delegate () dg, size_t sz)
    {
        super(dg, sz);
        call();
    }

    /**
     * Initializes a generator object which is associated with a dynamic
     * D function.  The function will be called once to prepare the range
     * for iteration.
     *
     * Params:
     *  dg = The fiber function.
     *  sz = The stack size for this fiber.
     *  guardPageSize = size of the guard page to trap fiber's stack
     *                  overflows. Refer to $(REF Fiber, core,thread)'s
     *                  documentation for more details.
     *
     * In:
     *  dg must not be null.
     */
    this (void delegate () dg, size_t sz, size_t guardPageSize)
    {
        super(dg, sz, guardPageSize);
        call();
    }

    /**
     * Returns true if the generator is empty.
     */
    final bool empty () @property
    {
        return m_value is null || state == State.TERM;
    }

    /**
     * Obtains the next value from the underlying function.
     */
    final void popFront ()
    {
        call();
    }

    /**
     * Returns the most recently generated value by shallow copy.
     */
    final T front () @property
    {
        return *m_value;
    }

    /**
     * Returns the most recently generated value without executing a
     * copy contructor. Will not compile for element types defining a
     * postblit, because Generator does not return by reference.
     */
    final T moveFront ()
    {
        static if (!hasElaborateCopyConstructor!T)
        {
            return front;
        }
        else
        {
            static assert(0,
            "Fiber front is always rvalue and thus cannot be moved since it defines a postblit.");
        }
    }

    final int opApply (scope int delegate(T) loopBody)
    {
        int broken;
        for (; !empty; popFront())
        {
            broken = loopBody(front);
            if (broken) break;
        }
        return broken;
    }

    final int opApply (scope int delegate(size_t, T) loopBody)
    {
        int broken;
        for (size_t i; !empty; ++i, popFront())
        {
            broken = loopBody(i, front);
            if (broken) break;
        }
        return broken;
    }
private:
    T* m_value;
}

private @property shared (Mutex) initOnceLock ()
{
    static shared Mutex lock;
    if (auto mtx = atomicLoad!(MemoryOrder.acq)(lock))
        return mtx;
    auto mtx = new shared Mutex;
    if (cas(&lock, cast(shared) null, mtx))
        return mtx;
    return atomicLoad!(MemoryOrder.acq)(lock);
}

/**
 * Initializes $(D_PARAM var) with the lazy $(D_PARAM init) value in a
 * thread-safe manner.
 *
 * The implementation guarantees that all threads simultaneously calling
 * initOnce with the same $(D_PARAM var) argument block until $(D_PARAM var) is
 * fully initialized. All side-effects of $(D_PARAM init) are globally visible
 * afterwards.
 *
 * Params:
 *   var = The variable to initialize
 *   init = The lazy initializer value
 *
 * Returns:
 *   A reference to the initialized variable
 */
auto ref initOnce (alias var)(lazy typeof(var) init)
{
    return initOnce!var(init, initOnceLock);
}

/**
 * Same as above, but takes a separate mutex instead of sharing one among
 * all initOnce instances.
 *
 * This should be used to avoid dead-locks when the $(D_PARAM init)
 * expression waits for the result of another thread that might also
 * call initOnce. Use with care.
 *
 * Params:
 *   var = The variable to initialize
 *   init = The lazy initializer value
 *   mutex = A mutex to prevent race conditions
 *
 * Returns:
 *   A reference to the initialized variable
 */
auto ref initOnce (alias var)(lazy typeof(var) init, shared Mutex mutex)
{
    // check that var is global, can't take address of a TLS variable
    static assert(is(typeof({ __gshared p = &var; })),
        "var must be 'static shared' or '__gshared'.");
    import core.atomic : atomicLoad, MemoryOrder, atomicStore;

    static shared bool flag;
    if (!atomicLoad!(MemoryOrder.acq)(flag))
    {
        synchronized (mutex)
        {
            if (!atomicLoad!(MemoryOrder.raw)(flag))
            {
                var = init;
                atomicStore!(MemoryOrder.rel)(flag, true);
            }
        }
    }
    return var;
}

/// ditto
auto ref initOnce (alias var)(lazy typeof(var) init, Mutex mutex)
{
    return initOnce!var(init, cast(shared) mutex);
}

static ~this ()
{
    thisInfo.cleanup();
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
                    "function with arguments " ~
                    a1.stringof ~ " occludes successive function");
            }
        }
    }
}

@property ref ThreadInfo thisInfo () nothrow
{
    if (scheduler is null)
        return ThreadInfo.thisInfo;
    return scheduler.thisInfo;
}
