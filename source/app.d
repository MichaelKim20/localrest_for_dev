module test;

import vibe.data.json;
import std.stdio;
import core.sync.mutex;
import core.thread;
import std.datetime.systime;
import std.variant;

import core.atomic;
class Michael
{
    private string name;

    this (string name)
    {
        this.name = name;
    }
    mixin(q{
        public string getName ()
        {
            return this.name;
        }
    });
}

///
private struct List (T)
{
    struct Range
    {
        import std.exception : enforce;

        @property bool empty () const
        {
            return !m_prev.next;
        }

        @property ref T front ()
        {
            enforce(m_prev.next, "invalid list node");
            return m_prev.next.val;
        }

        @property void front (T val)
        {
            enforce(m_prev.next, "invalid list node");
            m_prev.next.val = val;
        }

        void popFront ()
        {
            enforce(m_prev.next, "invalid list node");
            m_prev = m_prev.next;
        }

        private this (Node* p)
        {
            m_prev = p;
        }

        private Node* m_prev;
    }

    void put (T val)
    {
        put(newNode(val));
    }

    void put (ref List!(T) rhs)
    {
        if (!rhs.empty)
        {
            put(rhs.m_first);
            while (m_last.next !is null)
            {
                m_last = m_last.next;
                m_count++;
            }
            rhs.m_first = null;
            rhs.m_last = null;
            rhs.m_count = 0;
        }
    }

    Range opSlice ()
    {
        return Range(cast(Node*)&m_first);
    }

    void removeAt (Range r)
    {
        import std.exception : enforce;

        assert(m_count);
        Node* n = r.m_prev;
        enforce(n && n.next, "attempting to remove invalid list node");

        if (m_last is m_first)
            m_last = null;
        else if (m_last is n.next)
            m_last = n; // nocoverage
        Node* to_free = n.next;
        n.next = n.next.next;
        freeNode(to_free);
        m_count--;
    }

    @property size_t length ()
    {
        return m_count;
    }

    void clear ()
    {
        m_first = m_last = null;
        m_count = 0;
    }

    @property bool empty ()
    {
        return m_first is null;
    }

private:
    struct Node
    {
        Node* next;
        T val;

        this(T v)
        {
            val = v;
        }
    }

    static shared struct SpinLock
    {
        void lock ()
        {
            while (!cas(&locked, false, true))
            {
                Thread.yield();
            }
        }
        void unlock ()
        {
            atomicStore!(MemoryOrder.rel)(locked, false);
        }
        bool locked;
    }

    static shared SpinLock sm_lock;
    static shared Node* sm_head;

    Node* newNode (T v)
    {
        Node* n;
        {
            sm_lock.lock();
            scope (exit) sm_lock.unlock();

            if (sm_head)
            {
                n = cast(Node*) sm_head;
                sm_head = sm_head.next;
            }
        }
        if (n)
        {
            import std.conv : emplace;
            emplace!Node(n, v);
        }
        else
        {
            n = new Node(v);
        }
        return n;
    }

    void freeNode (Node* n)
    {
        // destroy val to free any owned GC memory
        destroy(n.val);

        sm_lock.lock();
        scope (exit) sm_lock.unlock();

        auto sn = cast(shared(Node)*) n;
        sn.next = sm_head;
        sm_head = sn;
    }

    void put (Node* n)
    {
        m_count++;
        if (!empty)
        {
            m_last.next = n;
            m_last = n;
            return;
        }
        m_first = n;
        m_last = n;
    }

    Node* m_first;
    Node* m_last;
    size_t m_count;
}

alias ListT = List!(int);

bool onStandardMsg (int msg)
{
    if ((msg == 5))// || (msg == 6) || (msg == 7))
    {
        return true;
    }
    return false;
}

bool scan (ref ListT list)
{
    for (auto range = list[]; !range.empty;)
    {
        // Only the message handler will throw, so if this occurs
        // we can be certain that the message was handled.
        scope (failure)
            list.removeAt(range);

        if (onStandardMsg(range.front))
        {
            list.removeAt(range);
            return true;
        }
        range.popFront();
        continue;
    }
    return false;
}

void mtest()
{
    auto m = new Michael("Kim");
    writeln(m.getName());
}

void main()
{
    //mtest();
    ListT msgs;
    //msgs.put(1);
    //msgs.put(2);
    //msgs.put(3);
    //msgs.put(4);
   // msgs.put(5);
    //msgs.put(6);
    //msgs.put(7);
    //msgs.put(8);

    msgs.put(6);
    msgs.put(5);
    writeln(msgs[]);
    scan(msgs);
    writeln(msgs[]);
    scan(msgs);
    writeln(msgs[]);

}
