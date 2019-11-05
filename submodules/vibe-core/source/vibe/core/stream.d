/**
	Generic stream interface used by several stream-like classes.

	This module defines the basic (buffered) stream primitives. For concrete stream types, take a
	look at the `vibe.stream` package. The `vibe.stream.operations` module contains additional
	high-level operations on streams, such as reading streams by line or as a whole.

	Note that starting with vibe-core 1.0.0, streams can be of either `struct`  or `class` type.
	Any APIs that take streams as a parameter should use a template type parameter that is tested
	using the appropriate trait (e.g. `isInputStream`) instead of assuming the specific interface
	type (e.g. `InputStream`).

	Copyright: © 2012-2016 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.stream;

import vibe.internal.traits : checkInterfaceConformance, validateInterfaceConformance;
import vibe.internal.interfaceproxy;
import core.time;
import std.algorithm;
import std.conv;

public import eventcore.driver : IOMode;


/** Pipes an InputStream directly into this OutputStream.

	The number of bytes written is either the whole input stream when `nbytes == 0`, or exactly
	`nbytes` for `nbytes > 0`. If the input stream contains less than `nbytes` of data, an
	exception is thrown.

	Returns:
		The actual number of bytes written is returned. If `nbytes` is  given
		and not equal to `ulong.max`, íts value will be returned.
*/
ulong pipe(InputStream, OutputStream)(InputStream source, OutputStream sink, ulong nbytes)
	@blocking @trusted
	if (isOutputStream!OutputStream && isInputStream!InputStream)
{
	import vibe.internal.allocator : theAllocator, makeArray, dispose;

	scope buffer = cast(ubyte[]) theAllocator.allocate(64*1024);
	scope (exit) theAllocator.dispose(buffer);

	//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
	ulong ret = 0;
	if (nbytes == ulong.max) {
		while (!source.empty) {
			size_t chunk = min(source.leastSize, buffer.length);
			assert(chunk > 0, "leastSize returned zero for non-empty stream.");
			//logTrace("read pipe chunk %d", chunk);
			source.read(buffer[0 .. chunk]);
			sink.write(buffer[0 .. chunk]);
			ret += chunk;
		}
	} else {
		while (nbytes > 0) {
			size_t chunk = min(nbytes, buffer.length);
			//logTrace("read pipe chunk %d", chunk);
			source.read(buffer[0 .. chunk]);
			sink.write(buffer[0 .. chunk]);
			nbytes -= chunk;
			ret += chunk;
		}
	}
	return ret;
}
/// ditto
ulong pipe(InputStream, OutputStream)(InputStream source, OutputStream sink)
	@blocking
	if (isOutputStream!OutputStream && isInputStream!InputStream)
{
	return pipe(source, sink, ulong.max);
}


/** Marks a function as blocking.

	Blocking in this case means that it may contain an operation that needs to wait for
	external events, such as I/O operations, and may result in other tasks in the same
	threa being executed before it returns.

	Currently this attribute serves only as a documentation aid and is not enforced
	or used for deducation in any way.
*/
struct blocking {}

/**************************************************************************************************/
/* Public functions                                                                               */
/**************************************************************************************************/

/**
	Returns a `NullOutputStream` instance.

	The instance will only be created on the first request and gets reused for
	all subsequent calls from the same thread.
*/
NullOutputStream nullSink() @safe nothrow
{
	static NullOutputStream ret;
	if (!ret) ret = new NullOutputStream;
	return ret;
}

/**************************************************************************************************/
/* Public types                                                                                   */
/**************************************************************************************************/

/**
	Interface for all classes implementing readable streams.
*/
interface InputStream {
	@safe:

	/** Returns true $(I iff) the end of the input stream has been reached.

		For connection oriented streams, this function will block until either
		new data arrives or the connection got closed.
	*/
	@property bool empty() @blocking;

	/**	(Scheduled for deprecation) Returns the maximum number of bytes that are known to remain available for read.

		After `leastSize()` bytes have been read, the stream will either have reached EOS
		and `empty()` returns `true`, or `leastSize()` returns again a number greater than `0`.
	*/
	@property ulong leastSize() @blocking;

	/** (Scheduled for deprecation) Queries if there is data available for immediate, non-blocking read.
	*/
	@property bool dataAvailableForRead();

	/** Returns a temporary reference to the data that is currently buffered.

		The returned slice typically has the size `leastSize()` or `0` if `dataAvailableForRead()`
		returns `false`. Streams that don't have an internal buffer will always return an empty
		slice.

		Note that any method invocation on the same stream potentially invalidates the contents of
		the returned buffer.
	*/
	const(ubyte)[] peek();

	/**	Fills the preallocated array 'bytes' with data from the stream.

		This function will continue read from the stream until the buffer has
		been fully filled.

		Params:
			dst = The buffer into which to write the data that was read
			mode = Optional reading mode (defaults to `IOMode.all`).

		Return:
			Returns the number of bytes read. The `dst` buffer will be filled up
			to this index. The return value is guaranteed to be `dst.length` for
			`IOMode.all`.

		Throws: An exception if the operation reads past the end of the stream

		See_Also: `readOnce`, `tryRead`
	*/
	size_t read(scope ubyte[] dst, IOMode mode) @blocking;
	/// ditto
	final void read(scope ubyte[] dst) @blocking { auto n = read(dst, IOMode.all); assert(n == dst.length); }
}


/**
	Interface for all classes implementing writeable streams.
*/
interface OutputStream {
	@safe:

	/** Writes an array of bytes to the stream.
	*/
	size_t write(in ubyte[] bytes, IOMode mode) @blocking;
	/// ditto
	final void write(in ubyte[] bytes) @blocking { auto n = write(bytes, IOMode.all); assert(n == bytes.length); }
	/// ditto
	final void write(in char[] bytes) @blocking { write(cast(const(ubyte)[])bytes); }

	/** Flushes the stream and makes sure that all data is being written to the output device.
	*/
	void flush() @blocking;

	/** Flushes and finalizes the stream.

		Finalize has to be called on certain types of streams. No writes are possible after a
		call to finalize().
	*/
	void finalize() @blocking;
}

/**
	Interface for all classes implementing readable and writable streams.
*/
interface Stream : InputStream, OutputStream {
}


/**
	Interface for streams based on a connection.

	Connection streams are based on streaming socket connections, pipes and similar end-to-end
	streams.

	See_also: `vibe.core.net.TCPConnection`
*/
interface ConnectionStream : Stream {
	@safe:

	/** Determines The current connection status.

		If `connected` is `false`, writing to the connection will trigger an exception. Reading may
		still succeed as long as there is data left in the input buffer. Use `InputStream.empty`
		instead to determine when to stop reading.
	*/
	@property bool connected() const;

	/** Actively closes the connection and frees associated resources.

		Note that close must always be called, even if the remote has already closed the connection.
		Failure to do so will result in resource and memory leakage.

		Closing a connection implies a call to `finalize`, so that it doesn't need to be called
		explicitly (it will be a no-op in that case).
	*/
	void close() @blocking;

	/** Blocks until data becomes available for read.

		The maximum wait time can be customized with the `timeout` parameter. If there is already
		data availabe for read, or if the connection is closed, the function will return immediately
		without blocking.

		Params:
			timeout = Optional timeout, the default value of `Duration.max` waits without a timeout.

		Returns:
			The function will return `true` if data becomes available before the timeout is reached.
			If the connection gets closed, or the timeout gets reached, `false` is returned instead.
	*/
	bool waitForData(Duration timeout = Duration.max) @blocking;
}


/**
	Interface for all streams supporting random access.
*/
interface RandomAccessStream : Stream {
	@safe:

	/// Returns the total size of the file.
	@property ulong size() const nothrow;

	/// Determines if this stream is readable.
	@property bool readable() const nothrow;

	/// Determines if this stream is writable.
	@property bool writable() const nothrow;

	/// Seeks to a specific position in the file if supported by the stream.
	void seek(ulong offset) @blocking;

	/// Returns the current offset of the file pointer
	ulong tell() nothrow;
}


/**
	Stream implementation acting as a sink with no function.

	Any data written to the stream will be ignored and discarded. This stream type is useful if
	the output of a particular stream is not needed but the stream needs to be drained.
*/
final class NullOutputStream : OutputStream {
	size_t write(in ubyte[] bytes, IOMode) { return bytes.length; }
	alias write = OutputStream.write;
	void flush() {}
	void finalize() {}
}


/// Generic storage for types that implement the `InputStream` interface
alias InputStreamProxy = InterfaceProxy!InputStream;
/// Generic storage for types that implement the `OutputStream` interface
alias OutputStreamProxy = InterfaceProxy!OutputStream;
/// Generic storage for types that implement the `Stream` interface
alias StreamProxy = InterfaceProxy!Stream;
/// Generic storage for types that implement the `ConnectionStream` interface
alias ConnectionStreamProxy = InterfaceProxy!ConnectionStream;
/// Generic storage for types that implement the `RandomAccessStream` interface
alias RandomAccessStreamProxy = InterfaceProxy!RandomAccessStream;


/** Tests if the given aggregate type is a valid input stream.

	See_also: `validateInputStream`
*/
enum isInputStream(T) = checkInterfaceConformance!(T, InputStream) is null;

/** Tests if the given aggregate type is a valid output stream.

	See_also: `validateOutputStream`
*/
enum isOutputStream(T) = checkInterfaceConformance!(T, OutputStream) is null;

/** Tests if the given aggregate type is a valid bidirectional stream.

	See_also: `validateStream`
*/
enum isStream(T) = checkInterfaceConformance!(T, Stream) is null;

/** Tests if the given aggregate type is a valid connection stream.

	See_also: `validateConnectionStream`
*/
enum isConnectionStream(T) = checkInterfaceConformance!(T, ConnectionStream) is null;

/** Tests if the given aggregate type is a valid random access stream.

	See_also: `validateRandomAccessStream`
*/
enum isRandomAccessStream(T) = checkInterfaceConformance!(T, RandomAccessStream) is null;

/** Verifies that the given type is a valid input stream.

	A valid input stream type must implement all methods of the `InputStream` interface. Inheriting
	form `InputStream` is not strictly necessary, which also enables struct types to be considered
	as stream implementations.

	See_Also: `isInputStream`
*/
mixin template validateInputStream(T) { import vibe.internal.traits : validateInterfaceConformance; mixin validateInterfaceConformance!(T, .InputStream); }

/** Verifies that the given type is a valid output stream.

	A valid output stream type must implement all methods of the `OutputStream` interface. Inheriting
	form `OutputStream` is not strictly necessary, which also enables struct types to be considered
	as stream implementations.

	See_Also: `isOutputStream`
*/
mixin template validateOutputStream(T) { import vibe.internal.traits : validateInterfaceConformance; mixin validateInterfaceConformance!(T, .OutputStream); }

/** Verifies that the given type is a valid bidirectional stream.

	A valid stream type must implement all methods of the `Stream` interface. Inheriting
	form `Stream` is not strictly necessary, which also enables struct types to be considered
	as stream implementations.

	See_Also: `isStream`
*/
mixin template validateStream(T) { import vibe.internal.traits : validateInterfaceConformance; mixin validateInterfaceConformance!(T, .Stream); }

/** Verifies that the given type is a valid connection stream.

	A valid connection stream type must implement all methods of the `ConnectionStream` interface.
	Inheriting form `ConnectionStream` is not strictly necessary, which also enables struct types
	to be considered as stream implementations.

	See_Also: `isConnectionStream`
*/
mixin template validateConnectionStream(T) { import vibe.internal.traits : validateInterfaceConformance; mixin validateInterfaceConformance!(T, .ConnectionStream); }

/** Verifies that the given type is a valid random access stream.

	A valid random access stream type must implement all methods of the `RandomAccessStream`
	interface. Inheriting form `RandomAccessStream` is not strictly necessary, which also enables
	struct types to be considered as stream implementations.

	See_Also: `isRandomAccessStream`
*/
mixin template validateRandomAccessStream(T) { import vibe.internal.traits : validateInterfaceConformance; mixin validateInterfaceConformance!(T, .RandomAccessStream); }
