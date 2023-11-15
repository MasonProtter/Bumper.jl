# Changelog

## Version 0.6.0

+ Removed the package extension which was added in v0.5.1, because we plan on making Bumper.jl
a direct dependancy of StaticTools.jl

## Version 0.5.4

+ Changed the default size heuristics for `SlabBuffer`, the default slab size is now 1 megabyte, and custom slabs 
are now created for allocations which are larger than *half* the slab size, rather than larger than the slab size.
+ Changed the default size heuristic for `AllocBuffer`. `AllocBuffer()` now creates a buffer of 1 megabyte capacity.

## Version 0.5.3

+ Added `@alloc_ptr(n)` which is like `@alloc` except it returns an `n` byte pointer directly instead of an array.

## Version 0.5.2

## Version 0.5.1

+ Added a package extension (only works on julia versions 1.9+) which lets the `AllocBuffer` work under
StaticCompiler.jl, and defines methods like `AllocBuffer(::Type{MallocVector}, n::Int)` and `free(AllocBuffer{<:MallocArray})` for convenience. 

## Version 0.5.0

+ The default allocator is now something known as a *slab* allocator `SlabBuffer`. This comes with a very *slight* performance hit relative to `AllocBuffer`, but the advantage is that it scales very well from handling small allocations all the way up to handling very large allocations. It will only run out of memory when your computer runs out of memory, but it also won't hog memory that's not in use.  It is also be much faster to construct than the old default `AllocBuffer`. 
+ `AllocBuffer` still exists, but now defaults to 128kb of storage instead of 1/8th of your computer's physical memory. This allocator is very slightly faster than the slab allocator, but will error if it runs out of memory. It also is more flexible in the kinds of types it can wrap to use as underlying storage.
+ There is now an API for hooking user-defined allocators into the `@no_escape` and `@alloc` machinery.
+ `alloc(::Type{T}, buffer, dims...)` is now `alloc!(buffer, ::Type{T}, dims...)`
+ `alloc_nothrow` and `@alloc_nothrow` have been removed. People who need this can instead create custom no-throw buffer types.

## Version 0.4.0

+ `alloc` has been replaced with `@alloc`, a macro that can *only* be used inside of a `@no_escape` block, and always
  allocates memory from that specified block. `alloc` still exists, but it is not recommended, and has to be
  explicitly imported to use.
