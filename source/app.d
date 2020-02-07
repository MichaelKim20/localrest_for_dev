module test;

import geod24.concurrency;
import geod24.LocalRest;

import core.sync.mutex;
import core.thread;


public alias MessageChannel = Channel!Message;


public struct Request
{
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
    public MessageChannel sender;
    public MessageChannel receiver;

    public this (MessageChannel receiver, MessageChannel sender = null)
    {
        if (sender !is null)
            this.sender = sender;
        else
            this.sender = new MessageChannel();
        this.receiver = receiver;
    }

    public Message query (Message req)
    {
        this.sender.send(req);
        Message res = this.receiver.receive();
        return res;
    }

    public void reply (Message res)
    {
        this.receiver.send(res);
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
