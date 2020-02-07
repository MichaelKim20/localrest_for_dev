/*******************************************************************************

    Transceiver device required for message exchange between threads.
    Send and receive data requests, responses, commands, etc.

*******************************************************************************/

module geod24.LocalRestType;

import geod24.concurrency;
import core.time;

/// Data sent by the caller
public struct Command
{
    /// Transceiver of the sender thread
    Transceiver sender;
    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response`
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id = size_t.max;
    /// Method to call
    string method;
    /// Arguments to the method, JSON formatted
    string args;
}

/// Ask the node to exhibit a certain behavior for a given time
public struct TimeCommand
{
    /// For how long our remote node apply this behavior
    Duration dur;
    /// Whether or not affected messages should be dropped
    bool drop = false;
}

/// Ask the node to shut down
public struct ShutdownCommand
{
}

/// Filter out requests before they reach a node
public struct FilterAPI
{
    /// the mangled symbol name of the function to filter
    string func_mangleof;

    /// used for debugging
    string pretty_func;
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
    /// In order to support re-entrancy, every request contains an id
    /// which should be copied in the `Response` so the scheduler can
    /// properly dispatch this event
    /// Initialized to `size_t.max` so not setting it crashes the program
    size_t id;
    /// If `status == Status.Success`, the JSON-serialized return value.
    /// Otherwise, it contains `Exception.toString()`.
    string data;
}

// very simple & limited variant, to keep it performant.
// should be replaced by a real Variant later
public struct Message
{
    this (Command msg) { this.cmd = msg; this.tag = Message.Type.command; }
    this (Response msg) { this.res = msg; this.tag = Message.Type.response; }
    this (FilterAPI msg) { this.filter = msg; this.tag = Message.Type.filter; }
    this (TimeCommand msg) { this.time = msg; this.tag = Message.Type.time_command; }
    this (ShutdownCommand msg) { this.shutdown = msg; this.tag = Message.Type.shutdown_command; }

    union
    {
        Command cmd;
        Response res;
        FilterAPI filter;
        TimeCommand time;
        ShutdownCommand shutdown;
    }

    ubyte tag;

    /// Status of a request
    enum Type
    {
        command,
        response,
        filter,
        time_command,
        shutdown_command
    }
}


/*******************************************************************************

    Transceiver device required for message exchange between threads.
    Send and receive data requests, responses, commands, etc.

*******************************************************************************/

public class Transceiver
{

    /// Channel of Request
    public Channel!Message chan;

    /// Ctor
    public this () @safe nothrow
    {
        this.chan = new Channel!Message(64*1024);
    }


    /***************************************************************************

        It is a function that accepts Message

        Params:
            msg = The `Message` to send.

    ***************************************************************************/

    public void send (Message msg) @trusted
    {
        this.chan.send(msg);
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

        Return closing status

        Return:
            true if channel is closed, otherwise false

    ***************************************************************************/

    public @property bool isClosed () @safe @nogc pure
    {
        return false;
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


/***************************************************************************

    Getter of Transceiver assigned to a called thread.

    Returns:
        Returns instance of `Transceiver` that is created by top thread.

***************************************************************************/

public @property Transceiver thisTransceiver () nothrow
{
    auto p = "transceiver" in thisInfo.objects;
    if (p !is null)
        return cast(Transceiver)*p;
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
    thisInfo.objects["transceiver"] = value;
}
