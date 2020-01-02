module geod24.Transceiver;

import geod24.concurrency;

import core.time;

/// Data sent by the caller
public struct Request
{
    /// ITransceiver of the sender thread
    ITransceiver sender;
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

    /// Request Dropped
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

/// Ask the node to exhibit a certain behavior for a given time
public struct TimeCommand
{
    /// For how long our remote node apply this behavior
    Duration dur;
    /// Whether or not affected messages should be dropped
    bool drop = false;
}

/// Filter out requests before they reach a node
public struct FilterAPI
{
    /// the mangled symbol name of the function to filter
    string func_mangleof;

    /// used for debugging
    string pretty_func;
}

/*******************************************************************************

    Receve request and response
    Interfaces to and from data

*******************************************************************************/

public interface ITransceiver
{
    /***************************************************************************

        It is a function that accepts `Request`.

    ***************************************************************************/

    void send (Request msg);


    /***************************************************************************

        It is a function that accepts `Response`.

    ***************************************************************************/

    void send (Response msg);


    /***************************************************************************

        Generate a convenient string for identifying this ServerTransceiver.

    ***************************************************************************/

    void toString (scope void delegate(const(char)[]) sink);
}


/*******************************************************************************

    Accept only Request. It has `Channel!Request`

*******************************************************************************/

public class ServerTransceiver : ITransceiver
{
    /// Channel of Request
    public Channel!Request req;

    /// Channel of TimeCommand - Using for sleeping
    public Channel!TimeCommand ctrl_time;

    /// Channel of FilterAPI - Using for filtering
    public Channel!FilterAPI ctrl_filter;

    /// Channel of Response
    public Channel!Response res;

    /// Ctor
    public this () @safe nothrow
    {
        req = new Channel!Request();
        ctrl_time = new Channel!TimeCommand();
        ctrl_filter = new Channel!FilterAPI();
        res = new Channel!Response();
    }


    /***************************************************************************

        It is a function that accepts `Request`.

    ***************************************************************************/

    public void send (Request msg) @trusted
    {
        if (thisScheduler !is null)
            this.req.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.req.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }


    /***************************************************************************

        It is a function that accepts `TimeCommand`.

    ***************************************************************************/

    public void send (TimeCommand msg) @trusted
    {
        if (thisScheduler !is null)
            this.ctrl_time.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.ctrl_time.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }

    /***************************************************************************

        It is a function that accepts `FilterAPI`.

    ***************************************************************************/

    public void send (FilterAPI msg) @trusted
    {
        if (thisScheduler !is null)
            this.ctrl_filter.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.ctrl_filter.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }


    /***************************************************************************

        It is a function that accepts `Response`.
        It is not use.

    ***************************************************************************/

    public void send (Response msg) @trusted
    {
        if (thisScheduler !is null)
            this.res.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.res.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }


    /***************************************************************************

        Close the `Channel`

    ***************************************************************************/

    public void close () @trusted
    {
        this.req.close();
        this.ctrl_time.close();
        this.ctrl_filter.close();
        this.res.close();
    }


    /***************************************************************************

        Generate a convenient string for identifying this ServerTransceiver.

    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "STR(%x:%x)", cast(void*) req, cast(void*) res);
    }
}


/*******************************************************************************

    Accept only Response. It has `Channel!Response`

*******************************************************************************/

public class ClientTransceiver : ITransceiver
{
    /// Channel of Response
    public Channel!Response res;

    /// Ctor
    public this () @safe nothrow
    {
        res = new Channel!Response();
    }


    /***************************************************************************

        It is a function that accepts `Request`.
        It is not use.

    ***************************************************************************/

    public void send (Request msg) @trusted
    {
    }


    /***************************************************************************

        It is a function that accepts `Response`.

    ***************************************************************************/

    public void send (Response msg) @trusted
    {
        if (thisScheduler !is null)
            this.res.send(msg);
        else
        {
            auto fiber_scheduler = new FiberScheduler();
            auto condition = fiber_scheduler.newCondition(null);
            fiber_scheduler.start({
                this.res.send(msg);
                condition.notify();
            });
            condition.wait();
        }
    }


    /***************************************************************************

        Close the `Channel`

    ***************************************************************************/

    public void close () @trusted
    {
        this.res.close();
    }


    /***************************************************************************

        Generate a convenient string for identifying this ServerTransceiver.

    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "CTR(0:%x)", cast(void*) res);
    }
}

