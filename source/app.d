module test;

import geod24.concurrency;
import geod24.LocalRest;

import core.sync.mutex;
import core.thread;

import std.stdio;

/*
public alias MessageChannel = Channel!Message;

public struct Request
{
    MessagePipeline pipeline;
    string method;
    string args;
}


public enum Status
{
    Failed,
    Timeout,
    Success
}


public struct Response
{
    Status status;
    string data;
}


public struct Message
{
    public this (Request msg)
    {
        this.req = msg;
        this.tag = Message.Type.request;
    }

    public this (Response msg)
    {
        this.res = msg;
        this.tag = Message.Type.response;
    }

    union
    {
        Request req;
        Response res;
    }

    ubyte tag;

    enum Type
    {
        request,
        response
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


public class MessageHandler
{
    public bool exec (Message req, Message res)
    {

    }
}


bool compute (Message req, Message res)
{

    return true;
}
*/

void main ()
{
    import std.process;
    writefln("Current thread ID: %x",  thisThreadID);
}
