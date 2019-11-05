/**
	Efficient generic management of large numbers of timers.
*/
module eventcore.drivers.timer;

import eventcore.driver;
import eventcore.internal.consumablequeue;
import eventcore.internal.dlist;
import eventcore.internal.utils : mallocT, freeT, nogc_assert;


final class LoopTimeoutTimerDriver : EventDriverTimers {
	import std.experimental.allocator.building_blocks.free_list;
	import std.experimental.allocator.building_blocks.region;
	import std.experimental.allocator.mallocator;
	import std.experimental.allocator : dispose, make;
	import std.container.array;
	import std.datetime : Clock;
	import std.range : SortedRange, assumeSorted, take;
	import core.time : hnsecs, Duration;
	import core.memory : GC;

	private {
		static FreeList!(Mallocator, TimerSlot.sizeof) ms_allocator;
		TimerSlot*[TimerID] m_timers;
		StackDList!TimerSlot m_timerQueue;
		TimerID m_lastTimerID;
		ConsumableQueue!(TimerSlot*) m_firedTimers;
	}

	static this()
	{
		ms_allocator.parent = Mallocator.instance;
	}

	this()
	@nogc @safe nothrow {
		m_firedTimers = mallocT!(ConsumableQueue!(TimerSlot*));
	}

	~this()
	@nogc @trusted nothrow {
		try freeT(m_firedTimers);
		catch (Exception e) assert(false, e.msg);
	}

	package @property size_t pendingCount() const @safe nothrow { return m_timerQueue.length; }

	final package Duration getNextTimeout(long stdtime)
	@safe nothrow {
		if (m_timerQueue.empty) return Duration.max;
		return (m_timerQueue.front.timeout - stdtime).hnsecs;
	}

	final package bool process(long stdtime)
	@trusted nothrow {
		assert(m_firedTimers.length == 0);
		if (m_timerQueue.empty) return false;

		TimerSlot ts = void;
		ts.timeout = stdtime+1;
		foreach (tm; m_timerQueue[]) {
			if (tm.timeout > stdtime) break;
			if (tm.repeatDuration > 0) {
				do tm.timeout += tm.repeatDuration;
				while (tm.timeout <= stdtime);
			} else tm.pending = false;
			m_firedTimers.put(tm);
		}

		auto processed_timers = m_firedTimers.consume();

		foreach (tm; processed_timers) {
			m_timerQueue.remove(tm);
			if (tm.repeatDuration > 0)
				enqueueTimer(tm);
		}

		foreach (tm; processed_timers) {
			auto cb = tm.callback;
			tm.callback = null;
			if (cb) {
				cb(tm.id, true);
				releaseRef(tm.id);
			}
		}

		return processed_timers.length > 0;
	}

	final override TimerID create()
	@trusted {
		auto id = cast(TimerID)(++m_lastTimerID);
		TimerSlot* tm;
		try tm = ms_allocator.make!TimerSlot;
		catch (Exception e) return TimerID.invalid;
		assert(tm !is null);
		GC.addRange(tm, TimerSlot.sizeof, typeid(TimerSlot));
		tm.id = id;
		tm.refCount = 1;
		tm.timeout = long.max;
		m_timers[id] = tm;
		return id;
	}

	final override void set(TimerID timer, Duration timeout, Duration repeat)
	@trusted {
		scope (failure) assert(false);
		auto tm = m_timers[timer];
		if (tm.pending) stop(timer);
		tm.timeout = Clock.currStdTime + timeout.total!"hnsecs";
		tm.repeatDuration = repeat.total!"hnsecs";
		tm.pending = true;
		enqueueTimer(tm);
	}

	final override void stop(TimerID timer)
	@trusted {
		import std.algorithm.mutation : swap;

		auto tm = m_timers[timer];
		if (!tm.pending) return;
		TimerCallback2 cb;
		swap(cb, tm.callback);
		if (cb) {
			cb(timer, false);
			releaseRef(timer);
		}
		tm.pending = false;
		m_timerQueue.remove(tm);
	}

	final override bool isPending(TimerID descriptor)
	{
		return m_timers[descriptor].pending;
	}

	final override bool isPeriodic(TimerID descriptor)
	{
		return m_timers[descriptor].repeatDuration > 0;
	}

	final override void wait(TimerID timer, TimerCallback2 callback)
	{
		assert(!m_timers[timer].callback, "Calling wait() on a timer that is already waiting.");
		m_timers[timer].callback = callback;
		addRef(timer);
	}
	alias wait = EventDriverTimers.wait;

	final override void cancelWait(TimerID timer)
	{
		auto pt = m_timers[timer];
		assert(pt.callback);
		pt.callback = null;
		releaseRef(timer);
	}

	final override void addRef(TimerID descriptor)
	{
		assert(descriptor != TimerID.init, "Invalid timer ID.");
		assert(descriptor in m_timers, "Unknown timer ID.");
		if (descriptor !in m_timers) return;

		m_timers[descriptor].refCount++;
	}

	final override bool releaseRef(TimerID descriptor)
	{
		nogc_assert(descriptor != TimerID.init, "Invalid timer ID.");
		nogc_assert((descriptor in m_timers) !is null, "Unknown timer ID.");
		if (descriptor !in m_timers) return true;

		auto tm = m_timers[descriptor];
		tm.refCount--;

		// cancel starved timer waits
		if (tm.callback && tm.refCount == 1 && !tm.pending) {
			debug addRef(descriptor);
			cancelWait(tm.id);
			debug {
				assert(tm.refCount == 1);
				releaseRef(descriptor);
			}
			return false;
		}

		if (!tm.refCount) {
			if (tm.pending) stop(tm.id);
			m_timers.remove(descriptor);
			() @trusted {
				scope (failure) assert(false);
				ms_allocator.dispose(tm);
				GC.removeRange(tm);
			} ();

			return false;
		}

		return true;
	}

	final bool isUnique(TimerID descriptor)
	const {
		if (descriptor == TimerID.init) return false;
		return m_timers[descriptor].refCount == 1;
	}

	protected final override void* rawUserData(TimerID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		TimerSlot* fds = m_timers[descriptor];
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= TimerSlot.userData.length, "Requested user data is too large.");
		if (size > TimerSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return fds.userData.ptr;
	}

	private void enqueueTimer(TimerSlot* tm)
	nothrow {
		TimerSlot* ns;
		foreach_reverse (t; m_timerQueue[])
			if (t.timeout <= tm.timeout) {
				ns = t;
				break;
			}

		if (ns) m_timerQueue.insertAfter(tm, ns);
		else m_timerQueue.insertFront(tm);
	}
}

struct TimerSlot {
	TimerSlot* prev, next;
	TimerID id;
	uint refCount;
	bool pending;
	long timeout; // stdtime
	long repeatDuration;
	TimerCallback2 callback; // TODO: use a list with small-value optimization

	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;
}
