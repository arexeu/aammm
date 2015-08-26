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
import std.typecons: Flag;
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
Creates AA with GC-allocated internal implementation.
+/
auto aa(Key, Val, Allocator)(ref Allocator allocator, size_t sz = INIT_NUM_BUCKETS)
{
    return AA!(Key, Val, Allocator)(allocator, sz);
}

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
    disp = dispose entries when `remove` or destructor is called.

See_also: `std.experimental.allocator.typed`
+/
struct AA(Key, Val, Allocator, Flag!"disposeEntries" disp = Flag!"disposeEntries".yes)
{
    import std.experimental.allocator: make, makeArray, dispose;
    //@disable this();

    ///
    @property nothrow @safe @nogc
    bool isInitialized() const
    {
        return impl !is null;
    }

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

    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink("[");
        auto range = byKeyValue();
        if(!range.empty)
        {
            import std.format: formatElement, FormatSpec;
            FormatSpec!char fmt;
            sink.formatElement(range.front.key, fmt);
            sink(" : ");
            sink.formatElement(range.front.value, fmt);
            range.popFront;
            foreach(elem; range)
            {
                sink(", ");
                sink.formatElement(range.front.key, fmt);
                sink(" : ");
                sink.formatElement(range.front.value, fmt);
            }
        }
        sink("]");
    }

    void opIndexAssign(Val val, scope Key key)
    {
        // lazily alloc implementation
        //if (impl is null)
        //    impl = new Impl(INIT_NUM_BUCKETS);

        // get hash and bucket for key
        immutable hash = calcHash(key);

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
        assert(p !is null, (typeof(this)).stringof);
        return *p;
    }

    inout(Val)* opIn_r(in Key key) inout @trusted
    {
        if (empty)
            return null;

        immutable hash = calcHash(key);
        if (auto p = findSlotLookup(hash, key))
            return &p.entry.val;
        return null;
    }

    /++
    Removes entry from table and disposes it.
    +/
    bool remove(in Key key)
    {
        if (empty)
            return false;

        immutable hash = calcHash(key);
        if (auto p = findSlotLookup(hash, key))
        {
            // clear entry
            p.hash = HASH_DELETED;
            static if(disp)
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

    ref Val getOrSet(scope Key key, lazy Val val)
    {
        // lazily alloc implementation
        //if (impl is null)
        //    impl = new Impl(INIT_NUM_BUCKETS);

        // get hash and bucket for key
        immutable hash = calcHash(key);

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

    /**
       Convert the AA to the type of the builtin language AA.
     */
    Val[Key] toBuiltinAA()
    {
        Val[Key] ret;
        foreach(key, value; byKeyValue())
        {
            ret[key] = value;
        }
        return ret;
    }

    /++
    Creates `AA` from builtin associative array.
    +/
    static AA fromBuiltinAA(T : V[K], V, K)(T baa, Allocator allocator, size_t sz = INIT_NUM_BUCKETS)
    {
        auto ret = AA(allocator, sz);
        foreach(key, value; baa)
        {
            ret[key] = value;
        }
        return ret;
    }

private:

    private this(inout(Impl)* impl) inout
    {
        this.impl = impl;
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
            static if(disp)
                foreach(ref b; buckets)
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

    Impl* impl;
    alias impl this;
}

private size_t mix(size_t h) @safe pure nothrow @nogc
{
    // final mix function of MurmurHash2
    static if(size_t.sizeof == 4)
    {
        enum m = 0x5bd1e995;
        h ^= h >> 13;
        h *= m;
        h ^= h >> 15;
    }
    else
    {
        enum ulong m = 0xc6a4a7935bd1e995UL;
        enum int r = 47;
        h ^= h >> r;
        h *= m;
        h ^= h >> r;
    }
    return h;
}

private size_t calcHash(Key)(const ref Key key)
{

    static if(is(Key : AA!(K, V, A), K, V, A)) //object.d workaround
        immutable hash = key.toHash();
    else
        immutable hash = hashOf(key);
    // highest bit is set to distinguish empty/deleted from filled buckets
    return mix(hash) | HASH_FILLED_MARK;
}

unittest
{
    import std.experimental.allocator.mallocator;
    //auto aa = AA!(int, int)(GCAllocator.instance);
    auto aa = aa!(int, int)(Mallocator.instance);
    assert(aa.length == 0);
    aa[0] = 1;
    assert(aa.length == 1 && aa[0] == 1);
    aa[1] = 2;
    assert(aa.length == 2 && aa[1] == 2);

    int[int] rtaa = aa.toBuiltinAA();
    assert(rtaa.length == 2);
    assert(rtaa[0] == 1);
    assert(rtaa[1] == 2);
    rtaa[2] = 3;

    //assert(aa[2] == 3);
}

unittest {
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator.gc_allocator;
    auto aa = makeAA!(int, string)(GCAllocator.instance, Mallocator.instance);
    GCAllocator.instance.disposeAA(aa);
}

//==============================================================================
// Helper functions
//------------------------------------------------------------------------------

private T min(T)(T a, T b) pure nothrow @nogc
{
    return a < b ? a : b;
}

private T max(T)(T a, T b) pure nothrow @nogc
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
//==============================================================================
// Unittests
//------------------------------------------------------------------------------

unittest
{
    import std.experimental.allocator.mallocator;
    auto aa = makeAA!(string, int)(Mallocator.instance, Mallocator.instance);

    assert(aa.keys.length == 0);
    assert(aa.values.length == 0);

    aa["hello"] = 3;
    assert(aa["hello"] == 3);
    aa["hello"]++;
    assert(aa["hello"] == 4);

    assert(aa.length == 1);

    string[] keys = aa.keys;
    assert(keys.length == 1);
    assert(keys[0] == "hello");

    int[] values = aa.values;
    assert(values.length == 1);
    assert(values[0] == 4);

    aa.rehash;
    assert(aa.length == 1);
    assert(aa["hello"] == 4);

    aa["foo"] = 1;

    {
        //toString
        import std.conv: to;
        import std.algorithm.searching: canFind;
        assert([`["hello" : 4, "foo" : 1]`, `["foo" : 1, "hello" : 4]`].canFind(aa.to!string));
    }
    aa["bar"] = 2;
    aa["batz"] = 3;
    assert(aa.keys.length == 4);
    assert(aa.values.length == 4);
    import std.array: array;
    assert(aa.keys == aa.byKey.array);
    assert(aa.values == aa.byValue.array);


    foreach (a; aa.keys)
    {
        assert(a.length != 0);
        assert(a.ptr != null);
    }

    foreach (v; aa.values)
    {
        assert(v != 0);
    }
    GCAllocator.instance.disposeAA(aa);
}

unittest  // Test for Issue 10381
{
    import std.experimental.allocator.mallocator;
    //alias II = int[int];
    //II aa1 = [0 : 1];
    //II aa2 = [0 : 1];
    //II aa3 = [0 : 2];
    alias II = AA!(int, int, shared Mallocator);
    auto aa1 = II(Mallocator.instance); aa1[0] = 1;
    auto aa2 = II(Mallocator.instance); aa2[0] = 1;
    auto aa3 = II(Mallocator.instance); aa3[0] = 2;
    assert(aa1 == aa1); // Passes
    assert(aa1 == aa2); // Passes
    assert(aa1 != aa3); // Passes
    //assert(typeid(II).equals(&aa1, &aa2));
    //assert(!typeid(II).equals(&aa1, &aa3));
}

unittest
{
    import std.experimental.allocator.mallocator;

    //string[int] key1 = [1 : "true", 2 : "false"];
    //string[int] key2 = [1 : "false", 2 : "true"];
    //string[int] key3;

    alias IS = AA!(int, string, shared Mallocator);
    auto key1 = IS(Mallocator.instance);
    auto key2 = IS(Mallocator.instance);
    auto key3 = IS(Mallocator.instance);
    key1[1] = "true";
    key1[2] = "false";
    key2[2] = "true";
    key2[1] = "false";

    // AA lits create a larger hashtable
    //int[string[int]] aa1 = [key1 : 100, key2 : 200, key3 : 300];
    alias ISI = AA!(AA!(int, string, shared Mallocator), int, shared Mallocator);
    auto aa1 = ISI.fromBuiltinAA([key1 : 100, key2 : 200, key3 : 300], Mallocator.instance);

    //// Ensure consistent hash values are computed for key1
    assert((key1 in aa1) !is null);
    // Manually assigning to an empty AA creates a smaller hashtable
    auto aa2 = ISI(Mallocator.instance);
    aa2[key1] = 100;
    aa2[key2] = 200;
    aa2[key3] = 300;

    assert(aa1 == aa2);

    //// Ensure binary-independence of equal hash keys
    auto key2a = IS(Mallocator.instance);
    key2a[1] = "false";
    key2a[2] = "true";

    assert(aa1[key2a] == 200);
}

// Issue 9852
unittest
{
    import std.experimental.allocator.mallocator;

    // Original test case (revised, original assert was wrong)
    //int[string] a;
    auto a = aa!(string, int)(Mallocator.instance);
    a["foo"] = 0;
    a.remove("foo");
    assert(a == null); // should not crash

    auto b = aa!(string, int)(Mallocator.instance);
    //assert(b is null);
    assert(a == b); // should not deref null
    assert(b == a); // ditto

    auto c = aa!(string, int)(Mallocator.instance);
    c["a"] = 1;
    assert(a != c); // comparison with empty non-null AA
    assert(c != a);
    assert(b != c); // comparison with null AA
    assert(c != b);
}

// Bugzilla 14104
unittest
{
    import std.experimental.allocator.mallocator;
    alias K = const(ubyte)*;
    auto aa = aa!(K, size_t)(Mallocator.instance);
    immutable key = cast(K)(cast(uint) uint.max + 1);
    aa[key] = 12;
    assert(key in aa);
}

unittest
{
    import std.experimental.allocator.mallocator;
    auto aa = aa!(int, int)(Mallocator.instance);

    foreach (k, v; aa)
        assert(false);
    foreach (v; aa)
        assert(false);
    assert(aa.byKey.empty);
    assert(aa.byValue.empty);
    assert(aa.byKeyValue.empty);

    size_t n;
    //aa = [0 : 3, 1 : 4, 2 : 5];
    aa[0] = 3;
    aa[1] = 4;
    aa[2] = 5;
    assert(!aa.empty);
    foreach (k, v; aa)
    {
        n += k;
        assert(k >= 0 && k < 3);
        assert(v >= 3 && v < 6);
    }
    assert(n == 3);
    n = 0;

    foreach (v; aa)
    {
        n += v;
        assert(v >= 3 && v < 6);
    }
    assert(n == 12);

    n = 0;
    foreach (k, v; aa)
    {
        ++n;
        break;
    }
    assert(n == 1);

    n = 0;
    foreach (v; aa)
    {
        ++n;
        break;
    }
    assert(n == 1);
}

unittest
{
    import std.experimental.allocator.mallocator;
    auto aa = aa!(int, int)(Mallocator.instance);
    assert(!aa.remove(0));
    aa[0] = 1;
    assert(aa.remove(0));
    assert(!aa.remove(0));
    aa[1] = 2;
    assert(!aa.remove(0));
    assert(aa.remove(1));

    assert(aa.length == 0);
    assert(aa.byKey.empty);
}

// test zero sized value (hashset)
unittest
{
    alias V = void[0];
    import std.experimental.allocator.mallocator;
    auto aa = AA!(int, V, shared Mallocator)(Mallocator.instance);
    aa[0] = V.init;
    assert(aa.length == 1);
    assert(aa.byKey.front == 0);
    assert(aa.byValue.front == V.init);
    aa[1] = V.init;
    assert(aa.length == 2);
    aa[0] = V.init;
    assert(aa.length == 2);
    assert(aa.remove(0));
    aa[0] = V.init;
    assert(aa.length == 2);
    //assert(aa == [0 : V.init, 1 : V.init]);
    assert(aa[0] == V.init);
    assert(aa[1] == V.init);
}

// test tombstone purging
unittest
{
    import std.experimental.allocator.mallocator;
    auto aa = AA!(int, int, shared Mallocator)(Mallocator.instance);
    foreach (i; 0 .. 6)
        aa[i] = i;
    foreach (i; 0 .. 6)
        assert(aa.remove(i));
    foreach (i; 6 .. 10)
        aa[i] = i;
    assert(aa.length == 4);
    foreach (i; 6 .. 10)
        assert(i in aa);
}

//// test postblit for AA literals
//unittest
//{
//    static struct T
//    {
//        static size_t postblit, dtor;
//        this(this)
//        {
//            ++postblit;
//        }

//        ~this()
//        {
//            ++dtor;
//        }
//    }

//    T t;
//    import std.experimental.allocator.mallocator;
//    auto aa1 = AA!(int, T, shared Mallocator)(Mallocator.instance);
//    aa1[0] = t;
//    aa1[1] = t;
//    import std.conv;
//    assert(T.dtor == 0 && T.postblit == 2, T.dtor.to!string~", "~T.postblit.to!string);
//    aa1[0] = t;
//    assert(T.dtor == 1 && T.postblit == 3);

//    T.dtor = 0;
//    T.postblit = 0;

//    //auto aa2 = [0 : t, 1 : t, 0 : t]; // literal with duplicate key => value overwritten
//    auto aa2 = AA!(int, T, shared Mallocator)(Mallocator.instance);
//    aa2[0] = t;
//    aa2[1] = t;
//    aa2[0] = t;

//    assert(T.dtor == 1 && T.postblit == 3);

//    T.dtor = 0;
//    T.postblit = 0;

//    auto aa3 = AA!(T, int, shared Mallocator)(Mallocator.instance);
//    aa3[t] = 0;
//    assert(T.dtor == 0 && T.postblit == 1, T.dtor.to!string~", "~T.postblit.to!string);
//    aa3[t] = 1;
//    assert(T.dtor == 0 && T.postblit == 1);
//    aa3.remove(t);
//    assert(T.dtor == 0 && T.postblit == 1);
//    aa3[t] = 2;
//    assert(T.dtor == 0 && T.postblit == 2);

//    // dtor will be called by GC finalizers
//    aa1 = null;
//    aa2 = null;
//    aa3 = null;
//    //GC.runFinalizers((cast(char*)(&entryDtor))[0 .. 1]);
//    //assert(T.dtor == 6 && T.postblit == 2);
//}
