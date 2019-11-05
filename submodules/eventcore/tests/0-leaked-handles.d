/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.driver;
import std.socket : InternetAddress;


class C {
	DatagramSocketFD m_handle;
	EventDriver m_driver;

	this()
	{
		auto addr = new InternetAddress(0x7F000001, 40001);
		m_handle = eventDriver.sockets.createDatagramSocket(addr, null);
		assert(m_handle != DatagramSocketFD.invalid);
		m_driver = eventDriver;
	}

	~this()
	{
		assert(eventDriver is m_driver);
		eventDriver.sockets.releaseRef(m_handle);
	}
}

void main()
{
	// let the GC clean up at app exit
	// note that this happens *after* the static module destructors have been run
	new C;
}
