/** Implements a thread-safe, typed producer-consumer queue.

	Copyright: © 2017-2019 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.channel;

import vibe.core.sync : TaskCondition;
import vibe.internal.array : FixedRingBuffer;

import std.algorithm.mutation : move, swap;
import std.exception : enforce;
import core.sync.mutex;

// multiple producers allowed, multiple consumers allowed - Q: should this be restricted to allow higher performance? maybe configurable?
// currently always buffered - TODO: implement blocking non-buffered mode
// TODO: implement a multi-channel wait, e.g.
// TaggedAlgebraic!(...) consumeAny(ch1, ch2, ch3); - requires a waitOnMultipleConditions function

// NOTE: not using synchronized (m_mutex) because it is not nothrow


/** Creates a new channel suitable for cross-task and cross-thread communication.
*/
Channel!(T, buffer_size) createChannel(T, size_t buffer_size = 100)()
{
	Channel!(T, buffer_size) ret;
	ret.m_impl = new shared ChannelImpl!(T, buffer_size);
	return ret;
}


/** Thread-safe typed data channel implementation.

	The implementation supports multiple-reader-multiple-writer operation across
	multiple tasks in multiple threads.
*/
struct Channel(T, size_t buffer_size = 100) {
	enum bufferSize = buffer_size;

	private shared ChannelImpl!(T, buffer_size) m_impl;

	/** Determines whether there is more data to read.

		This property is empty $(I iff) no more elements are in the internal
		buffer and `close()` has been called. Once the channel is empty,
		subsequent calls to `consumeOne` or `consumeAll` will throw an
		exception.

		Note that relying on the return value to determine whether another
		element can be read is only safe in a single-reader scenario. Use
		`tryConsumeOne` in a multiple-reader scenario instead.
	*/
	@property bool empty() { return m_impl.empty; }
	/// ditto
	@property bool empty() shared { return m_impl.empty; }

	/** Returns the current count of items in the buffer.

		This function is useful for diagnostic purposes.
	*/
	@property size_t bufferFill() { return m_impl.bufferFill; }
	/// ditto
	@property size_t bufferFill() shared { return m_impl.bufferFill; }

	/** Closes the channel.

		A closed channel does not accept any new items enqueued using `put` and
		causes `empty` to return `fals` as soon as all preceeding elements have
		been consumed.
	*/
	void close() { m_impl.close(); }
	/// ditto
	void close() shared { m_impl.close(); }

	/** Consumes a single element off the queue.

		This function will block if no elements are available. If the `empty`
		property is `true`, an exception will be thrown.
	*/
	T consumeOne() { return m_impl.consumeOne(); }
	/// ditto
	T consumeOne() shared { return m_impl.consumeOne(); }

	/** Attempts to consume a single element.

		If no more elements are available and the channel has been closed,
		`false` is returned and `dst` is left untouched.
	*/
	bool tryConsumeOne(ref T dst) { return m_impl.tryConsumeOne(dst); }
	/// ditto
	bool tryConsumeOne(ref T dst) shared { return m_impl.tryConsumeOne(dst); }

	/** Attempts to consume all elements currently in the queue.

		This function will block if no elements are available. Once at least one
		element is available, the contents of `dst` will be replaced with all
		available elements.

		If the `empty` property is or becomes `true` before data becomes
		avaiable, `dst` will be left untouched and `false` is returned.
	*/
	bool consumeAll(ref FixedRingBuffer!(T, buffer_size) dst)
		in { assert(dst.empty); }
		body { return m_impl.consumeAll(dst); }
	/// ditto
	bool consumeAll(ref FixedRingBuffer!(T, buffer_size) dst) shared
		in { assert(dst.empty); }
		body { return m_impl.consumeAll(dst); }

	/** Enqueues an element.

		This function may block the the event that the internal buffer is full.
	*/
	void put(T item) { m_impl.put(item.move); }
	/// ditto
	void put(T item) shared { m_impl.put(item.move); }
}


private final class ChannelImpl(T, size_t buffer_size) {
	import vibe.core.concurrency : isWeaklyIsolated;
	static assert(isWeaklyIsolated!T, "Channel data type "~T.stringof~" is not safe to pass between threads.");

	private {
		Mutex m_mutex;
		TaskCondition m_condition;
		FixedRingBuffer!(T, buffer_size) m_items;
		bool m_closed = false;
	}

	this()
	shared @trusted {
		m_mutex = cast(shared)new Mutex;
		m_condition = cast(shared)new TaskCondition(cast(Mutex)m_mutex);
	}

	@property bool empty()
	shared nothrow {
		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			auto thisus = () @trusted { return cast(ChannelImpl)this; } ();
			return thisus.m_closed && thisus.m_items.empty;
		}
	}

	@property size_t bufferFill()
	shared nothrow {
		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			auto thisus = () @trusted { return cast(ChannelImpl)this; } ();
			return thisus.m_items.length;
		}
	}

	void close()
	shared nothrow {
		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			auto thisus = () @trusted { return cast(ChannelImpl)this; } ();
			thisus.m_closed = true;
			thisus.m_condition.notifyAll();
		}
	}

	bool tryConsumeOne(ref T dst)
	shared nothrow {
		auto thisus = () @trusted { return cast(ChannelImpl)this; } ();
		bool was_full = false;

		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			while (thisus.m_items.empty) {
				if (m_closed) return false;
				thisus.m_condition.wait();
			}
			was_full = thisus.m_items.full;
			move(thisus.m_items.front, dst);
			thisus.m_items.popFront();
		}

		if (was_full) thisus.m_condition.notify();

		return true;
	}

	T consumeOne()
	shared {
		auto thisus = () @trusted { return cast(ChannelImpl)this; } ();
		T ret;
		bool was_full = false;

		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			while (thisus.m_items.empty) {
				if (m_closed) throw new Exception("Attempt to consume from an empty channel.");
				thisus.m_condition.wait();
			}
			was_full = thisus.m_items.full;
			move(thisus.m_items.front, ret);
			thisus.m_items.popFront();
		}

		if (was_full) thisus.m_condition.notify();

		return ret.move;
	}

	bool consumeAll(ref FixedRingBuffer!(T, buffer_size) dst)
	shared nothrow {
		auto thisus = () @trusted { return cast(ChannelImpl)this; } ();
		bool was_full = false;

		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			while (thisus.m_items.empty) {
				if (m_closed) return false;
				thisus.m_condition.wait();
			}

			was_full = thisus.m_items.full;
			swap(thisus.m_items, dst);
		}

		if (was_full) thisus.m_condition.notify();

		return true;
	}

	void put(T item)
	shared {
		auto thisus = () @trusted { return cast(ChannelImpl)this; } ();
		bool need_notify = false;

		{
			m_mutex.lock_nothrow();
			scope (exit) m_mutex.unlock_nothrow();

			enforce(!m_closed, "Sending on closed channel.");
			while (thisus.m_items.full)
				thisus.m_condition.wait();
			need_notify = thisus.m_items.empty;
			thisus.m_items.put(item.move);
		}

		if (need_notify) thisus.m_condition.notify();
	}
}

@safe unittest { // test basic operation and non-copyable struct compatiblity
	static struct S {
		int i;
		@disable this(this);
	}

	auto ch = createChannel!S;
	ch.put(S(1));
	assert(ch.consumeOne().i == 1);
	ch.put(S(4));
	ch.put(S(5));
	{
		FixedRingBuffer!(S, 100) buf;
		ch.consumeAll(buf);
		assert(buf.length == 2);
		assert(buf[0].i == 4);
		assert(buf[1].i == 5);
	}
	ch.put(S(2));
	assert(!ch.empty);
	ch.close();
	assert(!ch.empty);
	S v;
	assert(ch.tryConsumeOne(v));
	assert(v.i == 2);
	assert(ch.empty);
	assert(!ch.tryConsumeOne(v));
}

@safe unittest { // make sure shared(Channel!T) can also be used
	shared ch = createChannel!int;
	ch.put(1);
	assert(!ch.empty);
	assert(ch.consumeOne == 1);
	ch.close();
	assert(ch.empty);
}

@safe unittest { // ensure nothrow'ness for throwing struct
	static struct S {
		this(this) { throw new Exception("meh!"); }
	}
	auto ch = createChannel!S;
	ch.put(S.init);
	ch.put(S.init);

	S s;
	FixedRingBuffer!(S, 100, true) sb;

	() nothrow {
		assert(ch.tryConsumeOne(s));
		assert(ch.consumeAll(sb));
		assert(sb.length == 1);
		ch.close();
		assert(ch.empty);
	} ();
}
