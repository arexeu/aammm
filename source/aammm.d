/**
 * Implementation of associative arrays.
 *
 * Copyright: Martin Nowak 2015 -.
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors:   Martin Nowak, Ilya Yaroshenko
 */
module aammm;

import core.memory : GC;

import std.experimental.allocator.gc_allocator : GCAllocator;

private
{
    // grow threshold
    enum GROW_NUM = 4;
    enum GROW_DEN = 5;
    // shrink threshold
    enum SHRINK_NUM = 1;
    enum SHRINK_DEN = 8;
    // grow factor
    enum GROW_FAC = 4;
    // growing the AA doubles it's size, so the shrink threshold must be
    // smaller than half the grow threshold to have a hysteresis
    static assert(GROW_FAC * SHRINK_NUM * GROW_DEN < GROW_NUM * SHRINK_DEN);
    // initial load factor (for literals), mean of both thresholds
    enum INIT_NUM = (GROW_DEN * SHRINK_NUM + GROW_NUM * SHRINK_DEN) / 2;
    enum INIT_DEN = SHRINK_DEN * GROW_DEN;

    // magic hash constants to distinguish empty, deleted, and filled buckets
    enum HASH_EMPTY = 0;
    enum HASH_DELETED = 0x1;
    enum HASH_FILLED_MARK = size_t(1) << 8 * size_t.sizeof - 1;
}

enum INIT_NUM_BUCKETS = 8;


/++
Allocates internal AA implementation using `aaalocator`.
Do not use it if you want the GC to remove internal pointer automatically.
+/
auto makeAA(Key, Val, AAAlocator, Allocator)(ref AAAlocator aaalocator, ref Allocator allocator, size_t sz = INIT_NUM_BUCKETS)
{
    import std.experimental.allocator: make;
    alias T = AA!(Key, Val, Allocator);
    T aa = void;
    aa.impl = aaalocator.make!(T.Impl)(allocator, sz);
    return aa;
}

/++
Disposes internal AA implementation using `aaalocator`.
+/
auto disposeAA(AAAlocator, T : AA!(Key, Val, Allocator), Key, Val, Allocator)(ref AAAlocator aaalocator, auto ref T aa)
{
    import std.experimental.allocator: dispose;
    aaalocator.dispose(aa.impl);
    aa.impl = null;
}

/++
Params:
    Key = key type
    Val = value type
    Allocator = allocator type

See_also: `std.experimental.allocator.typed`
+/
struct AA(Key, Val, Allocator = shared GCAllocator)
{
    import std.experimental.allocator: make, makeArray, dispose;
    //@disable this();

    this(ref Allocator allocator, size_t sz = INIT_NUM_BUCKETS)
    {
        impl = new Impl(allocator, sz);
    }

    @property bool empty() const pure nothrow @safe @nogc
    {
        return !length;
    }

    @property size_t length() const pure nothrow @safe @nogc
    {
        return impl is null ? 0 : impl.length;
    }

    typeof(this) rehash()
    {
        if (!empty)
            resize(nextpow2(INIT_DEN * buckets.length / INIT_NUM));
        return this;
    }

    Key[] keys() @property
    {
        if(empty)
            return null;
        auto ret = new typeof(return)(length);
        size_t i;
        foreach (ref b; buckets)
        {
            if (!b.filled)
                continue;
            ret[i++] = b.entry.key;
        }
        assert(i == length);
        return ret;
    }

    Val[] values() @property
    {
        if(empty)
            return null;
        auto ret = new typeof(return)(length);
        size_t i;
        foreach (ref b; buckets)
        {
            if (!b.filled)
                continue;
            ret[i++] = b.entry.val;
        }
        assert(i == length);
        return ret;
    }

    auto byKey() const
    {
        alias R = Range!(const Impl);
        struct ByKey
        {
            R range;
            alias range this;

            const(Key) front() @property
            {
                return range.front.key;
            }
        }
        return ByKey(R(this.impl));
    }

    auto byKey()
    {
        alias R = Range!Impl;
        struct ByKey
        {
            R range;
            alias range this;

            Key front() @property
            {
                return range.front.key;
            }
        }
        return ByKey(R(this.impl));
    }

    auto byValue() const
    {
        alias R = Range!(const Impl);
        struct ByValue
        {
            R range;
            alias range this;

            ref const(Val) front() @property
            {
                return range.front.val;
            }
        }
        return ByValue(R(this.impl));
    }

    auto byValue()
    {
        alias R = Range!Impl;
        struct ByValue
        {
            R range;
            alias range this;

            ref Val front() @property
            {
                return range.front.val;
            }
        }
        return ByValue(R(this.impl));
    }

    auto byKeyValue() const
    {
        alias R = Range!(const Impl);
        struct ByKeyValue
        {
            R range;
            alias range this;

            import std.typecons: Tuple;
            Tuple!(const Key, "key", const Val, "value") front() @property
            {
                return typeof(return)(range.front.key, range.front.val);
            }
        }
        return ByKeyValue(R(this.impl));
    }

    auto byKeyValue() 
    {
        alias R = Range!Impl;
        struct ByKeyValue
        {
            R range;
            alias range this;

            import std.typecons: Tuple;
            Tuple!(Key, "key", Val, "value") front() @property
            {
                return typeof(return)(range.front.key, range.front.val);
            }
        }
        return ByKeyValue(R(this.impl));
    }

    private struct Range(Impl)
    {
        Impl* impl;
        size_t idx;

        this(Impl* _impl)
        {
            impl = _impl;
            if(impl !is null)
            {
                if(impl.length)
                {
                    while(!impl.buckets[idx].filled)
                        ++idx;
                }
                else
                {
                    idx = impl.buckets.length;
                }
            }
        }
        
        bool empty() @property
        {
            return impl is null ? true : impl.buckets.length <= idx;
        }

        auto ref front() @property
        {
            assert(!empty);
            return *impl.buckets[idx].entry;
        }

        void popFront()
        {
            assert(!empty);
            for (++idx; idx < impl.buckets.length; ++idx)
            {
                if (impl.buckets[idx].filled)
                    break;
            }
        }
    }

    size_t toHash() const
    {
        if (empty)
            return 0;

        size_t h;
        foreach (b; buckets)
        {
            if (!b.filled)
                continue;
            static if(is(Key : AA!(K, V, A), K, V, A)) //object.d workaround
                size_t[2] h2 = [b.hash, b.entry.key.toHash];
            else
                size_t[2] h2 = [b.hash, hashOf(b.entry.key)];
            // use XOR here, so that hash is independent of element order
            h ^= hashOf(h2.ptr, h2.length * h2[0].sizeof);
        }
        return h;
    }

    bool opEquals(in AA aa) const
    {
        if (this.impl is aa.impl)
            return true;
        immutable len = length;
        if (len != aa.length)
            return false;

        if (!len) // both empty
            return true;

        // compare the entries
        foreach(b1; this.buckets)
        {
            if (!b1.filled)
                continue;
            auto pb2 = aa.findSlotLookup(b1.hash, b1.entry.key);
            if (pb2 is null || pb2.entry.val != b1.entry.val)
                return false;
        }
        return true;
    }

    bool opEquals(typeof(null))
    {
        return empty;
    }

    void opIndexAssign(Val val, in Key key)
    {
        // lazily alloc implementation
        //if (impl is null)
        //    impl = new Impl(INIT_NUM_BUCKETS);

        // get hash and bucket for key
        immutable hash = hashOf(key) | HASH_FILLED_MARK;

        // found a value => assignment
        if (auto p = impl.findSlotLookup(hash, key))
        {
            p.entry.val = val;
            return;
        }

        auto p = findSlotInsert(hash);
        if (p.deleted)
            --deleted;
        // check load factor and possibly grow
        else if (++used * GROW_DEN > dim * GROW_NUM)
        {
            grow();
            p = findSlotInsert(hash);
            assert(p.empty);
        }

        // update search cache and allocate entry
        firstUsed = min(firstUsed, cast(size_t)(p - buckets.ptr));
        p.hash = hash;
        p.entry = allocator.make!(Impl.Entry)(key, val); // TODO: move
        return;
    }

    ref inout(Val) opIndex(in Key key) inout @trusted
    {
        auto p = opIn_r(key);
        assert(p !is null);
        return *p;
    }

    inout(Val)* opIn_r(in Key key) inout @trusted
    {
        if (empty)
            return null;

        immutable hash = hashOf(key) | HASH_FILLED_MARK;
        if (auto p = findSlotLookup(hash, key))
            return &p.entry.val;
        return null;
    }

    bool remove(in Key key)
    {
        if (empty)
            return false;

        immutable hash = hashOf(key) | HASH_FILLED_MARK;
        if (auto p = findSlotLookup(hash, key))
        {
            // clear entry
            p.hash = HASH_DELETED;
            allocator.dispose(p.entry);
            p.entry = null;

            ++deleted;
            if (length * SHRINK_DEN < dim * SHRINK_NUM)
                shrink();

            return true;
        }
        return false;
    }

    ref Allocator allocator() pure nothrow @nogc { return impl.allocator; }

    Val get(in Key key, lazy Val val)
    {
        auto p = opIn_r(key);
        return p is null ? val : *p;
    }

    ref Val getOrSet(in Key key, lazy Val val)
    {
        // lazily alloc implementation
        //if (impl is null)
        //    impl = new Impl(INIT_NUM_BUCKETS);

        // get hash and bucket for key
        immutable hash = hashOf(key) | HASH_FILLED_MARK;

        // found a value => assignment
        if (auto p = impl.findSlotLookup(hash, key))
            return p.entry.val;

        auto p = findSlotInsert(hash);
        if (p.deleted)
            --deleted;
        // check load factor and possibly grow
        else if (++used * GROW_DEN > dim * GROW_NUM)
        {
            grow();
            p = findSlotInsert(hash);
            assert(p.empty);
        }

        // update search cache and allocate entry
        firstUsed = min(firstUsed, cast(size_t)(p - buckets.ptr));
        p.hash = hash;
        p.entry = allocator.make!(Impl.Entry)(key, val);
        return p.entry.val;
    }

    /// foreach opApply over all values
    int opApply(int delegate(Val) dg)
    {
        if (empty)
            return 0;

        foreach (ref b; buckets)
        {
            if (!b.filled)
                continue;
            if (auto res = dg(b.entry.val))
                return res;
        }
        return 0;
    }

    /// foreach opApply over all key/value pairs
    int opApply(int delegate(Key, ref Val) dg)
    {
        if (empty)
            return 0;
        foreach (ref b; buckets)
        {
            if (!b.filled)
                continue;
            if (auto res = dg(b.entry.key, b.entry.val))
                return res;
        }
        return 0;
    }

    ///**
    //   Convert the AA to the type of the builtin language AA.
    // */
    //Val[Key] toBuiltinAA() pure nothrow
    //{
    //    return cast(Val[Key]) _aaFromCoreAA(impl, rtInterface);
    //}

private:

    private this(inout(Impl)* impl) inout
    {
        this.impl = impl;
    }

    ref Val getLValue(in Key key)
    {
        // lazily alloc implementation
        //if (impl is null)
        //    impl = new Impl(INIT_NUM_BUCKETS);

        // get hash and bucket for key
        immutable hash = hashOf(key) | HASH_FILLED_MARK;

        // found a value => assignment
        if (auto p = impl.findSlotLookup(hash, key))
            return p.entry.val;

        auto p = findSlotInsert(hash);
        if (p.deleted)
            --deleted;
        // check load factor and possibly grow
        else if (++used * GROW_DEN > dim * GROW_NUM)
        {
            grow();
            p = findSlotInsert(hash);
            assert(p.empty);
        }

        // update search cache and allocate entry
        firstUsed = min(firstUsed, cast(size_t)(p - buckets.ptr));
        p.hash = hash;
        p.entry = allocator.make!(Impl.Entry)(key); // TODO: move
        return p.entry.val;
    }

    static struct Impl
    {
        static if(is(Allocator == struct))
        {
            Allocator* _allocator;
            ref Allocator allocator() pure nothrow @nogc { return *_allocator; }
            this(ref Allocator allocator, size_t sz = INIT_NUM_BUCKETS)
            {
                this._allocator = &allocator;
                buckets = allocBuckets(sz);
            }
        }
        else
        {
            Allocator allocator;
            this(Allocator allocator, size_t sz = INIT_NUM_BUCKETS)
            {
                this.allocator = allocator;
                buckets = allocBuckets(sz);
            }
        }

        ~this()
        {
            foreach(b; buckets)
                if(b.filled)
                    allocator.dispose(b.entry);
            allocator.dispose(buckets);
        }

        @property size_t length() const pure nothrow @nogc
        {
            assert(used >= deleted);
            return used - deleted;
        }

        @property size_t dim() const pure nothrow @nogc
        {
            return buckets.length;
        }

        @property size_t mask() const pure nothrow @nogc
        {
            return dim - 1;
        }

        // find the first slot to insert a value with hash
        inout(Bucket)* findSlotInsert(size_t hash) inout pure nothrow @nogc
        {
            for (size_t i = hash & mask, j = 1;; ++j)
            {
                if (!buckets[i].filled)
                    return &buckets[i];
                i = (i + j) & mask;
            }
        }

        // lookup a key
        inout(Bucket)* findSlotLookup(size_t hash, in Key key) inout
        {
            for (size_t i = hash & mask, j = 1;; ++j)
            {
                if (buckets[i].hash == hash && key == buckets[i].entry.key)
                    return &buckets[i];
                else if (buckets[i].empty)
                    return null;
                i = (i + j) & mask;
            }
        }

        void grow()
        {
            // If there are so many deleted entries, that growing would push us
            // below the shrink threshold, we just purge deleted entries instead.
            if (length * SHRINK_DEN < GROW_FAC * dim * SHRINK_NUM)
                resize(dim);
            else
                resize(GROW_FAC * dim);
        }

        void shrink()
        {
            if (dim > INIT_NUM_BUCKETS)
                resize(dim / GROW_FAC);
        }

        void resize(size_t ndim)
        {
            auto obuckets = buckets;
            buckets = allocBuckets(ndim);

            foreach (ref b; obuckets)
                if (b.filled)
                    *findSlotInsert(b.hash) = b;

            firstUsed = 0;
            used -= deleted;
            deleted = 0;
            allocator.dispose(obuckets); // safe to free b/c impossible to reference
        }

        static struct Entry
        {
            Key key;
            Val val;
        }

        static struct Bucket
        {
            size_t hash;
            Entry* entry;

            @property bool empty() const
            {
                return hash == HASH_EMPTY;
            }

            @property bool deleted() const
            {
                return hash == HASH_DELETED;
            }

            @property bool filled() const
            {
                return cast(ptrdiff_t) hash < 0;
            }
        }

        Bucket[] allocBuckets(size_t dim)
        {
            //enum attr = GC.BlkAttr.NO_INTERIOR;
            //immutable sz = dim * Bucket.sizeof;
            //return (cast(Bucket*) GC.calloc(sz, attr))[0 .. dim];
            return allocator.makeArray!Bucket(dim);
        }

        Bucket[] buckets;
        size_t used;
        size_t deleted;
        size_t firstUsed;
    }

    //RTInterface* rtInterface()() pure nothrow @nogc
    //{
    //    static size_t aaLen(in void* pimpl) pure nothrow @nogc
    //    {
    //        auto aa = const(AA)(cast(const(Impl)*)pimpl);
    //        return aa.length;
    //    }

    //    static void* aaGetY(void** pimpl, in void* pkey)
    //    {
    //        auto aa = AA(cast(Impl*)*pimpl);
    //        auto res = &aa.getLValue(*cast(const(Key*)) pkey);
    //        *pimpl = aa.impl; // might have changed
    //        return res;
    //    }

    //    static inout(void)* aaInX(inout void* pimpl, in void* pkey)
    //    {
    //        auto aa = inout(AA)(cast(inout(Impl)*)pimpl);
    //        return aa.opIn_r(*cast(const(Key*)) pkey);
    //    }

    //    static bool aaDelX(void* pimpl, in void* pkey)
    //    {
    //        auto aa = AA(cast(Impl*)pimpl);
    //        return aa.remove(*cast(const(Key*)) pkey);
    //    }

    //    static immutable vtbl = RTInterface(&aaLen, &aaGetY, &aaInX, &aaDelX);
    //    return cast(RTInterface*)&vtbl;
    //}

    Impl* impl;
    alias impl this;
}

//package extern (C) void* _aaFromCoreAA(void* impl, RTInterface* rtIntf) pure nothrow;

private:

//struct RTInterface
//{
//    alias AA = void*;

//    size_t function(in AA aa) pure nothrow @nogc len;
//    void* function(AA* aa, in void* pkey) getY;
//    inout(void)* function(inout AA aa, in void* pkey) inX;
//    bool function(AA aa, in void* pkey) delX;
//}

unittest
{
    import std.experimental.allocator.mallocator;
    //auto aa = AA!(int, int)(GCAllocator.instance);
    auto aa = AA!(int, int, shared Mallocator)(Mallocator.instance);
    assert(aa.length == 0);
    aa[0] = 1;
    assert(aa.length == 1 && aa[0] == 1);
    aa[1] = 2;
    assert(aa.length == 2 && aa[1] == 2);
    import core.stdc.stdio;

    //int[int] rtaa = aa.toBuiltinAA();
    //assert(rtaa.length == 2);
    //puts("length");
    //assert(rtaa[0] == 1);
    //assert(rtaa[1] == 2);
    //rtaa[2] = 3;

    //assert(aa[2] == 3);
}


//==============================================================================
// Helper functions
//------------------------------------------------------------------------------

T min(T)(T a, T b) pure nothrow @nogc
{
    return a < b ? a : b;
}

T max(T)(T a, T b) pure nothrow @nogc
{
    return b < a ? a : b;
}

private size_t nextpow2(in size_t n) pure nothrow @nogc
{
    import core.bitop : bsr;

    if (!n)
        return 1;

    const isPowerOf2 = !((n - 1) & n);
    return 1 << (bsr(n) + !isPowerOf2);
}

pure nothrow @nogc unittest
{
    //                            0, 1, 2, 3, 4, 5, 6, 7, 8,  9
    foreach (const n, const pow2; [1, 1, 2, 4, 4, 8, 8, 8, 8, 16])
        assert(nextpow2(n) == pow2);
}
