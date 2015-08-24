[![Build Status](https://travis-ci.org/arexeu/aammm.svg)](https://travis-ci.org/arexeu/aammm)
# aammm
Associative arrays with manual memory management

#### Example
```D
    //std.experimental.allocator is included into `aammm`
    import std.experimental.allocator.mallocator;
    import aammm;

    auto a = AA!(string, int, shared Mallocator)(Mallocator.instance);
    a["foo"] = 0;
    a.remove("foo"); //dealocates and dispose entry
    assert(a == null); // should not crash
```
