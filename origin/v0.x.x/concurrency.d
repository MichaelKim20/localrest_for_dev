/**
 * This is a low-level messaging API upon which more structured or restrictive
 * APIs may be built.  The general idea is that every messageable entity is
 * represented by a common handle type called a Tid, which allows messages to
 * be sent to logical threads that are executing in both the current process
 * and in external processes using the same interface.  This is an important
 * aspect of scalability because it allows the components of a program to be
 * spread across available resources with few to no changes to the actual
 * implementation.
 *
 * A logical thread is an execution context that has its own stack and which
 * runs asynchronously to other logical threads.  These may be preemptively
 * scheduled kernel threads, fibers (cooperative user-space threads), or some
 * other concept with similar behavior.
 *
 * The type of concurrency used when logical threads are created is determined
 * by the Scheduler selected at initialization time.  The default behavior is
 * currently to create a new kernel thread per call to spawn, but other
 * schedulers are available that multiplex fibers across the main thread or
 * use some combination of the two approaches.
 *
 * Note:
 * Copied (almost verbatim) from Phobos at commit 3bfccf4f1 (2019-11-27)
 * Changes are this notice, and the module rename, from `std.concurrency`
 * to `geod24.concurrency`.
 *
 * Copyright: Copyright Sean Kelly 2009 - 2014.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Sean Kelly, Alex Rønne Petersen, Martin Nowak
 * Source:    $(PHOBOSSRC std/concurrency.d)
 */
/*          Copyright Sean Kelly 2009 - 2014.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module geod24.concurrency;

public import std.variant;

import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.traits;

///
@system unittest
{
    __gshared string received;
    static void spawnedFunc(Tid self, Tid ownerTid)
    {
        import std.conv : text;
        // Receive a message from the owner thread.
        self.receive((int i){
            received = text("Received the number ", i);

            // Send a message back to the owner thread
            // indicating success.
            send(ownerTid, true);
        });
    }

    // Start spawnedFunc in a new thread.
    auto childTid = spawn(&spawnedFunc, thisTid);
    auto self = thisTid();

    // Send the number 42 to this new thread.
    send(childTid, 42);

    // Receive the result code.
    auto wasSuccessful = self.receiveOnly!(bool);
    assert(wasSuccessful);
    assert(received == "Received the number 42");
}

private
{
    bool hasLocalAliasing(Types...)()
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
        priority,
        linkDead,
    }

    struct Message
    {
        MsgType type;
        Variant data;

        this(T...)(MsgType t, T vals) if (T.length > 0)
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
        }

        @property auto convertsTo(T...)()
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

        @property auto get(T...)()
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

        auto map(Op)(Op op)
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

    void checkops(T...)(T ops)
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

    @property ref ThreadInfo thisInfo() nothrow
    {
        return ThreadInfo.thisInfo;
    }
}

static ~this()
{
    thisInfo.cleanup();
}

// Exceptions

/**
 * Thrown on calls to `receiveOnly` if a message other than the type
 * the receiving thread expected is sent.
 */
class MessageMismatch : Exception
{
    ///
    this(string msg = "Unexpected message type") @safe pure nothrow @nogc
    {
        super(msg);
    }
}

/**
 * Thrown on calls to `receive` if the thread that spawned the receiving
 * thread has terminated and no more messages exist.
 */
class OwnerTerminated : Exception
{
    ///
    this(Tid t, string msg = "Owner terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    Tid tid;
}

/**
 * Thrown if a linked thread has terminated.
 */
class LinkTerminated : Exception
{
    ///
    this(Tid t, string msg = "Link terminated") @safe pure nothrow @nogc
    {
        super(msg);
        tid = t;
    }

    Tid tid;
}

/**
 * Thrown if a message was sent to a thread via
 * $(REF prioritySend, std,concurrency) and the receiver does not have a handler
 * for a message of this type.
 */
class PriorityMessageException : Exception
{
    ///
    this(Variant vals)
    {
        super("Priority message");
        message = vals;
    }

    /**
     * The message that was sent.
     */
    Variant message;
}

/**
 * Thrown when a Tid is missing, e.g. when `ownerTid` doesn't
 * find an owner thread.
 */
class TidMissingException : Exception
{
    import std.exception : basicExceptionCtors;
    ///
    mixin basicExceptionCtors;
}


// Thread ID


/**
 * An opaque type used to represent a logical thread.
 */
struct Tid
{
package:
    this(MessageBox m) @safe pure nothrow @nogc
    {
        mbox = m;
    }

    MessageBox mbox;

public:

    /**
     * Generate a convenient string for identifying this Tid.  This is only
     * useful to see if Tid's that are currently executing are the same or
     * different, e.g. for logging and debugging.  It is potentially possible
     * that a Tid executed in the future will have the same toString() output
     * as another Tid that has already terminated.
     */
    void toString(scope void delegate(const(char)[]) sink)
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

/**
 * Returns: The $(LREF Tid) of the caller's thread.
 */
@property Tid thisTid() @safe
{
    // TODO: remove when concurrency is safe
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

@system unittest
{
    import std.exception : assertThrown;

    static void fun(Tid self)
    {
        string res = self.receiveOnly!string();
        assert(res == "Main calling");
        ownerTid.send("Child responding");
    }

    assertThrown!TidMissingException(ownerTid);
    auto self = thisTid();
    auto child = spawn(&fun);
    child.send("Main calling");
    string res = self.receiveOnly!string();
    assert(res == "Child responding");
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
            && isParamsImplicitlyConvertible!(F, void function(Tid, T))
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
Tid spawn(F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    return _spawn(fn, args);
}

///
@system unittest
{
    static void f(Tid self, string msg)
    {
        assert(msg == "Hello World");
    }

    auto tid = spawn(&f, "Hello World");
}

/// Fails: char[] has mutable aliasing.
@system unittest
{
    string msg = "Hello, World!";

    static void f1(Tid self, string msg) {}
    static assert(!__traits(compiles, spawn(&f1, msg.dup)));
    static assert( __traits(compiles, spawn(&f1, msg.idup)));

    static void f2(Tid self, char[] msg) {}
    static assert(!__traits(compiles, spawn(&f2, msg.dup)));
    static assert(!__traits(compiles, spawn(&f2, msg.idup)));
}

/// New thread with anonymous function
@system unittest
{
    auto self = thisTid();
    spawn((Tid self) {
        ownerTid.send("This is so great!");
    });
    assert(self.receiveOnly!string == "This is so great!");
}

/*
 *
 */
private Tid _spawn(F, T...)(F fn, T args)
if (isSpawnable!(F, T))
{
    // TODO: MessageList and &exec should be shared.
    auto spawnTid = Tid(new MessageBox);
    auto ownerTid = thisTid;

    void exec()
    {
        thisInfo.ident = spawnTid;
        thisInfo.owner = ownerTid;
        fn(spawnTid, args);
    }

    // TODO: MessageList and &exec should be shared.
    auto t = new Thread(&exec);
    t.start();
    return spawnTid;
}

@system unittest
{
    void function(Tid) fn1;
    void function(Tid, int) fn2;
    static assert(__traits(compiles, spawn(fn1)));
    static assert(__traits(compiles, spawn(fn2, 2)));
    static assert(!__traits(compiles, spawn(fn1, 1)));
    static assert(!__traits(compiles, spawn(fn2)));

    void delegate(Tid, int) shared dg1;
    shared(void delegate(Tid, int)) dg2;
    shared(void delegate(Tid, long) shared) dg3;
    shared(void delegate(Tid, real, int, long) shared) dg4;
    void delegate(Tid, int) immutable dg5;
    void delegate(Tid, int) dg6;
    static assert(__traits(compiles, spawn(dg1, 1)));
    static assert(__traits(compiles, spawn(dg2, 2)));
    static assert(__traits(compiles, spawn(dg3, 3)));
    static assert(__traits(compiles, spawn(dg4, 4, 4, 4)));
    static assert(__traits(compiles, spawn(dg5, 5)));
    static assert(!__traits(compiles, spawn(dg6, 6)));

    auto callable1  = new class{ void opCall(Tid, int) shared {} };
    auto callable2  = cast(shared) new class{ void opCall(Tid, int) shared {} };
    auto callable3  = new class{ void opCall(Tid, int) immutable {} };
    auto callable4  = cast(immutable) new class{ void opCall(Tid, int) immutable {} };
    auto callable5  = new class{ void opCall(Tid, int) {} };
    auto callable6  = cast(shared) new class{ void opCall(Tid, int) immutable {} };
    auto callable7  = cast(immutable) new class{ void opCall(Tid, int) shared {} };
    auto callable8  = cast(shared) new class{ void opCall(Tid, int) const shared {} };
    auto callable9  = cast(const shared) new class{ void opCall(Tid, int) shared {} };
    auto callable10 = cast(const shared) new class{ void opCall(Tid, int) const shared {} };
    auto callable11 = cast(immutable) new class{ void opCall(Tid, int) const shared {} };
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

/**
 * Places the values as a message at the back of tid's message queue.
 *
 * Sends the supplied value to the thread represented by tid.  As with
 * $(REF spawn, std,concurrency), `T` must not have unshared aliasing.
 */
void send(T...)(Tid tid, T vals)
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    _send(MsgType.standard, tid, vals);
}

/**
 * Places the values as a message on the front of tid's message queue.
 *
 * Send a message to `tid` but place it at the front of `tid`'s message
 * queue instead of at the back.  This function is typically used for
 * out-of-band communication, to signal exceptional conditions, etc.
 */
void prioritySend(T...)(Tid tid, T vals)
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");
    _send(MsgType.priority, tid, vals);
}

/*
 * Implementation of send.  This allows parameter checking to be different for
 * both Tid.send() and .send().
 */
private void _send(T...)(MsgType type, Tid tid, T vals)
{
    auto msg = Message(type, vals);
    tid.mbox.put(msg);
}

/**
 * Receives a message from another thread.
 *
 * Receive a message from another thread, or block if no messages of the
 * specified types are available.  This function works by pattern matching
 * a message against a set of delegates and executing the first match found.
 *
 * If a delegate that accepts a $(REF Variant, std,variant) is included as
 * the last argument to `receive`, it will match any message that was not
 * matched by an earlier delegate.  If more than one argument is sent,
 * the `Variant` will contain a $(REF Tuple, std,typecons) of all values
 * sent.
 */
void receive(T...)(Tid self, T ops )
in
{
    assert(self.mbox !is null,
           "Cannot receive a message until a thread was spawned "
           ~ "or thisTid was passed to a running thread.");
}
do
{
    checkops( ops );
    self.mbox.get( ops );
}

///
@system unittest
{
    import std.variant : Variant;

    auto process = (Tid self)
    {
        self.receive(
            (int i) { ownerTid.send(1); },
            (double f) { ownerTid.send(2); },
            (Variant v) { ownerTid.send(3); }
        );
    };

    auto self = thisTid();
    {
        auto tid = spawn(process);
        send(tid, 42);
        assert(self.receiveOnly!int == 1);
    }

    {
        auto tid = spawn(process);
        send(tid, 3.14);
        assert(self.receiveOnly!int == 2);
    }

    {
        auto tid = spawn(process);
        send(tid, "something else");
        assert(self.receiveOnly!int == 3);
    }
}

@safe unittest
{
    static assert( __traits( compiles,
                      {
                          receive(Tid.init, (Variant x) {} );
                          receive(Tid.init, (int x) {}, (Variant x) {} );
                      } ) );

    static assert( !__traits( compiles,
                       {
                           receive(Tid.init, (Variant x) {}, (int x) {} );
                       } ) );

    static assert( !__traits( compiles,
                       {
                           receive(Tid.init, (int x) {}, (int x) {} );
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
                          receive(Tid.init, &receiveFunction );
                          receive(Tid.init, &receiveFunction, (Variant x) {} );
                      } ) );
}


private template receiveOnlyRet(T...)
{
    static if ( T.length == 1 )
    {
        alias receiveOnlyRet = T[0];
    }
    else
    {
        import std.typecons : Tuple;
        alias receiveOnlyRet = Tuple!(T);
    }
}

/**
 * Receives only messages with arguments of types `T`.
 *
 * Throws:  `MessageMismatch` if a message of types other than `T`
 *          is received.
 *
 * Returns: The received message.  If `T.length` is greater than one,
 *          the message will be packed into a $(REF Tuple, std,typecons).
 */
receiveOnlyRet!(T) receiveOnly(T...)(Tid self)
in
{
    assert(self.mbox !is null,
        "Cannot receive a message until a thread was spawned or thisTid was passed to a running thread.");
}
do
{
    import std.format : format;
    import std.typecons : Tuple;

    Tuple!(T) ret;

    self.mbox.get((T val) {
        static if (T.length)
            ret.field = val;
    },
    (LinkTerminated e) { throw e; },
    (OwnerTerminated e) { throw e; },
    (Variant val) {
        static if (T.length > 1)
            string exp = T.stringof;
        else
            string exp = T[0].stringof;

        throw new MessageMismatch(
            format("Unexpected message type: expected '%s', got '%s'", exp, val.type.toString()));
    });
    static if (T.length == 1)
        return ret[0];
    else
        return ret;
}

///
@system unittest
{
    auto tid = spawn(
    (Tid self) {
        assert(self.receiveOnly!int == 42);
    });
    send(tid, 42);
}

///
@system unittest
{
    auto tid = spawn(
    (Tid self) {
        assert(self.receiveOnly!string == "text");
    });
    send(tid, "text");
}

///
@system unittest
{
    struct Record { string name; int age; }

    auto tid = spawn(
    (Tid self) {
        auto msg = self.receiveOnly!(double, Record);
        assert(msg[0] == 0.5);
        assert(msg[1].name == "Alice");
        assert(msg[1].age == 31);
    });

    send(tid, 0.5, Record("Alice", 31));
}

@system unittest
{
    static void t1(Tid self, Tid mainTid)
    {
        try
        {
            self.receiveOnly!string();
            mainTid.send("");
        }
        catch (Throwable th)
        {
            mainTid.send(th.msg);
        }
    }

    auto self = thisTid();
    auto tid = spawn(&t1, self);
    tid.send(1);
    string result = self.receiveOnly!string();
    assert(result == "Unexpected message type: expected 'string', got 'int'");
}

/**
 * Tries to receive but will give up if no matches arrive within duration.
 * Won't wait at all if provided $(REF Duration, core,time) is negative.
 *
 * Same as `receive` except that rather than wait forever for a message,
 * it waits until either it receives a message or the given
 * $(REF Duration, core,time) has passed. It returns `true` if it received a
 * message and `false` if it timed out waiting for one.
 */
bool receiveTimeout(T...)(Tid self, Duration duration, T ops)
in
{
    assert(self.mbox !is null,
        "Cannot receive a message until a thread was spawned or thisTid was passed to a running thread.");
}
do
{
    checkops(ops);
    return self.mbox.get(duration, ops);
}

@safe unittest
{
    static assert(__traits(compiles, {
        receiveTimeout(Tid.init, msecs(0), (Variant x) {});
        receiveTimeout(Tid.init, msecs(0), (int x) {}, (Variant x) {});
    }));

    static assert(!__traits(compiles, {
        receiveTimeout(Tid.init, msecs(0), (Variant x) {}, (int x) {});
    }));

    static assert(!__traits(compiles, {
        receiveTimeout(Tid.init, msecs(0), (int x) {}, (int x) {});
    }));

    static assert(__traits(compiles, {
        receiveTimeout(Tid.init, msecs(10), (int x) {}, (Variant x) {});
    }));
}


/**
 * Encapsulates all implementation-level data needed for scheduling.
 *
 * When defining a Scheduler, an instance of this struct must be associated
 * with each logical thread.  It contains all implementation-level information
 * needed by the internal API.
 */
struct ThreadInfo
{
    Tid ident;
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
    void cleanup()
    {
        if (ident.mbox !is null)
            ident.mbox.close();
        if (owner != Tid.init)
            _send(MsgType.linkDead, owner, ident);
    }
}

/**
 * An example Scheduler using kernel threads.
 *
 * This is an example Scheduler that mirrors the default scheduling behavior
 * of creating one kernel thread per call to spawn.  It is fully functional
 * and may be instantiated and used, but is not a necessary part of the
 * default functioning of this module.
 */
class ThreadScheduler
{
    /**
     * This simply runs op directly, since no real scheduling is needed by
     * this approach.
     */
    void start(void delegate() op)
    {
        op();
    }

    /**
     * Creates a new kernel thread and assigns it to run the supplied op.
     */
    void spawn(void delegate() op)
    {
        auto t = new Thread(op);
        t.start();
    }

    /**
     * Returns ThreadInfo.thisInfo, since it is a thread-local instance of
     * ThreadInfo, which is the correct behavior for this scheduler.
     */
    @property ref ThreadInfo thisInfo() nothrow
    {
        return ThreadInfo.thisInfo;
    }

    /**
     * Creates a new Condition variable.  No custom behavior is needed here.
     */
    Condition newCondition(Mutex m) nothrow
    {
        return new Condition(m);
    }
}

/**
 * An example Scheduler using Fibers.
 *
 * This is an example scheduler that creates a new Fiber per call to spawn
 * and multiplexes the execution of all fibers within the main thread.
 */
class FiberScheduler
{
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
        FiberScheduler.yield();
    }

    /**
     * If the caller is a scheduled Fiber, this yields execution to another
     * scheduled Fiber.
     */
    static void yield() nothrow
    {
        // NOTE: It's possible that we should test whether the calling Fiber
        //       is an InfoFiber before yielding, but I think it's reasonable
        //       that any fiber should yield here.
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
    @property ref ThreadInfo thisInfo() nothrow
    {
        auto f = cast(InfoFiber) Fiber.getThis();

        if (f !is null)
            return f.info;
        return ThreadInfo.thisInfo;
    }

    /**
     * Returns a Condition analog that yields when wait or notify is called.
     *
     * Bug:
     * For the default implementation, `notifyAll`will behave like `notify`.
     *
     * Params:
     *   m = A `Mutex` to use for locking if the condition needs to be waited on
     *       or notified from multiple `Thread`s.
     *       If `null`, no `Mutex` will be used and it is assumed that the
     *       `Condition` is only waited on/notified from one `Thread`.
     */
    Condition newCondition(Mutex m) nothrow
    {
        return new FiberCondition();
    }

protected:
    /**
     * Creates a new Fiber which calls the given delegate.
     *
     * Params:
     *   op = The delegate the fiber should call
     */
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

    /**
     * Fiber which embeds a ThreadInfo
     */
    static class InfoFiber : Fiber
    {
        ThreadInfo info;

        this(void delegate() op, size_t sz = 16 * 1024 * 1024) nothrow
        {
            super(op, sz);
        }
    }

    protected class FiberCondition : Condition
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
                FiberScheduler.yield();
        }

        override bool wait(Duration period) nothrow
        {
            import core.time : MonoTime;

            scope (exit) notified = false;

            for (auto limit = MonoTime.currTime + period;
                 !notified && !period.isNegative;
                 period = limit - MonoTime.currTime)
            {
                FiberScheduler.yield();
            }
            return notified;
        }

        override void notify() nothrow
        {
            notified = true;
            FiberScheduler.yield();
        }

        override void notifyAll() nothrow
        {
            notified = true;
            FiberScheduler.yield();
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

private:
    Fiber[] m_fibers;
    size_t m_pos;
}

package
{
    /*
     * A MessageBox is a message queue for one thread.  Other threads may send
     * messages to this owner by calling put(), and the owner receives them by
     * calling get().  The put() call is therefore effectively shared and the
     * get() call is effectively local.  setMaxMsgs may be used by any thread
     * to limit the size of the message queue.
     */
    class MessageBox
    {
        this() @trusted nothrow /* TODO: make @safe after relevant druntime PR gets merged */
        {
            m_lock = new Mutex;
            m_closed = false;

            m_putMsg = new Condition(m_lock);
            m_notFull = new Condition(m_lock);
        }

        ///
        final @property bool isClosed() @safe @nogc pure
        {
            synchronized (m_lock)
            {
                return m_closed;
            }
        }

        /*
         * If maxMsgs is not set, the message is added to the queue and the
         * owner is notified.  If the queue is full, the message will still be
         * accepted if it is a control message, otherwise onCrowdingDoThis is
         * called.  If the routine returns true, this call will block until
         * the owner has made space available in the queue.  If it returns
         * false, this call will abort.
         *
         * Params:
         *  msg = The message to put in the queue.
         *
         * Throws:
         *  An exception if the queue is full and onCrowdingDoThis throws.
         */
        final void put(ref Message msg)
        {
            synchronized (m_lock)
            {
                // TODO: Generate an error here if m_closed is true, or maybe
                //       put a message in the caller's queue?
                if (!m_closed)
                {
                    while (true)
                    {
                        if (isPriorityMsg(msg))
                        {
                            m_sharedPty.put(msg);
                            m_putMsg.notify();
                            return;
                        }
                        if (!mboxFull() || isControlMsg(msg))
                        {
                            m_sharedBox.put(msg);
                            m_putMsg.notify();
                            return;
                        }
                        if (m_onMaxMsgs !is null && !m_onMaxMsgs(thisTid))
                        {
                            return;
                        }
                        m_putQueue++;
                        m_notFull.wait();
                        m_putQueue--;
                    }
                }
            }
        }

        /*
         * Matches ops against each message in turn until a match is found.
         *
         * Params:
         *  ops = The operations to match.  Each may return a bool to indicate
         *        whether a message with a matching type is truly a match.
         *
         * Returns:
         *  true if a message was retrieved and false if not (such as if a
         *  timeout occurred).
         *
         * Throws:
         *  LinkTerminated if a linked thread terminated, or OwnerTerminated
         * if the owner thread terminates and no existing messages match the
         * supplied ops.
         */
        bool get(T...)(scope T vals)
        {
            import std.meta : AliasSeq;

            static assert(T.length, "T must not be empty");

            static if (isImplicitlyConvertible!(T[0], Duration))
            {
                alias Ops = AliasSeq!(T[1 .. $]);
                alias ops = vals[1 .. $];
                enum timedWait = true;
                Duration period = vals[0];
            }
            else
            {
                alias Ops = AliasSeq!(T);
                alias ops = vals[0 .. $];
                enum timedWait = false;
            }

            bool onStandardMsg(ref Message msg)
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

            bool onLinkDeadMsg(ref Message msg)
            {
                assert(msg.convertsTo!(Tid),
                        "Message could be converted to Tid");
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

            bool onControlMsg(ref Message msg)
            {
                switch (msg.type)
                {
                case MsgType.linkDead:
                    return onLinkDeadMsg(msg);
                default:
                    return false;
                }
            }

            bool scan(ref ListT list)
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

            bool pty(ref ListT list)
            {
                if (!list.empty)
                {
                    auto range = list[];

                    if (onStandardMsg(range.front))
                    {
                        list.removeAt(range);
                        return true;
                    }
                    if (range.front.convertsTo!(Throwable))
                        throw range.front.get!(Throwable);
                    else if (range.front.convertsTo!(shared(Throwable)))
                        throw range.front.get!(shared(Throwable));
                    else
                        throw new PriorityMessageException(range.front.data);
                }
                return false;
            }

            static if (timedWait)
            {
                import core.time : MonoTime;
                auto limit = MonoTime.currTime + period;
            }

            while (true)
            {
                ListT arrived;

                if (pty(m_localPty) || scan(m_localBox))
                {
                    return true;
                }
                FiberScheduler.yield();
                synchronized (m_lock)
                {
                    updateMsgCount();
                    while (m_sharedPty.empty && m_sharedBox.empty)
                    {
                        // NOTE: We're notifying all waiters here instead of just
                        //       a few because the onCrowding behavior may have
                        //       changed and we don't want to block sender threads
                        //       unnecessarily if the new behavior is not to block.
                        //       This will admittedly result in spurious wakeups
                        //       in other situations, but what can you do?
                        if (m_putQueue && !mboxFull())
                            m_notFull.notifyAll();
                        static if (timedWait)
                        {
                            if (period <= Duration.zero || !m_putMsg.wait(period))
                                return false;
                        }
                        else
                        {
                            m_putMsg.wait();
                        }
                    }
                    m_localPty.put(m_sharedPty);
                    arrived.put(m_sharedBox);
                }
                if (m_localPty.empty)
                {
                    scope (exit) m_localBox.put(arrived);
                    if (scan(arrived))
                    {
                        return true;
                    }
                    else
                    {
                        static if (timedWait)
                        {
                            period = limit - MonoTime.currTime;
                        }
                        continue;
                    }
                }
                m_localBox.put(arrived);
                pty(m_localPty);
                return true;
            }
        }

        /*
         * Called on thread termination.  This routine processes any remaining
         * control messages, clears out message queues, and sets a flag to
         * reject any future messages.
         */
        final void close()
        {
            static void onLinkDeadMsg(ref Message msg)
            {
                assert(msg.convertsTo!(Tid),
                        "Message could be converted to Tid");
                auto tid = msg.get!(Tid);

                if (tid == thisInfo.owner)
                    thisInfo.owner = Tid.init;
            }

            static void sweep(ref ListT list)
            {
                for (auto range = list[]; !range.empty; range.popFront())
                {
                    if (range.front.type == MsgType.linkDead)
                        onLinkDeadMsg(range.front);
                }
            }

            ListT arrived;

            sweep(m_localBox);
            synchronized (m_lock)
            {
                arrived.put(m_sharedBox);
                m_closed = true;
            }
            m_localBox.clear();
            sweep(arrived);
        }

    private:
        // Routines involving local data only, no lock needed.

        bool mboxFull() @safe @nogc pure nothrow
        {
            return m_maxMsgs && m_maxMsgs <= m_localMsgs + m_sharedBox.length;
        }

        void updateMsgCount() @safe @nogc pure nothrow
        {
            m_localMsgs = m_localBox.length;
        }

        bool isControlMsg(ref Message msg) @safe @nogc pure nothrow
        {
            return msg.type != MsgType.standard && msg.type != MsgType.priority;
        }

        bool isPriorityMsg(ref Message msg) @safe @nogc pure nothrow
        {
            return msg.type == MsgType.priority;
        }

        bool isLinkDeadMsg(ref Message msg) @safe @nogc pure nothrow
        {
            return msg.type == MsgType.linkDead;
        }

        alias OnMaxFn = bool function(Tid);
        alias ListT = List!(Message);

        ListT m_localBox;
        ListT m_localPty;

        Mutex m_lock;
        Condition m_putMsg;
        Condition m_notFull;
        size_t m_putQueue;
        ListT m_sharedBox;
        ListT m_sharedPty;
        OnMaxFn m_onMaxMsgs;
        size_t m_localMsgs;
        size_t m_maxMsgs;
        bool m_closed;
    }

    /*
     *
     */
    struct List(T)
    {
        struct Range
        {
            import std.exception : enforce;

            @property bool empty() const
            {
                return !m_prev.next;
            }

            @property ref T front()
            {
                enforce(m_prev.next, "invalid list node");
                return m_prev.next.val;
            }

            @property void front(T val)
            {
                enforce(m_prev.next, "invalid list node");
                m_prev.next.val = val;
            }

            void popFront()
            {
                enforce(m_prev.next, "invalid list node");
                m_prev = m_prev.next;
            }

            private this(Node* p)
            {
                m_prev = p;
            }

            private Node* m_prev;
        }

        void put(T val)
        {
            put(newNode(val));
        }

        void put(ref List!(T) rhs)
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

        Range opSlice()
        {
            return Range(cast(Node*)&m_first);
        }

        void removeAt(Range r)
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

        @property size_t length()
        {
            return m_count;
        }

        void clear()
        {
            m_first = m_last = null;
            m_count = 0;
        }

        @property bool empty()
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
            void lock() { while (!cas(&locked, false, true)) { Thread.yield(); } }
            void unlock() { atomicStore!(MemoryOrder.rel)(locked, false); }
            bool locked;
        }

        static shared SpinLock sm_lock;
        static shared Node* sm_head;

        Node* newNode(T v)
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

        void freeNode(Node* n)
        {
            // destroy val to free any owned GC memory
            destroy(n.val);

            sm_lock.lock();
            scope (exit) sm_lock.unlock();

            auto sn = cast(shared(Node)*) n;
            sn.next = sm_head;
            sm_head = sn;
        }

        void put(Node* n)
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
}

// test ability to send shared arrays
@system unittest
{
    static shared int[] x = new shared(int)[1];
    auto tid = spawn((Tid self) {
        auto arr = self.receiveOnly!(shared(int)[]);
        arr[0] = 5;
        ownerTid.send(true);
    });
    tid.send(x);
    auto self = thisTid();
    self.receiveOnly!(bool);
    assert(x[0] == 5);
}
