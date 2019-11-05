/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import core.time;

import vibe.core.core;
import vibe.core.net;

ushort port;
void main()
{
	runTask(&server);
	runTask(&client);

	runEventLoop();
}

void server()
{
	auto listener = listenTCP(0, (conn) @safe nothrow {
		try { sleep(200.msecs); } catch (Exception) {}
	});
	port = listener[0].bindAddress.port;
}

void client()
{
	sleep(100.msecs);
	auto tcp = connectTCP("127.0.0.1", port);
	runTask({
		sleep(10.msecs);
		tcp.close();
	});
	assert(!tcp.waitForData());
	exitEventLoop(true);
}