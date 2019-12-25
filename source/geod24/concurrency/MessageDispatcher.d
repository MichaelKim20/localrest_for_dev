module geod24.concurrency.MessageDispatcher;

import std.container;
import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;
import core.thread;

import geod24.concurrency.Scheduler;

/// Ditto
public class MessageDispatcher (T)
{
    public FiberScheduler scheduler;
    public Thread thread;

    public this (void function() fn, ulong sz = 0LU) pure nothrow @nogc @safe
    {
        super(fn, sz);
        this.scheduler = new FiberScheduler;
        this.chan = new Channel!T(this.scheduler);
    }

    public this (void delegate() dg, ulong sz = 0LU) pure nothrow @nogc @safe
    {
        super(dg, sz);
        this.scheduler = new FiberScheduler!T();
        this.chan = new Channel!T(this.scheduler, chan_size);
    }

    public void send (T) (T msg)
    {
        auto f = cast(MessageInfoFiber) Fiber.getThis();
        if (f !is null)
            this.chan.put(msg);
        else
        {
            auto cond = this.scheduler.newCondition(null);
            this.spawnFiber(
            {
                this.chan.put(msg);
                cond.notify();
            });
            cond.wait();
        }
    }

    public T receive ()
    {
        auto f = cast(MessageInfoFiber) Fiber.getThis();
        if (f !is null)
            return this.chan.get();
        else
        {
            T res;
            auto cond = this.scheduler.newCondition(null);
            this.spawnFiber(
            {
                this.chan.get(&res);
                cond.notify();
            });
            cond.wait();
            return res;
        }
    }

    public void startFiber (void delegate () op)
    {
        this.scheduler.start(op);
    }

    public void spawnFiber (void delegate () op)
    {
        this.scheduler.spawn(op);
    }
}
