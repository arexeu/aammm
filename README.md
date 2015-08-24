[![Build Status](https://travis-ci.org/arexeu/aammm.svg)](https://travis-ci.org/arexeu/aammm)
# aammm
Associative arrays with manual memory management

All enries and buckets would be dealocated and disposed by internal implementation's destructor.
The destructor is called by garbage collector (by default).

#### Example
```D
    //std.experimental.allocator is included into `aammm`
    import std.experimental.allocator.mallocator;
    import aammm;

    auto a = AA!(string, int, shared Mallocator)(Mallocator.instance);
    a["foo"] = 0;
    a.remove("foo"); //dealocates and disposes the entry
    assert(a == null); // should not crash
```
