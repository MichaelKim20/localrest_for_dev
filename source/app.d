/+ dub.sdl:
	name "test"
	description "Tests vibe.d's std.concurrency integration"
	dependency "vibe-core" path="../"
+/
module test;

import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

import core.atomic;
import core.time;
import core.stdc.stdlib : exit;

import std.stdio;
import vibe.data.json;


public class MyBox (T)
{
	public void send(T) (T val)
	{
		writeln("send %s", val);
	}
}

/*
public class MyNode (T, U)
{
	this
}
*/

public void viewOptions(T...) (T ops)
{
	foreach (i, t1; T)
	{
		writefln("%s", t1);
	}
}

void main()
{
	viewOptions(int, double);
}
