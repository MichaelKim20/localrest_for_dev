module eventcore.drivers.winapi.processes;

version (Windows):

import eventcore.driver;
import eventcore.internal.win32;

final class WinAPIEventDriverProcesses : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:
    override ProcessID adopt(int system_pid)
    {
        assert(false, "TODO!");
    }

    override Process spawn(string[] args, ProcessStdinFile stdin, ProcessStdoutFile stdout, ProcessStderrFile stderr, const string[string] env, ProcessConfig config, string working_dir)
    {
        assert(false, "TODO!");
    }

    override bool hasExited(ProcessID pid)
    {
        assert(false, "TODO!");
    }

    override void kill(ProcessID pid, int signal)
    {
        assert(false, "TODO!");
    }

    override size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit)
    {
        assert(false, "TODO!");
    }

    override void cancelWait(ProcessID pid, size_t waitId)
    {
        assert(false, "TODO!");
    }

    override void addRef(ProcessID pid)
    {
        assert(false, "TODO!");
    }

    override bool releaseRef(ProcessID pid)
    {
        assert(false, "TODO!");
    }

    protected override void* rawUserData(ProcessID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
    @system {
        assert(false, "TODO!");
    }
}
