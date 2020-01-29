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
    Removed Tid, spawn
    Added Channel

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

import std.container;
import std.range;

import core.sync.condition;
import core.sync.mutex;
import core.thread;


/// Data sent by the caller
public struct Request
{
    /// Transceiver of the sender thread
    Transceiver sender;

    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response`
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id;

    /// Method to call
    string method;

    /// Arguments to the method, JSON formatted
    string args;
};


/// Status of a request
public enum Status
{
    /// Request failed
    Failed,

    /// Request timed-out
    Timeout,

    /// Request droped
    Dropped,

    /// Request succeeded
    Success
};


/// Data sent by the callee back to the caller
public struct Response
{
    /// Final status of a request (failed, timeout, success, etc)
    Status status;
    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response` so the scheduler can
    /// properly dispatch this event
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id;
    /// If `status == Status.Success`, the JSON-serialized return value.
    /// Otherwise, it contains `Exception.toString()`.
    string data;
};


/// Filter out requests before they reach a node
public struct FilterAPI
{
    /// the mangled symbol name of the function to filter
    string func_mangleof;

    /// used for debugging
    string pretty_func;
}


/// Ask the node to exhibit a certain behavior for a given time
public struct TimeCommand
{
    /// For how long our remote node apply this behavior
    Duration dur;
    /// Whether or not affected messages should be dropped
    bool drop = false;

    bool send_response_msg = true;
}


/// Ask the node to shut down
public struct ShutdownCommand
{
}


/// Owner Terminate
public struct OwnerTerminateCommand
{
}


/// Status of a request
public enum MessageType
{
    request,
    response,
    filter,
    time_command,
    shutdown_command
};


// very simple & limited variant, to keep it performant.
// should be replaced by a real Variant later
static struct Message
{
    this (Request msg) { this.req = msg; this.tag = MessageType.request; }
    this (Response msg) { this.res = msg; this.tag = MessageType.response; }
    this (FilterAPI msg) { this.filter = msg; this.tag = MessageType.filter; }
    this (TimeCommand msg) { this.time = msg; this.tag = MessageType.time_command; }
    this (ShutdownCommand msg) { this.shutdown = msg; this.tag = MessageType.shutdown_command; }

    union
    {
        Request req;
        Response res;
        FilterAPI filter;
        TimeCommand time;
        ShutdownCommand shutdown;
    }

    ubyte tag;
}


/*******************************************************************************

    Receve request and response
    Interfaces to and from data

*******************************************************************************/

public class Transceiver
{
    /// Channel of Request
    public Channel!Message chan;

    /// Ctor
    public this () @safe nothrow
    {
        chan = new Channel!Message(64*1024);
    }


    /***************************************************************************

        It is a function that accepts Message

        Params:
            msg = The `Message` to send.

        In:
            thisScheduler must not be null.

    ***************************************************************************/

    public void send (Message msg) @trusted
    {
        this.chan.send(msg);
    }


    /***************************************************************************

        It is a function that accepts Request

        Params:
            msg = The `Request` to send.

    ***************************************************************************/

    public void send (Request msg) @trusted
    {
        this.send(Message(msg));
    }


    /***************************************************************************

        It is a function that accepts Response

        Params:
            msg = The `Response` to send.

    ***************************************************************************/

    public void send (Response msg) @trusted
    {
        this.send(Message(msg));
    }


    /***************************************************************************

        It is a function that accepts TimeCommand

        Params:
            msg = The `TimeCommand` to send.

    ***************************************************************************/

    public void send (TimeCommand msg) @trusted
    {
        this.send(Message(msg));
    }


    /***************************************************************************

        It is a function that accepts ShutdownCommand

        Params:
            msg = The `ShutdownCommand` to send.

    ***************************************************************************/

    public void send (ShutdownCommand msg) @trusted
    {
        this.send(Message(msg));
    }


    /***************************************************************************

        It is a function that accepts FilterAPI

        Params:
            msg = The `FilterAPI` to send.

    ***************************************************************************/

    public void send (FilterAPI msg) @trusted
    {
        this.send(Message(msg));
    }


    /***************************************************************************

        Return the received message.

        Returns:
            A received `Message`

    ***************************************************************************/

    public bool receive (Message *msg) @trusted
    {
        return this.chan.receive(msg);
    }


    /***************************************************************************

        Return the received message.

        Params:
            msg = The `Message` pointer to receive.

        Returns:
            Returns true when message has been received. Otherwise false

    ***************************************************************************/

    public bool tryReceive (Message *msg) @trusted
    {
        return this.chan.tryReceive(msg);
    }


    /***************************************************************************

        Close the `Channel`

    ***************************************************************************/

    public void close () @trusted
    {
        this.chan.close();
    }


    /***************************************************************************

        Generate a convenient string for identifying this Transceiver.

    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "TR(%x)", cast(void*) chan);
    }
}


/*******************************************************************************

    After making the request, wait until the response comes,
    and find the response that suits the request.

*******************************************************************************/

public class WaitingManager
{
    /// Just a Condition with a state
    private struct Waiting
    {
        Condition c;
        bool busy;
    }

    /// The 'Response' we are currently processing, if any
    public Response pending;

    /// Request IDs waiting for a response
    public Waiting[ulong] waiting;


    /// Get the next available request ID
    public size_t getNextResponseId () @safe nothrow
    {
        static size_t last_idx;
        return last_idx++;
    }

    /// Wait for a response.
    public Response waitResponse (size_t id, Duration duration) @trusted nothrow
    {
        try
        {
            if (id !in this.waiting)
                this.waiting[id] = Waiting(thisScheduler.newCondition(null), false);

            Waiting* ptr = &this.waiting[id];
            if (ptr.busy)
                assert(0, "Trying to override a pending request");

            ptr.busy = true;

            if (duration == Duration.init)
                ptr.c.wait();
            else if (!ptr.c.wait(duration))
                this.pending = Response(Status.Timeout, id, "");

            ptr.busy = false;

            scope(exit) this.pending = Response.init;
            return this.pending;
        }
        catch (Exception e)
        {
            import std.format;
            assert(0, format("Exception - %s", e.message));
        }
    }

    /// Called when a waiting condition was handled and can be safely removed
    public void remove (size_t id) @safe nothrow
    {
        this.waiting.remove(id);
    }

    /// Returns true if a key value equal to id exists.
    public bool exist (size_t id) @safe nothrow
    {
        return ((id in this.waiting) !is null);
    }

    ///
    public void cleanup ()
    {
        this.waiting.clear();
   }
}

/*******************************************************************************

    Encapsulates all implementation-level data needed for scheduling.

    When defining a Scheduler, an instance of this struct must be associated
    with each logical thread.  It contains all implementation-level information
    needed by the internal API.

*******************************************************************************/

public struct ThreadInfo
{
    Transceiver     transceiver;

    FiberScheduler  scheduler;

    WaitingManager  wmanager;

    int tag;


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

        Params:
            root = The top is a Thread and the fibers exist below it.
                   Thread is root, if this value is true,
                   then it is to clean the value that Thread had.

    ***************************************************************************/

    public void cleanup ()
    {
    }
}


/// Information of a Current Thread or Fiber
public @property ref ThreadInfo thisInfo () nothrow
{
    return ThreadInfo.thisInfo;
}


/***************************************************************************

    Getter of Transceiver assigned to a called thread.

    Returns:
        Returns instance of `Transceiver` that is created by top thread.

***************************************************************************/

public @property Transceiver thisTransceiver () nothrow
{
    return thisInfo.transceiver;
}


/***************************************************************************

    Setter of Transceiver assigned to a called thread.

    Params:
        value = The instance of `Transceiver`.

***************************************************************************/

public @property void thisTransceiver (Transceiver value) nothrow
{
    thisInfo.transceiver = value;
}


/***************************************************************************

    Getter of Scheduler assigned to a called thread.

***************************************************************************/

public @property FiberScheduler thisScheduler () nothrow
{
    return thisInfo.scheduler;
}


/***************************************************************************

    Setter of Scheduler assigned to a called thread.

***************************************************************************/

public @property void thisScheduler (FiberScheduler value) nothrow
{
    thisInfo.scheduler = value;
}


/***************************************************************************

    Getter of WaitingManager assigned to a called thread.

***************************************************************************/

public @property WaitingManager thisWaitingManager () nothrow
{
    return thisInfo.wmanager;
}


/***************************************************************************

    Setter of WaitingManager assigned to a called thread.

***************************************************************************/

public @property void thisWaitingManager (WaitingManager value) nothrow
{
    thisInfo.wmanager = value;
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

public class ThreadScheduler
{

    /***************************************************************************

        This simply runs op directly, since no real scheduling is needed by
        this approach.

        Params:
            op = The function to execute. This may be the actual function passed
                by the user to spawn itself, or may be a wrapper function.

    ***************************************************************************/

    public void start (void delegate () op)
    {
        op();
    }


    /***************************************************************************

        Creates a new kernel thread and assigns it to run the supplied op.

        Params:
            op = The function to execute. This may be the actual function passed
                by the user to spawn itself, or may be a wrapper function.

    ***************************************************************************/

    public void spawn (void delegate () op)
    {
        auto t = new Thread({
            thisScheduler = new FiberScheduler();
            scope (exit) {
                thisInfo.cleanup();
            }
            op();
        });
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
}


/*******************************************************************************

    Clean in use from main thread.

*******************************************************************************/

public void cleanupMainThread ()
{
    thread_joinAll();
    thisInfo.cleanup();
}


/*******************************************************************************

    An Scheduler using Fibers.

    This is an example scheduler that creates a new Fiber per call to spawn
    and multiplexes the execution of all fibers within the main thread.

*******************************************************************************/

class FiberScheduler
{
    private Mutex mutex;
    private bool terminated;
    private bool dispatching;

    public this ()
    {
        this.mutex = new Mutex();
    }

    /***************************************************************************

        This creates a new Fiber for the supplied op and then starts the
        dispatcher.

        Params:
            op = The delegate the fiber should call
            sz = The size of the stack

    ***************************************************************************/

    public void start (void delegate () op, size_t sz = 0)
    {
        create(op, sz);
        dispatch();
    }


    /***************************************************************************

        This commands the scheduler to shut down at the end of the program.

    ***************************************************************************/

    public void stop ()
    {
        terminated = true;
    }


    /***************************************************************************

        This created a new Fiber for the supplied op and adds it to the
        dispatch list.

        Params:
            op = The delegate the fiber should call
            sz = The size of the stack

    ***************************************************************************/

    public void spawn (void delegate() op, size_t sz = 0)
    {
        create(op, sz);
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
        return ThreadInfo.thisInfo;
    }


    /***************************************************************************

        Returns a Condition analog that yields when wait or notify is called.

        Params:
            m = The Mutex that will be associated with this condition.

    ***************************************************************************/

    public Condition newCondition (Mutex m) nothrow
    {
        return new FiberCondition(m);
    }


    /***************************************************************************

        Wait until notified.

        Params:
            c = A condition variable analog which is used to check for and
                to signal the addition of messages to a fiber's message queue

    ***************************************************************************/

    public void wait (Condition c)
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

    public bool wait (Condition c, Duration period)
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

    public void notifyAll (Condition c)
    {
        if (c.mutex !is null)
            c.mutex.lock();

        scope (exit)
             if (c.mutex !is null)
                c.mutex.unlock();

        c.notifyAll();
    }


    /***************************************************************************

        Creates a new Fiber which calls the given delegate.

        Params:
            op = The delegate the fiber should call
            sz = The size of the stack

    ***************************************************************************/

    protected void create (void delegate() op, size_t sz = 0) nothrow
    {
        void wrap()
        {
            op();
        }

        InfoFiber f;
        if (sz == 0)
            f = new InfoFiber(&wrap);
        else
            f = new InfoFiber(&wrap, sz);

        this.mutex.lock_nothrow();
        scope(exit) this.mutex.unlock_nothrow();
        this.m_fibers ~= f;
    }


    /***************************************************************************

        Fiber which embeds a ThreadInfo

    ***************************************************************************/

    static public class InfoFiber : Fiber
    {
        public this (void delegate () op) nothrow
        {
            super(op);
        }

        public this (void delegate () op, size_t sz) nothrow
        {
            super (op, sz);
        }
    }


    public class FiberCondition : Condition
    {
        /// Ctor
        public this (Mutex m) nothrow
        {
            super(m);
            notified = false;
        }

        /***********************************************************************

            Wait until notified.

        ***********************************************************************/

        public override void wait () nothrow
        {
            scope(exit) notified = false;

            while (!notified)
                switchContext();
        }


        /***********************************************************************

            Suspends the calling thread until a notification occurs or until
            the supplied time period has elapsed.

            Params:
                period = The time to wait.

        ***********************************************************************/

        public override bool wait (Duration period) nothrow
        {
            import core.time : MonoTime;

            scope(exit) notified = false;

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

        public override void notify () nothrow
        {
            notified = true;
            switchContext();
        }


        /***********************************************************************

            Notifies all waiters.

        ***********************************************************************/

        public override void notifyAll () nothrow
        {
            notified = true;
            switchContext();
        }


        /***********************************************************************

            switch Fiber Context

        ***********************************************************************/

        private void switchContext() nothrow
        {
            if (mutex_nothrow) mutex_nothrow.unlock_nothrow();
            scope (exit)
                if (mutex_nothrow)
                    mutex_nothrow.lock_nothrow();
            this.outer.yield();
        }

        private bool notified;
    }

    private void dispatch ()
    {
        import std.algorithm.mutation : remove;

        if (this.dispatching)
            return;

        this.dispatching = true;

        while (true)
        {
            try

                auto t = m_fibers[m_pos].call(Fiber.Rethrow.no);
                if (t !is null)
                {
                    if (cast(OwnerTerminate) t)
                        break;
                    else
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

                if (m_fibers.length == 0)
                {
                    break;
                }

                if (terminated)
                {
                    break;
                }
            } catch (Exception)
            {
            }
        }
        this.dispatching = false;
    }

    private Fiber[] m_fibers;
    private size_t m_pos;
}


/*******************************************************************************

    When the owner is terminated.

*******************************************************************************/

public class OwnerTerminate : Exception
{
    /// Ctor
    public this (string msg = "Owner Terminated") @safe pure nothrow @nogc
    {
        super(msg);
    }
}

/*******************************************************************************

    This channel has queues that senders and receivers can wait for.
    With these queues, a single thread alone can exchange data with each other.

    Technically, a channel is a data transmission pipe where data can be passed
    into or read from.
    Hence one fiber(thread) can send data into a channel, while other fiber(thread)
    can read that data from the same channel

    It is the Scheduler that allows the channel to connect the fiber organically.
    This allows for the segmentation of small units of logic during a program
    using fiber in a multi-threaded environment.

*******************************************************************************/

public class Channel (T)
{
    /// closed
    private bool closed;

    /// lock for queue and status
    private Mutex mutex;

    /// size of queue
    private size_t qsize;

    /// queue of data
    private DList!T queue;

    /// collection of send waiters
    private DList!(ChannelContext!T) sendq;

    /// collection of recv waiters
    private DList!(ChannelContext!T) recvq;

    /// Ctor
    public this (size_t qsize = 0)
    {
        this.closed = false;
        this.mutex = new Mutex;
        this.qsize = qsize;
    }


    /***************************************************************************

        Send data `msg`.
        First, check the receiving waiter that is in the `recvq`.
        If there are no targets there, add data to the `queue`.
        If queue is full then stored waiter(fiber) to the `sendq`.

        Params:
            msg = value to send

        Return:
            true if the sending is succescontextul, otherwise false

    ***************************************************************************/

    public bool send (T msg)
    {
        bool _send (T msg)
        {
            this.mutex.lock();

            if (this.closed)
            {
                this.mutex.unlock();
                return false;
            }

            if (this.recvq[].walkLength > 0)
            {
                ChannelContext!T context = this.recvq.front;
                this.recvq.removeFront();
                *(context.msg_ptr) = msg;
                this.mutex.unlock();

                if (context.condition !is null)
                    if (thisScheduler !is null)
                        thisScheduler.notify(context.condition);

                return true;
            }

            if (this.queue[].walkLength < this.qsize)
            {
                this.queue.insertBack(msg);
                this.mutex.unlock();
                return true;
            }

            {
                ChannelContext!T new_context;
                new_context.msg_ptr = null;
                new_context.msg = msg;
                new_context.condition = thisScheduler.newCondition(null);

                this.sendq.insertBack(new_context);
                this.mutex.unlock();

                thisScheduler.wait(new_context.condition);
                return true;
            }

        }

        if (thisScheduler !is null)
            return _send(msg);
        else
        {
            bool res;
            thisScheduler = new FiberScheduler();
            auto c = thisScheduler.newCondition(null);
            thisScheduler.start({
                res = _send(msg);
                thisScheduler.notify(c);
            });
            thisScheduler.wait(c);
            return res;
        }
    }


    /***************************************************************************

        Return the received message.

        Return:
            msg = value to receive

    ***************************************************************************/

    public bool receive (T* msg)
    {
        bool _receive(T* msg)
        {
            this.mutex.lock();

            if (this.closed)
            {
                (*msg) = T.init;
                this.mutex.unlock();
                return false;
            }

            if (this.sendq[].walkLength > 0)
            {
                ChannelContext!T context = this.sendq.front;
                this.sendq.removeFront();
                *(msg) = context.msg;
                this.mutex.unlock();

                if (context.condition !is null)
                    if (thisScheduler !is null)
                        thisScheduler.notify(context.condition);

                return true;
            }

            if (this.queue[].walkLength > 0)
            {
                *(msg) = this.queue.front;
                this.queue.removeFront();

                this.mutex.unlock();

                return true;
            }

            {
                ChannelContext!T new_context;
                new_context.msg_ptr = msg;
                new_context.condition = thisScheduler.newCondition(null);

                this.recvq.insertBack(new_context);
                this.mutex.unlock();

                thisScheduler.wait(new_context.condition);

                return true;
            }
        }

        if (thisScheduler !is null)
            return _receive(msg);
        else
        {
            bool res;
            thisScheduler = new FiberScheduler();
            auto c = thisScheduler.newCondition(null);
            thisScheduler.start({
                res = _receive(msg);
                thisScheduler.notify(c);
            });
            thisScheduler.wait(c);
            return res;
        }
    }


    /***************************************************************************

        Return the received message.

        Return:
            msg = value to receive

    ***************************************************************************/

    public bool tryReceive (T *msg)
    {
        bool _tryReceive (T *msg)
        {
            this.mutex.lock();

            if (this.closed)
            {
                this.mutex.unlock();
                return false;
            }

            if (this.sendq[].walkLength > 0)
            {
                ChannelContext!T context = this.sendq.front;
                this.sendq.removeFront();
                *(msg) = context.msg;
                this.mutex.unlock();

                if (context.condition !is null)
                    if (thisScheduler !is null)
                        thisScheduler.notify(context.condition);

                return true;
            }

            if (this.queue[].walkLength > 0)
            {
                *(msg) = this.queue.front;
                this.queue.removeFront();

                this.mutex.unlock();

                return true;
            }

            this.mutex.unlock();
            return false;
        }

        if (thisScheduler !is null)
            return _tryReceive(msg);
        else
        {
            bool res;
            thisScheduler = new FiberScheduler();
            auto c = thisScheduler.newCondition(null);
            thisScheduler.start({
                res = _tryReceive(msg);
                thisScheduler.notify(c);
            });
            thisScheduler.wait(c);
            return res;
        }
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

        Close Channel

    ***************************************************************************/

    public void close ()
    {
        ChannelContext!T context;

        this.mutex.lock();
        scope (exit) this.mutex.unlock();

        this.closed = true;

        while (true)
        {
            if (this.recvq[].walkLength == 0)
                break;

            context = this.recvq.front;
            this.recvq.removeFront();

            if ((context.condition !is null) && (thisScheduler !is null))
                thisScheduler.notify(context.condition);
        }

        this.queue.clear();

        while (true)
        {
            if (this.sendq[].walkLength == 0)
                break;

            context = this.sendq.front;
            this.sendq.removeFront();

            if ((context.condition !is null) && (thisScheduler !is null))
                thisScheduler.notify(context.condition);
        }
    }
}


/***************************************************************************

    A structure to be stored in a queue.
    It has information to use in standby.

***************************************************************************/

private struct ChannelContext (T)
{
    /// This is a message. Used in put
    public T  msg;

    /// This is a message point. Used in get
    public T* msg_ptr;

    //  Waiting Condition
    public Condition condition;
}


/// Fiber1 -> [ channel2 ] -> Fiber2 -> [ channel1 ] -> Fiber1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;

    Mutex mutex = new Mutex;
    Condition condition = new Condition(mutex);

    // Thread1
    thread_scheduler.spawn({
        thisScheduler.start({
            //  Fiber1
            thisScheduler.spawn({
                channel2.send(2);
                channel1.receive(&result);
                synchronized (mutex) {
                    condition.notify;
                }
            });
            //  Fiber2
            thisScheduler.spawn({
                int msg;
                channel2.receive(&msg);
                channel1.send(msg*msg);
            });
        });
    });

    synchronized (mutex) {
        condition.wait(1000.msecs);
    }

    assert(result == 4);

    cleanupMainThread();
}

/// Fiber1 in Thread1 -> [ channel2 ] -> Fiber2 in Thread2 -> [ channel1 ] -> Fiber1 in Thread1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result;

    Mutex mutex = new Mutex;
    Condition condition = new Condition(mutex);

    // Thread1
    thread_scheduler.spawn({
        // Fiber1
        thisScheduler.start({
            channel2.send(2);
            channel1.receive(&result);
            synchronized (mutex) {
                condition.notify;
            }
        });
    });

    // Thread2
    thread_scheduler.spawn({
        // Fiber2
        thisScheduler.start({
            int msg;
            channel2.receive(&msg);
            channel1.send(msg*msg);
        });
    });

    synchronized (mutex) {
        condition.wait(1000.msecs);
    }
    assert(result == 4);

    cleanupMainThread();
}

// If the queue size is 0, it will block when it is sent and received on the same fiber.
unittest
{
    auto channel_qs0 = new Channel!int(0);
    auto channel_qs1 = new Channel!int(1);
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;

    // Thread1
    thread_scheduler.spawn({

        auto cond = thisScheduler.newCondition(null);

        thisScheduler.start({
            //  Fiber1 - It'll be tangled.
            thisScheduler.spawn({
                channel_qs0.send(2);
                channel_qs0.receive(&result);
                thisScheduler.notify(cond);
            });

            assert(!thisScheduler.wait(cond, 1000.msecs));
            assert(result == 0);

            //  Fiber2 - Unravel a tangle
            thisScheduler.spawn({
                channel_qs0.receive(&result);
                channel_qs0.send(2);
            });

            thisScheduler.wait(cond, 1000.msecs);
            assert(result == 2);

            //  Fiber3 - It'll not be tangled, because queue size is 1
            thisScheduler.spawn({
                channel_qs1.send(2);
                channel_qs1.receive(&result);
                thisScheduler.notify(cond);
            });

            thisScheduler.wait(cond, 1000.msecs);
            assert(result == 2);
        });
    });

    cleanupMainThread();
}
