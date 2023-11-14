# Docstrings

## User API

```
@no_escape([buf=default_buffer()], expr)
```

Record the current state of `buf` (which defaults to the `default_buffer()` if there is only one argument), and then run the code in `expr` and then reset `buf` back to the state it was in before the code ran. This allows us to allocate memory within the `expr` using `@alloc`, and then have those arrays be automatically de-allocated once the expression is over. This is a restrictive but highly efficient form of memory management.

See also `Bumper.checkpoint_save`, and `Bumper.checkpoint_restore!`.

Using `return`, `@goto`, and `@label` are not allowed inside of `@no_escape` block.

Example:

```
function f(x::Vector{Int})
    # Set up a scope where memory may be allocated, and does not escape:
    @no_escape begin
        # Allocate a `PtrArray` from StrideArraysCore.jl using memory from the default buffer.
        y = @alloc(Int, length(x))
        # Now do some stuff with that vector:
        y .= x .+ 1
       sum(y)
    end
end
```

---------------------------------------
```
@alloc(T, n::Int...) -> PtrArray{T, length(n)}
```

This can be used inside a `@no_escape` block to allocate a `PtrArray` whose dimensions are determined by `n`. The memory used to allocate this array will come from the buffer associated with the enclosing `@no_escape` block.

Do not allow any references to this array to escape the enclosing `@no_escape` block, and do not pass these arrays to concurrent tasks unless that task is guaranteed to terminate before the `@no_escape` block ends. Any array allocated in this way which is found outside of its parent `@no_escape` block has undefined contents, and writing to this pointer will have undefined behaviour.

---------------------------------------
```
@alloc_ptr(n::Integer) -> Ptr{Nothing}
```

This can be used inside a `@no_escape` block to allocate a pointer which can hold `n` bytes. The memory used to allocate this pointer will come from the buffer associated with the enclosing `@no_escape` block.

Do not allow any references to this pointer to escape the enclosing `@no_escape` block, and do not pass these pointers to concurrent tasks unless that task is guaranteed to terminate before the `@no_escape` block ends. Any pointer allocated in this way which is found outside of its parent `@no_escape` block has undefined contents, and writing to this pointer will have undefined behaviour.

---------------------------------------
```
default_buffer(::Type{SlabBuffer}) -> SlabBuffer{16_384}
```

Return the current task-local default `SlabBuffer`, if one does not exist in the current task, it will create one automatically. This currently only works with `SlabBuffer{16_384}`, and you cannot adjust the slab size it creates.

```
default_buffer() -> SlabBuffer{16_384}
```

Return the current task-local default `SlabBuffer`, if one does not exist in the current task, it will create one automatically. This currently only works with `SlabBuffer{16_384}`, and you cannot adjust the slab size it creates.

---------------------------------------
```
mutable struct SlabBuffer{SlabSize}
```

A slab-based bump allocator which can dynamically grow to hold an arbitrary amount of memory. Small allocations live within a specific slab of memory, and if that slab fills up, a new slab is allocated and future allocations happen on that slab. Small allocations are stored in slabs of size `SlabSize` bytes, and the list of live slabs are tracked in the `slabs` field. Allocations which are too large to fit into one slab are stored and tracked in the `custom_slabs` field.

`SlabBuffer`s are nearly as fast as stack allocation (typically up to within a couple of nanoseconds) for typical use. One potential performance pitfall is if that `SlabBuffer`'s current position is at the end of a slab, then the next allocation will be slow because it requires a new slab to be created. This means that if you do something like

```
buf = SlabBuffer{N}()
@no_escape buf begin
    x = @alloc(Int8, N-1) # Almost fill up the first slab
    for i in 1:1000
        @no_escape buf begin
            y = @alloc(Int8, 10) # Allocate a new slab because there's no room
            f(y)
        end # At the end of this block, we delete the new slab because it's not needed.
    end
end
```

then the inner loop will run slower than normal because at each iteration, a new slab of size `N` bytes must be freshly allocated. This should be a rare occurance, but is possible to encounter.

Do not manipulate the fields of a SlabBuffer that is in use.

```
SlabBuffer{SlabSize}(;finalize::Bool = true)
```

Create a slab allocator whose slabs are of size `SlabSize`. If you set the `finalize` keyword argument to `false`, then you will need to explicitly call `Bumper.free()` when you are done with a `SlabBuffer`. This is not recommended.

```
SlabBuffer(;finalize::Bool = true)
```

Create a slab allocator whose slabs are of size 16384. If you set the `finalize` keyword argument to `false`, then you will need to explicitly call `Bumper.free()` when you are done with a `SlabBuffer`. This is not recommended.

---------------------------------------
```
Bumper.reset_buffer!(buf=default_buffer())
```

This resets a buffer to its default state, effectively making it like a freshly allocated buffer. This might be necessary to use if you accidentally over-allocate a buffer or screw up its state in some other way.

---------------------------------------
```
with_buffer(f, buf)
```

Execute the function `f()` in a context where `default_buffer()` will return `buf` instead of the normal `default_buffer`. This currently only works with `SlabBuffer{16_384}`, and `AllocBuffer{Vector{UInt8}}`.

Example:

```
julia> let b1 = default_buffer()
           b2 = SlabBuffer()
           with_buffer(b2) do
               @show default_buffer() == b2
           end
           @show default_buffer() == b1
       end
default_buffer() == b2 = true
default_buffer() == b1 = true
true
```

---------------------------------------
## Allocator API

```
Bumper.alloc_ptr!(b, n::Int) -> Ptr{Nothing}
```

Take a pointer which can store at least `n` bytes from the allocator `b`.

---------------------------------------
```
Bumper.alloc!(b, ::Type{T}, n::Int...) -> PtrArray{T, length(n)}
```

Function-based alternative to `@alloc` which allocates onto a specified allocator `b`. You must obey all the rules from `@alloc`, but you can use this outside of the lexical scope of `@no_escape` for specific (but dangerous!) circumstances where you cannot avoid a scope barrier between the two.

---------------------------------------
```
Bumper.checkpoint_save(buf = default_buffer())
```

Returns a checkpoint object `cp` which stores the state of a `buf` at a given point in a program. One can then use `Bumper.checkpoint_restore!(cp)` to later on restore the state of the buffer to it's earlier saved state, undoing any bump allocations which happened in the meantime on that buffer.

Users should prefer to use `@no_escape` instead of `checkpoint_save` and `checkpoint_restore`, which is a safer and more structured way of doing the same thing.

---------------------------------------
```
Bumper.checkpoint_restore!(cp)
```

Restore a buffer (the one used to create `cp`) to the state it was in when the checkpoint was created, undoing any bump allocations which happened in the meantime on that buffer. See also `Bumper.checkpoint_save`

Users should prefer to use `@no_escape` instead of `checkpoint_save` and `checkpoint_restore`, which is a safer and more structured way of doing the same thing.

---------------------------------------
