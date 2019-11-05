/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;

import core.time;


void main()
{
	// make sure that the internal driver is initialized, so that
	// base resources are all allocated
	sleep(1.msecs);

	auto initial = determineSocketCount();

	TCPConnection conn;
	try {
		conn = connectTCP("127.0.0.1", 16565);
		logError("Connection: %s", conn);
		conn.close();
		assert(false, "Didn't expect TCP connection on port 16565 to succeed");
	} catch (Exception) { }

	assert(determineSocketCount() == initial, "Sockets leaked!");
}

size_t determineSocketCount()
{
	import std.algorithm.searching : count;
	import std.exception : enforce;
	import std.range : iota;

	version (Posix) {
		import core.sys.posix.sys.resource : getrlimit, rlimit, RLIMIT_NOFILE;
		import core.sys.posix.fcntl : fcntl, F_GETFD;

		rlimit rl;
		enforce(getrlimit(RLIMIT_NOFILE, &rl) == 0);
		return iota(rl.rlim_cur).count!((fd) => fcntl(cast(int)fd, F_GETFD) != -1);
	} else {
		import core.sys.windows.winsock2 : getsockopt, SOL_SOCKET, SO_TYPE;

		int st;
		int stlen = st.sizeof;
		return iota(65536).count!(s => getsockopt(s, SOL_SOCKET, SO_TYPE, cast(void*)&st, &stlen) == 0);
	}
}
