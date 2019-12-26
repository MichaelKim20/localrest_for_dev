/*******************************************************************************

    This is a collection of Exception used in this module.

*******************************************************************************/

module geod24.concurrency.Exception;

/*******************************************************************************

    When the channel is closed, it is thrown when the `receive` is called.

*******************************************************************************/

public class ChannelClosed : Exception
{
    /// Ctor
    public this (string msg = "Channel Closed") @safe pure nothrow @nogc
    {
        super(msg);
    }
}
