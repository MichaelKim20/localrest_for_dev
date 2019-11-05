module eventcore.drivers.winapi.pipes;

version (Windows):

import eventcore.driver;
import eventcore.internal.win32;

final class WinAPIEventDriverPipes : EventDriverPipes {
@safe: /*@nogc:*/ nothrow:
    override PipeFD adopt(int system_pipe_handle)
    {
        assert(false, "TODO!");
    }

    override void read(PipeFD pipe, ubyte[] buffer, IOMode mode, PipeIOCallback on_read_finish)
    {
        assert(false, "TODO!");
    }

    override void cancelRead(PipeFD pipe)
    {
        assert(false, "TODO!");
    }

    override void write(PipeFD pipe, const(ubyte)[] buffer, IOMode mode, PipeIOCallback on_write_finish)
    {
        assert(false, "TODO!");
    }

    override void cancelWrite(PipeFD pipe)
    {
        assert(false, "TODO!");
    }

    override void waitForData(PipeFD pipe, PipeIOCallback on_data_available)
    {
        assert(false, "TODO!");
    }

    override void close(PipeFD pipe)
    {
        assert(false, "TODO!");
    }

    override void addRef(PipeFD pid)
    {
        assert(false, "TODO!");
    }

    override bool releaseRef(PipeFD pid)
    {
        assert(false, "TODO!");
    }

    protected override void* rawUserData(PipeFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
    @system {
        assert(false, "TODO!");
    }
}
