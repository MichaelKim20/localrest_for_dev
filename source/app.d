module test;

import vibe.data.json;
import geod24.MessageDispatcher;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;

void main()
{
    //thisInfo.self = new MainDispatcher();
    writefln("%s", ownerMessageDispatcher);
    writefln("%s", thisScheduler);
}
