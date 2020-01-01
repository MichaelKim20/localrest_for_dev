/*******************************************************************************

    Registry implementation for multi-threaded access

    This registry allows to look up a `ServerTransceiver` based on a `string`.
    It is extracted from the `std.concurrency` module to make it reusable

*******************************************************************************/

module geod24.Registry;

import core.sync.mutex;
import geod24.concurrency;
import geod24.Transceiver;

/// Ditto
public shared struct Registry
{
    private ServerTransceiver[string] tidByName;
    private string[][ServerTransceiver] namesByServerTransceiver;
    private Mutex registryLock;

    /// Initialize this registry, creating the Mutex
    public void initialize() @safe nothrow
    {
        this.registryLock = new shared Mutex;
    }

    /**
     * Gets the ServerTransceiver associated with name.
     *
     * Params:
     *  name = The name to locate within the registry.
     *
     * Returns:
     *  The associated ServerTransceiver or ServerTransceiver.init if name is not registered.
     */
    ServerTransceiver locate(string name)
    {
        synchronized (registryLock)
        {
            if (shared(ServerTransceiver)* tid = name in this.tidByName)
                return *cast(ServerTransceiver*)tid;
            return ServerTransceiver.init;
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
    bool register(string name, ServerTransceiver tid)
    {
        synchronized (registryLock)
        {
            if (name in tidByName)
                return false;
            //if (tid.mbox.isClosed)
            //    return false;
            this.namesByServerTransceiver[tid] ~= name;
            this.tidByName[name] = cast(shared)tid;
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
    bool unregister(string name)
    {
        import std.algorithm.mutation : remove, SwapStrategy;
        import std.algorithm.searching : countUntil;

        synchronized (registryLock)
        {
            if (shared(ServerTransceiver)* tid = name in this.tidByName)
            {
                auto allNames = *cast(ServerTransceiver*)tid in this.namesByServerTransceiver;
                auto pos = countUntil(*allNames, name);
                remove!(SwapStrategy.unstable)(*allNames, pos);
                this.tidByName.remove(name);
                return true;
            }
            return false;
        }
    }
}
