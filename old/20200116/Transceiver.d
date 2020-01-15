/*******************************************************************************

    This is an abstract of the transmission and reception module of the message.
    Send and receive messages using the Channel in `geod24.concurrency`.
    Fiber

    It is the Scheduler that allows the channel to connect the fiber organically.

*******************************************************************************/

module geod24.Transceiver;

import geod24.concurrency;

import core.time;


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

public class Transceiver : InfoObject
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

    public Message receive () @trusted
    {
        return this.chan.receive();
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


    /***************************************************************************

        Cleans up this Transceiver.
        This must be called when a thread terminates.

        Params:
            root = The top is a Thread and the fibers exist below it.
                   Thread is root, if this value is true,
                   then it is to clean the value that Thread had.

    ***************************************************************************/

    public void cleanup (bool root)
    {
        this.close();
    }
}


/***************************************************************************

    Getter of Transceiver assigned to a called thread.

    Returns:
        Returns instance of `Transceiver` that is created by top thread.

***************************************************************************/

public @property Transceiver thisTransceiver () nothrow
{
    if (auto p = "Transceiver" in thisInfo.objectValues)
        return cast(Transceiver)(*p);
    else
        return null;
}


/***************************************************************************

    Setter of Transceiver assigned to a called thread.

    Params:
        value = The instance of `Transceiver`.

***************************************************************************/

public @property void thisTransceiver (Transceiver value) nothrow
{
    thisInfo.objectValues["Transceiver"] = cast(InfoObject)value;
}
