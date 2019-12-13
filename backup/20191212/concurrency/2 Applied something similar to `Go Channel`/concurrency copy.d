/*******************************************************************************
    This is a low-level messaging API upon which more structured or restrictive
    APIs may be built.  The general idea is that every messageable entity is
    represented by a common handle type called a Tid, which allows messages to
    be sent to logical threads that are executing in both the current process
    and in external processes using the same interface.  This is an important
    aspect of scalability because it allows the components of a program to be
    spread across available resources with few to no changes to the actual
    implementation.

    A logical thread is an execution context that has its own stack and which
    runs asynchronously to other logical threads.  These may be preemptively
    scheduled kernel threads, fibers (cooperative user-space threads), or some
    other concept with similar behavior.

    he type of concurrency used when logical threads are created is determined
    by the Scheduler selected at initialization time.  The default behavior is
    currently to create a new kernel thread per call to spawn, but other
    schedulers are available that multiplex fibers across the main thread or
    use some combination of the two approaches.

    Note:
    Copied (almost verbatim) from Phobos at commit 3bfccf4f1 (2019-11-27)
    Changes are this notice, and the module rename, from `std.concurrency`
    to `geod24.concurrency`.

    Copyright: Copyright Sean Kelly 2009 - 2014.
    License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
    Authors:   Sean Kelly, Alex Rønne Petersen, Martin Nowak
    Source:    $(PHOBOSSRC std/concurrency.d)

    Copyright Sean Kelly 2009 - 2014.
    Distributed under the Boost Software License, Version 1.0.
    (See accompanying file LICENSE_1_0.txt or copy at
    http://www.boost.org/LICENSE_1_0.txt)

*******************************************************************************/

module geod24.concurrency;

public import std.variant;

import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.container;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.traits;

import std.stdio;
///
@system unittest
{
    __gshared string received;
    static void spawnedFunc (Tid ownerTid)
    {
        import std.conv : text;
        // Receive a message from the owner thread.
        receive((int i){
            received = text("Received the number ", i);

            // Send a message back to the owner thread
            // indicating success.
            send(ownerTid, true);
        });
    }

    // Start spawnedFunc in a new thread.
    auto childTid = spawn(&spawnedFunc, thisTid);

    // Send the number 42 to this new thread.
    send(childTid, 42);

    // Receive the result code.
    receive((bool wasSuccessful) {
        assert(wasSuccessful);
        assert(received == "Received the number 42");
    });
}

private
{
    bool hasLocalAliasing (Types...)()
    {
        import std.typecons : Rebindable;

        // Works around "statement is not reachable"
        bool doesIt = false;
        static foreach (T; Types)
        {
            static if (is(T == Tid))
            { /* Allowed */ }
            else static if (is(T : Rebindable!R, R))
                doesIt |= hasLocalAliasing!R;
            else static if (is(T == struct))
                doesIt |= hasLocalAliasing!(typeof(T.tupleof));
            else
                doesIt |= std.traits.hasUnsharedAliasing!(T);
        }
        return doesIt;
    }

    @safe unittest
    {
        static struct Container { Tid t; }
        static assert(!hasLocalAliasing!(Tid, Container, int));
    }

    @safe unittest
    {
        /* Issue 20097 */
        import std.datetime.systime : SysTime;
        static struct Container { SysTime time; }
        static assert(!hasLocalAliasing!(SysTime, Container));
    }

    enum MsgType
    {
        standard,
        linkDead,
    }

    struct Message
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

    void checkops (T...) (T ops)
    {
        import std.format : format;

        foreach (i, t1; T)
        {
            static assert(isFunctionPointer!t1 || isDelegate!t1,
                    format!"T %d is not a function pointer or delegates"(i));
            alias a1 = Parameters!(t1);
            alias r1 = ReturnType!(t1);

            static if (i < T.length - 1 && is(r1 == void))
            {
                static assert(a1.length != 1 || !is(a1[0] == Variant),
                              "function with arguments " ~ a1.stringof ~
                              " occludes successive function");

                foreach (t2; T[i + 1 .. $])
                {
                    alias a2 = Parameters!(t2);

                    static assert(!is(a1 == a2),
                        "function with arguments " ~ a1.stringof ~ " occludes successive function");
                }
            }
        }
    }

    @property ref ThreadInfo thisInfo () nothrow
    {
        return ThreadInfo.thisInfo;
    }
}

static this ()
{
    if (thread_scheduler is null)
        thread_scheduler = new ThreadScheduler();
}

static ~this ()
{
    thisInfo.cleanup();
}

// Exceptions

/// Thrown on calls to `receiveOnly` if a message other than the type
/// the receiving thread expected is sent.
class MessageMismatch : Exception
{
    /// Ctor
    this (string msg = "Unexpected message type") @safe pure nothrow @nogc
    {
        super(msg);
    }
}

/// Thrown on calls to `receive` if the thread that spawned the receiving
/// thread has terminated and no more messages exist.
class OwnerTerminated : Exception
{
    /// Ctor
    this (Tid t, string msg = "Owner terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    Tid tid;
}

/// Thrown if a linked thread has terminated.
class LinkTerminated : Exception
{
    /// Ctor
    this (Tid t, string msg = "Link terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    Tid tid;
}

/// Thrown when a Tid is missing, e.g. when `ownerTid` doesn't
/// find an owner thread.
class TidMissingException : Exception
{
    import std.exception : basicExceptionCtors;
    ///
    mixin basicExceptionCtors;
}


// Thread ID

/// An opaque type used to represent a logical thread.
struct Tid
{
    /// This is where the messages received are stored.
    public MessageBox mbox;
    /// Timeout time
    public Duration timeout;
    /// Set at the end to indicate that no further work can be done.
    public bool shutdown;

    private this (MessageBox m) @safe pure nothrow @nogc
    {
        mbox = m;
        timeout = Duration.init;
        shutdown = false;
    }

    /***************************************************************************

        Set the timeout time.

    ***************************************************************************/

    public void setTimeout (Duration d) @safe pure nothrow @nogc
    {
        this.timeout = d;
        mbox.setTimeout(d);
    }

    /***************************************************************************

        Generate a convenient string for identifying this MessageDispatcher.
        This is only useful to see if MessageDispatcher's that are currently
        executing are the same or different,
        e.g. for logging and debugging.  It is potentially possible
        that a Tid executed in the future will have the same toString() output
        as another Tid that has already terminated.

    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "Tid(%x)", cast(void*) mbox);
    }

    /***************************************************************************

        Clear the contents of the message.

    ***************************************************************************/

    public void cleanup ()
    {
        if (mbox !is null)
            mbox.close();
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

/// Returns: The $(LREF Tid) of the caller's thread.
@property Tid thisTid () @safe
{
    // TODO: remove when concurrency is safe
    static auto trus () @trusted
    {
        if (thisInfo.ident != Tid.init)
            return thisInfo.ident;
        thisInfo.ident = Tid(new MessageBox);
        thisInfo.scheduler = new MainScheduler();
        thisInfo.have_scheduler = true;
        return thisInfo.ident;
    }

    return trus();
}

/// Returns: The $(LREF Tid) of the caller's thread.
@property Scheduler thisScheduler () @safe
{
    // TODO: remove when concurrency is safe
    static auto trus () @trusted
    {
        if (thisInfo.scheduler !is null)
            return thisInfo.scheduler;
        if (thisInfo.ident == Tid.init)
            thisInfo.ident = Tid(new MessageBox);
        thisInfo.scheduler = new MainScheduler();
        thisInfo.have_scheduler = true;
        return thisInfo.scheduler;
    }

    return trus();
}

/*******************************************************************************

    Throws a `TidMissingException` exception if there is no owner thread.

    Returns:
        Return the Tid of the thread which spawned the caller's thread.

*******************************************************************************/

@property Tid ownerTid ()
{
    import std.exception : enforce;

    enforce!TidMissingException(thisInfo.owner.mbox !is null, "Error: Thread has no owner thread.");
    return thisInfo.owner;
}

@system unittest
{
    import std.exception : assertThrown;

    static void fun ()
    {
        receive((string res) {
            assert(res == "Main calling");
            ownerTid.send("Child responding");
        });
    }

    assertThrown!TidMissingException(ownerTid);
    auto child = spawn(&fun);
    child.send("Main calling");

    receive((string res) {
        assert(res == "Child responding");
    });
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

/*******************************************************************************

    Starts fn(args) in a new logical thread.

    Executes the supplied function in a new logical thread represented by
    `Tid`.  The calling thread is designated as the owner of the new thread.
    When the owner thread terminates an `OwnerTerminated` message will be
    sent to the new thread, causing an `OwnerTerminated` exception to be
    thrown on `receive()`.

    Params:
        fn   = The function to execute.
        args = Arguments to the function.

    Returns:
        A Tid representing the new logical thread.

    Notes:
        `args` must not have unshared aliasing.  In other words, all arguments
        to `fn` must either be `shared` or `immutable` or have no
        pointer indirection.  This is necessary for enforcing isolation among
        threads.

*******************************************************************************/

public Tid spawn (F, T...) (F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    return _spawn(false, fn, args);
}

public Tid spawnThread (F, T...) (F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    return _spawn(false, fn, args);
}

///
@system unittest
{
    static void f (string msg)
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

/// New thread with anonymous function
@system unittest
{
    spawn({
        ownerTid.send("This is so great!");
    });

    receive((string res) {
        assert(res == "This is so great!");
    });
}

@system unittest
{
    import core.thread : thread_joinAll;

    __gshared string receivedMessage;
    static void f1(string msg)
    {
        receivedMessage = msg;
    }

    auto tid1 = spawn(&f1, "Hello World");
    Thread.sleep(1000.msecs);
    assert(receivedMessage == "Hello World");
}

/*******************************************************************************

    Starts fn(args) in a logical thread and will receive a LinkTerminated
    message when the operation terminates.

    Executes the supplied function in a new logical thread represented by
    Tid.  This new thread is linked to the calling thread so that if either
    it or the calling thread terminates a LinkTerminated message will be sent
    to the other, causing a LinkTerminated exception to be thrown on receive().
    The owner relationship from spawn() is preserved as well, so if the link
    between threads is broken, owner termination will still result in an
    OwnerTerminated exception to be thrown on receive().

    Params:
        fn   = The function to execute.
        args = Arguments to the function.

    Returns:
        A Tid representing the new thread.

*******************************************************************************/

public Tid spawnLinked (F, T...) (F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T),
        "Aliases to mutable thread-local data not allowed.");
    return _spawn(true, fn, args);
}

/*******************************************************************************

    Starts fn(args) in a logical thread and will receive a LinkTerminated
    message when the operation terminates.

    Executes the supplied function in a new logical thread represented by
    Tid.  This new thread is linked to the calling thread so that if either
    it or the calling thread terminates a LinkTerminated message will be sent
    to the other, causing a LinkTerminated exception to be thrown on receive().
    The owner relationship from spawn() is preserved as well, so if the link
    between threads is broken, owner termination will still result in an
    OwnerTerminated exception to be thrown on receive().

    Params:
        linked  = If connected to the called thread then true or false.
        fn      = The function to execute.
        args    = Arguments to the function.

    Returns:
        A Tid representing the new thread.

*******************************************************************************/

private Tid _spawn (F, T...) (bool linked, F fn, T args)
if (isSpawnable!(F, T))
{
    auto spawn_tid = Tid(new MessageBox);
    auto owner_tid = thisTid;
    auto spawn_scheduler = new NodeScheduler();

    void execInThread ()
    {
        thisInfo.ident = spawn_tid;
        thisInfo.owner = owner_tid;
        thisInfo.scheduler = spawn_scheduler;
        thisInfo.have_scheduler = true;
        thisInfo.is_inherited = false;

        thisInfo.scheduler.start({
            thisInfo.ident = spawn_tid;
            thisInfo.owner = owner_tid;
            thisInfo.scheduler = spawn_scheduler;
            thisInfo.have_scheduler = false;
            thisInfo.is_inherited = true;
            fn(args);
        });
    }

    thread_scheduler.spawn(&execInThread);

    return spawn_tid;
}

public Tid spawnFiber (void delegate () op)
{
    auto spawn_tid = Tid(new MessageBox);
    auto owner_tid = thisTid;
    auto owner_scheduler = thisScheduler;

    thisScheduler.spawn(
    {
        thisInfo.ident = spawn_tid;
        thisInfo.owner = owner_tid;
        thisInfo.scheduler = owner_scheduler;
        thisInfo.have_scheduler = false;
        thisInfo.is_inherited = false;
        op();
    });

    return spawn_tid;
}

public Tid spawnInheritedFiber (void delegate () op)
{
    auto spawn_tid = thisTid;
    auto owner_tid = thisInfo.owner;
    auto owner_scheduler = thisScheduler;

    thisScheduler.spawn(
    {
        thisInfo.ident = spawn_tid;
        thisInfo.owner = owner_tid;
        thisInfo.scheduler = owner_scheduler;
        thisInfo.have_scheduler = false;
        thisInfo.is_inherited = false;
        op();
    });

    return spawn_tid;
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

void send (T...) (Tid tid, T vals)
{
    static assert(!hasLocalAliasing!(T),
        "Aliases to mutable thread-local data not allowed.");
    _send(tid, vals);
}

/// Ditto
private void _send (T...) (Tid tid, T vals)
{
    _send(MsgType.standard, tid, vals);
}

/*******************************************************************************

    Implementation of send.  This allows parameter checking to be different for
    both Tid.send() and .send().

*******************************************************************************/

private void _send (T...) (MsgType type, Tid tid, T vals)
{
    auto msg = Message(type, vals);
    if (Fiber.getThis())
        tid.mbox.put(msg);
    else
        spawnInheritedFiber(
        {
            tid.mbox.put(msg);
        });
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

void receive (T...) (T ops)
in
{
    assert(thisInfo.ident.mbox !is null,
           "Cannot receive a message until a thread was spawned "
           ~ "or thisTid was passed to a running thread.");
}
do
{
    checkops(ops);


    if (Fiber.getThis())
        thisInfo.ident.mbox.get(ops);
    else
    {
        auto cond = thisScheduler.newCondition(null);
        spawnInheritedFiber(
        {
            thisInfo.ident.mbox.get(ops);
            cond.notify();
        });
        cond.wait();
    }
}

///
@system unittest
{
    import std.variant : Variant;

    auto process = ()
    {
        receive(
            (int i)
            {
                ownerTid.send(1);
            },
            (double f)
            {
                ownerTid.send(2);
            },
            (Variant v)
            {
                ownerTid.send(3);
            }
        );
    };

    {
        auto tid = spawn(process);
        send(tid, 42);

        receive((int res) {
            assert(res == 1);
        });
    }

    {
        auto tid = spawn(process);
        send(tid, 3.14);

        receive((int res) {
            assert(res == 2);
        });
    }

    {
        auto tid = spawn(process);
        send(tid, "something else");

        receive((int res) {
            assert(res == 3);
        });
    }
}

@safe unittest
{
    static assert( __traits( compiles,
                      {
                          receive( (Variant x) {} );
                          receive( (int x) {}, (Variant x) {} );
                      } ) );

    static assert( !__traits( compiles,
                       {
                           receive( (Variant x) {}, (int x) {} );
                       } ) );

    static assert( !__traits( compiles,
                       {
                           receive( (int x) {}, (int x) {} );
                       } ) );
}

// Make sure receive() works with free functions as well.
version (unittest)
{
    private void receiveFunction(int x) {}
}
@safe unittest
{
    static assert( __traits( compiles,
                      {
                          receive( &receiveFunction );
                          receive( &receiveFunction, (Variant x) {} );
                      } ) );
}

/*******************************************************************************

    Tries to receive but will give up if no matches arrive within duration.
    Won't wait at all if provided $(REF Duration, core,time) is negative.

    Same as `receive` except that rather than wait forever for a message,
    it waits until either it receives a message or the given
    $(REF Duration, core,time) has passed. It returns `true` if it received a
    message and `false` if it timed out waiting for one.

 ******************************************************************************/

bool receiveTimeout (T...) (Duration duration, T ops)
in
{
    assert(thisInfo.ident.mbox !is null,
        "Cannot receive a message until a thread was spawned or thisTid was passed to a running thread.");
}
do
{
    checkops(ops);

    if (Fiber.getThis())
        return thisInfo.ident.mbox.get(duration, ops);
    else
    {
        bool res;
        auto cond = thisScheduler.newCondition(null);
        spawnInheritedFiber(
        {
            res = thisInfo.ident.mbox.get(duration, ops);
            cond.notify();
        });
        cond.wait();
        return res;
    }
}

@safe unittest
{
    static assert(__traits(compiles, {
        receiveTimeout(msecs(0), (Variant x) {});
        receiveTimeout(msecs(0), (int x) {}, (Variant x) {});
    }));

    static assert(!__traits(compiles, {
        receiveTimeout(msecs(0), (Variant x) {}, (int x) {});
    }));

    static assert(!__traits(compiles, {
        receiveTimeout(msecs(0), (int x) {}, (int x) {});
    }));

    static assert(__traits(compiles, {
        receiveTimeout(msecs(10), (int x) {}, (Variant x) {});
    }));
}

/*******************************************************************************

    Encapsulates all implementation-level data needed for scheduling.

    When defining a Scheduler, an instance of this struct must be associated
    with each logical thread.  It contains all implementation-level information
    needed by the internal API.

*******************************************************************************/

public struct ThreadInfo
{
    /// Tid of a currend thread(fiber).
    public Tid ident;

    public bool[Tid] links;

    /// Tid of a thread that generated the current thread(fiber).
    public Tid owner;

    /// Manages fiber's work schedule inside current thread.
    public Scheduler scheduler;

    /// Whether the scheduler has ownership or not
    public bool have_scheduler;

    /// Whether to clone ThreadInfo in a higher layer
    public bool is_inherited;

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
        if (this.ident == Tid.init)
            return;

        if (!this.is_inherited)
        {
            if (this.owner != Tid.init)
                _send(this.owner, MsgType.linkDead, this.ident);

            if ((this.scheduler !is null) && this.have_scheduler)
            {
                this.scheduler.stop({
                    if (this.ident != Tid.init)
                        this.ident.cleanup();
                });
            }
            else
            {
                if (this.ident != Tid.init)
                    this.ident.cleanup();
            }
        }
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

    void stop (void delegate () op);

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

        This calls at the end of the program and commands the scheduler to end.

    ***************************************************************************/

    public void stop (void delegate () op)
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
}


/*******************************************************************************

    A Fiber using FiberScheduler.

*******************************************************************************/

private static class InfoFiber : Fiber
{
    public ThreadInfo info;

    public this (void delegate () op) nothrow
    {
        super(op);
    }
}


/*******************************************************************************

    A Condition using FiberScheduler.

*******************************************************************************/

private class FiberCondition : Condition
{
    /// Owner
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

class FiberScheduler : Scheduler
{
    protected Fiber[] m_fibers;
    protected size_t m_pos;

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

        This calls at the end of the program and commands the scheduler to end.

    ***************************************************************************/

    public void stop (void delegate () op)
    {

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
        return new FiberCondition(m, this);
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

    /***************************************************************************

        Create a new fiber and add it to the array.

    ***************************************************************************/

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

    A Node-Thread's Scheduler using Fibers.

*******************************************************************************/

public class NodeScheduler : FiberScheduler
{
    private shared(bool) terminated;
    private shared(MonoTime) terminated_time;
    private shared(bool) stoped;
    private Mutex m;
    private Duration sleep_interval;

    /// Ctor
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

    override public void stop (void delegate () op)
    {
        terminated = true;
        terminated_time = MonoTime.currTime;
        while (!this.stoped)
            sleepThread(100.msecs);
        op();
    }


    /***************************************************************************

        Manages fiber's work schedule.

    ***************************************************************************/

    override protected void dispatch ()
    {
        import std.algorithm.mutation : remove;
        bool done = terminated && (m_fibers.length == 0);
        Duration limit = 3000.msecs;

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
                if (elapsed > limit)
                    done = true;
            }
            m.unlock();
            sleepThread(this.sleep_interval);
        }
        this.stoped = true;
    }


    /***************************************************************************

        Create a new fiber and add it to the array.

    ***************************************************************************/

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

    A Main-Thread's Scheduler using Fibers.

*******************************************************************************/

public class MainScheduler : FiberScheduler
{
    private shared(bool) terminated;
    private shared(MonoTime) terminated_time;
    private shared(bool) stoped;
    private Mutex m;
    private Duration sleep_interval;

    /// Ctor
    public this ()
    {
        this.sleep_interval = 1.msecs;
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

    override public void stop (void delegate () op)
    {
        terminated = true;
        terminated_time = MonoTime.currTime;
        while (!this.stoped)
            sleepThread(100.msecs);
        op();
    }


    /***************************************************************************

        Manages fiber's work schedule.

    ***************************************************************************/

    override protected void dispatch ()
    {
        import std.algorithm.mutation : remove;
        bool done = terminated && (m_fibers.length == 0);
        Duration limit = 3000.msecs;

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
                if (elapsed > limit)
                    done = true;
            }
            m.unlock();
            sleepThread(this.sleep_interval);
        }
        this.stoped = true;
    }


    /***************************************************************************

        Create a new fiber and add it to the array.

    ***************************************************************************/

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

@system unittest
{
    static void receive (Condition cond, ref size_t received)
    {
        while (true)
        {
            synchronized (cond.mutex)
            {
                cond.wait();
                ++received;
            }
        }
    }

    static void send (Condition cond, ref size_t sent)
    {
        while (true)
        {
            synchronized (cond.mutex)
            {
                ++sent;
                cond.notify();
            }
        }
    }

    auto fs = new FiberScheduler;
    auto mtx = new Mutex;
    auto cond = fs.newCondition(mtx);

    size_t received, sent;
    auto waiter = new Fiber({ receive(cond, received); }), notifier = new Fiber({ send(cond, sent); });
    waiter.call();
    assert(received == 0);
    notifier.call();
    assert(sent == 1);
    assert(received == 0);
    waiter.call();
    assert(received == 1);
    waiter.call();
    assert(received == 1);
}

/// The thread scheduler behavior within the program.
__gshared ThreadScheduler thread_scheduler;

void yield ()
{
    thisScheduler.yield();
}

void yieldAndSleep ()
{
    thisScheduler.yield();
    Thread.sleep(1.msecs);
}

void sleepThread (Duration val)
{
    Thread.sleep(val);
}

/*******************************************************************************

    A MessageBox is a message queue for one thread.  Other threads may send
    messages to this owner by calling put(), and the owner receives them by
    calling get().  The put() call is therefore effectively shared and the
    get() call is effectively local.

*******************************************************************************/

private class MessageBox
{
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

                    yieldAndSleep();
                }
            }
            else
            {
                while (is_waiting)
                    yieldAndSleep();
            }
        }

        return true;
    }

    private enum ResultGetMessage
    {
        close,
        success,
        yet
    }

    /***************************************************************************

        Get a message from the queue.

        Params:
            msg = The message to get in the queue.

        Returns:
            ResultGetMessage.close : When MessageBox is already closed
            ResultGetMessage.success : When the data was received
            ResultGetMessage.yet : When the data was not received

    ***************************************************************************/

    private ResultGetMessage getMessage (Message* msg)
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();
            return ResultGetMessage.close;
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

            return ResultGetMessage.success;
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

            ResultGetMessage res = ResultGetMessage.success;
            Duration interval;
            if (this.timed_wait)
                interval = this.timed_wait_period;
            else
                interval = 1.msecs;

            while (is_waiting1)
            {
                auto elapsed = MonoTime.currTime - new_sf.create_time;
                if (elapsed > interval)
                {
                    res = ResultGetMessage.yet;
                    is_waiting1 = true;
                    break;
                }
                yieldAndSleep();
            }

            if (this.timed_wait)
            {
                this.waitFromBase(new_sf.create_time, this.timed_wait_period);
                this.timed_wait = false;
            }

            return res;
        }
    }

    /***********************************************************************

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

    ***********************************************************************/

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

            yieldAndSleep();

            auto res = this.getMessage(&msg);
            if (res == ResultGetMessage.close)
                return false;

            if (res == ResultGetMessage.yet)
                continue;

            arrived.put(msg);
            if (scan(arrived))
            {
                this.localBox.put(arrived);
                return true;
            }
            else
            {
                this.localBox.put(arrived);
                continue;
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
                yieldAndSleep();
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

        assert(m_count, "Can not remove from empty Range");
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


unittest
{
    import std.concurrency;

    auto process = ()
    {
        size_t message_count = 2;
        while (message_count--)
        {
            receive(
                (int i)
                {
                    ownerTid.send(i);
                },
                (string s)
                {
                    ownerTid.send(s);
                }
            );
        }
    };

    auto spawnedTid = spawnThread(process);
    spawnedTid.send(42);
    spawnedTid.send("string");

    int got_i;
    string got_s;

    receive(
        (string s)
        {
            got_s = s;
        }
    );

    receive(
        (int i)
        {
            got_i = i;
        }
    );

    assert(got_i == 42);
    assert(got_s == "string");
}
