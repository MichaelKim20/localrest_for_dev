/*******************************************************************************

    Registry implementation for multi-threaded access

    This registry allows to look up a `Transceiver` based on a `string`.
    It is extracted from the `std.concurrency` module to make it reusable

*******************************************************************************/

module geod24.Registry;

import core.sync.mutex;
import geod24.concurrency;

/// Ditto
public shared struct Registry
{
    private Transceiver[string] transceiverByName;
    private string[][Transceiver] namesByTransceiver;
    private Mutex registryLock;

    /// Initialize this registry, creating the Mutex
    public void initialize() @safe nothrow
    {
        this.registryLock = new shared Mutex;
    }

    /**
     * Gets the Transceiver associated with name.
     *
     * Params:
     *  name = The name to locate within the registry.
     *
     * Returns:
     *  The associated Transceiver or Transceiver.init if name is not registered.
     */
    Transceiver locate(string name)
    {
        synchronized (registryLock)
        {
            if (shared(Transceiver)* transceiver = name in this.transceiverByName)
                return *cast(Transceiver*)transceiver;
            return Transceiver.init;
        }
    }

    /**
     * Associates name with transceiver.
     *
     * Associates name with transceiver in a process-local map.  When the thread
     * represented by transceiver terminates, any names associated with it will be
     * automatically unregistered.
     *
     * Params:
     *  name = The name to associate with transceiver.
     *  transceiver  = The transceiver register by name.
     *
     * Returns:
     *  true if the name is available and transceiver is not known to represent a
     *  defunct thread.
     */
    bool register(string name, Transceiver transceiver)
    {
        synchronized (registryLock)
        {
            if (name in transceiverByName)
                return false;
            if (transceiver.chan.isClosed)
                return false;
            this.namesByTransceiver[transceiver] ~= name;
            this.transceiverByName[name] = cast(shared)transceiver;
            return true;
        }
    }

    /**
     * Removes the registered name associated with a transceiver.
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
            if (shared(Transceiver)* transceiver = name in this.transceiverByName)
            {
                auto allNames = *cast(Transceiver*)transceiver in this.namesByTransceiver;
                auto pos = countUntil(*allNames, name);
                remove!(SwapStrategy.unstable)(*allNames, pos);
                this.transceiverByName.remove(name);
                return true;
            }
            return false;
        }
    }
}
