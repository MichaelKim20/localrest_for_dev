/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import vibe.core.core;

import core.memory;
import core.time;


int main()
{
	setTimer(10.seconds, { assert(false, "Event loop didn't exit in time."); });

	// make sure that periodic timers for which no explicit reference is stored
	// are still getting invoked periodically
	size_t i = 0;
	setTimer(50.msecs, { if (i++ == 3) exitEventLoop(); }, true);

	return runEventLoop();
}
