/*******************************************************************************

    Registry implementation for multi-threaded access

    This registry allows to look up a `MessageDispatcher` based on a `string`.
    It is extracted from the `std.concurrency` module to make it reusable

*******************************************************************************/


module geod24.Registry;

import core.sync.mutex;
import geod24.MessageDispatcher;

/// Ditto
public shared struct Registry
{
    private MessageDispatcher[string] messageDispatcherByName;
    private string[][MessageDispatcher] namesByMessageDispatcher;
    private Mutex registryLock;

    /// Initialize this registry, creating the Mutex
    public void initialize() @safe nothrow
    {
        this.registryLock = new shared Mutex;
    }

    /**
     * Gets the MessageDispatcher associated with name.
     *
     * Params:
     *  name = The name to locate within the registry.
     *
     * Returns:
     *  The associated MessageDispatcher or MessageDispatcher.init if name is not registered.
     */
    MessageDispatcher locate(string name)
    {
        synchronized (registryLock)
        {
            if (shared(MessageDispatcher)* msg_dispatcher = name in this.messageDispatcherByName)
                return *cast(MessageDispatcher*)msg_dispatcher;
            return null;
        }
    }

    /**
     * Associates name with MessageDispatcher.
     *
     * Associates name with MessageDispatcher in a process-local map.  When the thread
     * represented by MessageDispatcher terminates, any names associated with it will be
     * automatically unregistered.
     *
     * Params:
     *  name = The name to associate with MessageDispatcher.
     *  m  = The MessageDispatcher register by name.
     *
     * Returns:
     *  true if the name is available and MessageDispatcher is not known to represent a
     *  defunct thread.
     */
    bool register(string name, MessageDispatcher msg_dispatcher)
    {
        synchronized (registryLock)
        {
            if (name in messageDispatcherByName)
                return false;
            if (msg_dispatcher.mbox.isClosed)
                return false;
            this.namesByMessageDispatcher[msg_dispatcher] ~= name;
            this.messageDispatcherByName[name] = cast(shared)msg_dispatcher;
            return true;
        }
    }

    /**
     * Removes the registered name associated with a MessageDispatcher.
     *
     * Params:
     *  name = The name to unregister.
     *
     * Returns:
     *  true if the name is registered, false if not.
     */
    bool unregister(string name)
    {
        import std.algorithm.mutation : remove, SwapStrategy;
        import std.algorithm.searching : countUntil;

        synchronized (registryLock)
        {
            if (shared(MessageDispatcher)* msg_dispatcher = name in this.messageDispatcherByName)
            {
                auto allNames = *cast(MessageDispatcher*)msg_dispatcher in this.namesByMessageDispatcher;
                auto pos = countUntil(*allNames, name);
                remove!(SwapStrategy.unstable)(*allNames, pos);
                this.messageDispatcherByName.remove(name);
                return true;
            }
            return false;
        }
    }
}
