/*******************************************************************************

    Transceiver device required for message exchange between threads.
    Send and receive data requests, responses, commands, etc.

*******************************************************************************/

module geod24.LocalRestType;

import geod24.concurrency;
import core.time;

public alias MessageChannel = Channel!Message;

/// Data sent by the caller
public struct Command
{
    MessagePipeline pipeline;
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

public class MessagePipeline
{
    public MessageChannel producer;
    public MessageChannel consumer;

    public this (MessageChannel producer, MessageChannel consumer)
    {
        if (producer !is null)
            this.producer = producer;
        else
            this.producer = new MessageChannel();
        this.consumer = consumer;
    }

    public Message query (Message req)
    {
        this.consumer.send(req);
        return this.producer.receive();
    }

    public void reply (Message res)
    {
        this.producer.send(res);
    }
}


/***************************************************************************

    Getter of MessageChannel assigned to a called thread.

    Returns:
        Returns instance of `MessageChannel` that is created by top thread.

***************************************************************************/

public @property MessageChannel thisMessageChannel () nothrow
{
    auto p = "messagechannel" in thisInfo.objects;
    if (p !is null)
        return cast(MessageChannel)*p;
    else
        return null;
}


/***************************************************************************

    Setter of MessageChannel assigned to a called thread.

    Params:
        value = The instance of `MessageChannel`.

***************************************************************************/

public @property void thisMessageChannel (MessageChannel value) nothrow
{
    thisInfo.objects["messagechannel"] = value;
}
