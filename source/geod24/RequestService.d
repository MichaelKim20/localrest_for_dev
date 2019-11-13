module geod24.RequestService;

import std.container;
import std.datetime;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.stdio;
import std.traits;
import std.variant;

import core.atomic;
import core.sync.mutex;
import core.thread;


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
 * An opaque type used to represent a logical thread.
 */
struct Tid
{
    private MessageBox mbox;
    private this (MessageBox m) @safe pure nothrow @nogc
    {
        mbox = m;
    }

    /**
     * Generate a convenient string for identifying this Tid.  This is only
     * useful to see if Tid's that are currently executing are the same or
     * different, e.g. for logging and debugging.  It is potentially possible
     * that a Tid executed in the future will have the same toString() output
     * as another Tid that has already terminated.
     */
    public void toString (scope void delegate (const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "Tid(%x)", cast(void*) mbox);
    }
}

static ~this()
{
    thisInfo.cleanup();
    writeln("END");
}

/*
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
*/
/**
 * Returns: The $(LREF Tid) of the caller's thread.
 */
@property Tid thisTid () @safe
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
@property Tid ownerTid ()
{
    import std.exception : enforce;

    enforce!TidMissingException(thisInfo.owner.mbox !is null, "Error: Thread has no owner thread.");
    return thisInfo.owner;
}

private bool hasLocalAliasing(Types...)()
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

// Thread Creation
private template isSpawnable (F, T...)
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
Tid spawn (F, T...) (F fn, T args)
if (isSpawnable! (F, T))
{
    static assert(!hasLocalAliasing!(T), "Aliases to mutable thread-local data not allowed.");

    // TODO: MessageList and &exec should be shared.
    auto spawnTid = Tid(new MessageBox);
    auto ownerTid = thisTid;

    void exec()
    {
        thisInfo.ident = spawnTid;
        thisInfo.owner = ownerTid;
        fn(args);
    }

    auto t = new Thread(&exec);
    t.start();
    
    return spawnTid;
}

public Response query (Tid tid, Request data)
{
    auto req = Message(MsgType.standard, Variant(data));
    auto res = request(tid, req);
    return *res.data.peek!(Response);
}

///
public Message request (Tid tid, Message msg)
{
    //msg.head.request_time = Clock.currTime();
    return tid.mbox.request(msg);
}


public alias ProcessDlg = scope Message delegate (Message msg);
public void process (Tid tid, ProcessDlg dg)
{
    tid.mbox.process(dg);
    // tid.mbox.check_timeout((Message* msg) => {return false;});
}

private
{
    __gshared Tid[string] tidByName;
    __gshared string[][Tid] namesByTid;
}

private @property shared(Mutex) initOnceLock ()
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
auto ref initOnce (alias var) (lazy typeof(var) init, shared Mutex mutex)
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
auto ref initOnce (alias var) (lazy typeof(var) init, Mutex mutex)
{
    return initOnce!var(init, cast(shared) mutex);
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
auto ref initOnce (alias var) (lazy typeof(var) init)
{
    return initOnce!var(init, initOnceLock);
}

private @property Mutex registryLock ()
{
    __gshared Mutex impl;
    initOnce!impl(new Mutex);
    return impl;
}

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

/**
 * Associates name with tid.
 *
 * Associates name with tid in a process-local map.  When the thread
 * represented by tid terminates, any names associated with it will be
 * automatically unregistered.
 *
 * Params:
 *  name = The name to associate with tid.
 *  tid  = The tid register by name.
 *
 * Returns:
 *  true if the name is available and tid is not known to represent a
 *  defunct thread.
 */
public bool register (string name, Tid tid)
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

/**
 * Removes the registered name associated with a tid.
 *
 * Params:
 *  name = The name to unregister.
 *
 * Returns:
 *  true if the name is registered, false if not.
 */
public bool unregister (string name)
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

/**
 * Gets the Tid associated with name.
 *
 * Params:
 *  name = The name to locate within the registry.
 *
 * Returns:
 *  The associated Tid or Tid.init if name is not registered.
 */
public Tid locate (string name)
{
    synchronized (registryLock)
    {
        if (auto tid = name in tidByName)
            return *tid;
        return Tid.init;
    }
}

/**
 * Encapsulates all implementation-level data needed for scheduling.
 *
 * When defining a Scheduler, an instance of this struct must be associated
 * with each logical thread.  It contains all implementation-level information
 * needed by the internal API.
 */
public struct ThreadInfo
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
    static @property ref thisInfo () nothrow
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
        unregisterMe(); // clean up registry entries
    }
}

public @property ref ThreadInfo thisInfo () nothrow
{
    return ThreadInfo.thisInfo;
}

/// Data sent by the caller
public struct Request
{
    /// Tid of the sender thread (cannot be JSON serialized)
    Tid sender;

    /// Method to call
    string method;

    /// Arguments to the method, JSON formatted
    string args;

    ///
    SysTime request_time;

    ///
    Duration delay;

    ///
    Duration timeout;
}

/// Status of a request
public enum Status
{
    /// Request failed
    Failed,

    /// Request timed-out
    Timeout,

    /// Request succeeded
    Success
}

/// Data sent by the callee back to the caller
public struct Response
{
    /// Final status of a request (failed, timeout, success, etc)
    Status status;
    
    /// If `status == Status.Success`, the JSON-serialized return value.
    /// Otherwise, it contains `Exception.toString()`.
    string data;
}

///
public struct ServiceMessage
{
    Request  req;
    Response res;
}

///
public enum MsgType
{
    standard,
    priority,
    linkDead,
}

///
public struct Message
{
    MsgType type;
    Variant data;
}

///
public class MessageBox
{
    /// closed
    private bool closed;

    /// lock
    private Mutex mutex;

    /// collection of equest waiters
    private DList!(SudoFiber) queue;

    /// Ctor
    public this ()
    {
        this.closed = false;
        this.mutex = new Mutex;
    }

    /***************************************************************************

        Send data `msg`.
        First, check the receiving waiter that is in the `recvq`.
        If there are no targets there, add data to the `queue`.
        If queue is full then stored waiter(fiber) to the `sendq`.

        Params:
            msg = value to send

        Return:
            true if the sending is successful, otherwise false

    ***************************************************************************/

    public Message request (Message req_msg)
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();
            return Message(MsgType.standard, Variant(Response(Status.Failed, "")));
        }

        Message res_msg;
        Fiber fiber = Fiber.getThis();
        if (fiber !is null)
        {
            SudoFiber new_sf;
            new_sf.fiber = fiber;
            new_sf.req_msg = &req_msg;
            new_sf.res_msg = &res_msg;

            this.queue.insertBack(new_sf);
            this.mutex.unlock();
            Fiber.yield();
        }
        else
        {
            shared(bool) is_waiting = true;
            void stopWait() {
                is_waiting = false;
            }
            SudoFiber new_sf;
            new_sf.fiber = null;
            new_sf.req_msg = &req_msg;
            new_sf.res_msg = &res_msg;
            new_sf.swdg = &stopWait;

            this.queue.insertBack(new_sf);
            this.mutex.unlock();
            while (is_waiting)
                Thread.sleep(dur!("msecs")(1));
        }

        return res_msg;
    }

    /***************************************************************************

        Write the data received in `msg`

        Params:
            msg = value to receive

        Return:
            true if the receiving is successful, otherwise false

    ***************************************************************************/

    public bool process (ProcessDlg dg)
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();

            return false;
        }

        if (this.queue[].walkLength > 0)
        {
            SudoFiber sf = this.queue.front;

            this.queue.removeFront();

            this.mutex.unlock();

            (*sf.res_msg) = dg(*sf.req_msg);

            if (sf.fiber !is null)
                sf.fiber.call();
            else if (sf.swdg !is null)
                sf.swdg();

            return true;
        }
        return false;
    }

    /***************************************************************************

        Check timeout

    ***************************************************************************/

    public void check_timeout (scope bool delegate (Message* msg) dg)
    {
    }


    /***************************************************************************

        Return closing status

        Return:
            true if channel is closed, otherwise false

    ***************************************************************************/

    public @property bool isClosed () @safe @nogc pure
    {
        synchronized (this.mutex)
        {
            return this.closed;
        }
    }

    /***************************************************************************

        Close channel

    ***************************************************************************/

    public void close ()
    {
        SudoFiber sf;
        bool res;

        this.mutex.lock();
        scope (exit) this.mutex.unlock();

        this.closed = true;

        while (true)
        {
            if (this.queue[].walkLength == 0)
                break;

            sf = this.queue.front;
            this.queue.removeFront();

            //sf.msg.res.status = Status.Failed;

            if (sf.fiber !is null)
                sf.fiber.call();
            else if (sf.swdg !is null)
                sf.swdg();
        }
    }

}

private alias StopWaitDg = void delegate ();

///
private struct SudoFiber
{
    public Fiber fiber;
    public Message* req_msg;
    public Message* res_msg;
    public StopWaitDg swdg;
}

/*
@system unittest
{
    import std.stdio;
    auto today = Clock.currTime();
    writeln(today);

    Message msg;
    msg.req = Request(thisTid(), "", "");
    auto child = spawn({
        bool terminated = false;
        while (!terminated)
        {
            thisTid.process((Message* msg) {
                msg.res.data = "12121";
                writeln(msg.req.sender);
                terminated = true;
            });
            Thread.sleep(dur!("msecs")(1));
        }
    });
    child.request(&msg);
    writeln(msg.res.data);
}
*/
