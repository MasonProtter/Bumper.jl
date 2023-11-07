module Bumper

export SlabBuffer, AllocBuffer, @alloc, default_buffer, @no_escape, with_buffer
using StrideArraysCore
using mimalloc_jll

malloc(n::Int) = @ccall mimalloc_jll.libmimalloc.malloc(n::Int)::Ptr{Cvoid}
free(p::Ptr{Cvoid}) = @ccall mimalloc_jll.libmimalloc.free(p::Ptr{Cvoid})::Nothing


"""
    AllocBuffer

This is a single bump allocator that could be used to store some memory of type `StorageType`.
Do not manually manipulate the fields of an AllocBuffer that is in use.
"""
mutable struct AllocBuffer{Store}
    buf::Store
    offset::UInt
end

"""
    @no_escape([buf=default_buffer()], expr)

Record the current state of `buf` (which defaults to the `default_buffer()` if there is only one argument), and then run
the code in `expr` and then reset `buf` back to the state it was in before the code ran. This allows us to allocate memory
within the `expr` using `@alloc`, and then have those arrays be automatically de-allocated once the expression is over. This
is a restrictive but highly efficient form of memory management.

See also `Bumper.checkpoint_save`, and `Bumper.checkpoint_restore!`.

Using `return`, `@goto`, and `@label` are not allowed inside of `@no_escape` block.

Example:

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
"""
macro no_escape end

"""
    @alloc(T, n::Int...) -> PtrArray{T, length(n)}

This can only be used inside a `@no_escape` block to allocate a `PtrArray` whose dimensions
are determined by `n`. The memory used to allocate this array will come from the buffer
associated with the enclosing `@no_escape` block.

Do not allow any references to these arrays to escape the enclosing `@no_escape` block, and do
not pass these arrays to concurrent tasks unless that task is guaranteed to terminate before the
`@no_escape` block ends. Any array allocated in this way which is found outside of it's parent
`@no_escape` block has undefined contents.
"""
macro alloc(args...)
    error("The @alloc macro may only be used inside of a @no_escape block.")
end

"""
    @alloc_nothrow(T, n::Int...) -> PtrArray{T, length(n)}

Just like `@alloc` but it won't throw an error if the size you requested is too big. Don't use this
unless you're doing something weird like using StaticCompiler.jl and can't handle errors.
"""
macro alloc_nothrow(args...)
    error("The @alloc macro may only be used inside of a @no_escape block.")
end

"""
    Bumper.alloc_nothrow(T, buf, n::Int...) -> PtrArray{T, length(n)}

Just like `Bumper.alloc` but it won't throw an error if the size you requested is too big. Don't use this
unless you're doing something weird like using StaticCompiler.jl and can't handle errors.
"""
function alloc_nothrow end

"""
    default_buffer() -> AllocBuffer{Vector{UInt8}}

Return the current task-local default buffer, if one does not exist in the current task, it will
create one.
"""
function default_buffer end

"""
    Bumper.alloc(T, b::AllocBuffer, n::Int...) -> PtrArray{T, length(n)}

Function-based alternative to `@alloc` which allocates onto a specified `AllocBuffer`.
You must obey all the rules from `@alloc`, but you can use this outside of the lexical
scope of `@no_escape` for specific (but dangerous!) circumstances where you cannot avoid
a scope barrier between the two.
"""
function alloc end

function alloc_ptr! end

"""
    with_buffer(f, buf::AllocBuffer{Vector{UInt8}})

Execute the function `f()` in a context where `default_buffer()` will return `buf` instead of the normal `default_buffer`. This currently only works with `AllocBuffer{Vector{UInt8}}`.

Buffers created in tasks spawned within `f` will inherit the size of `buf` (but not its exact state and contents).

Example:

    julia> let b1 = default_buffer()
               b2 = AllocBuffer(10000)
               with_buffer(b2) do
                   @show default_buffer() == b2
               end
               @show default_buffer() == b1
           end
    default_buffer() == b2 = true
    default_buffer() == b1 = true
    true
"""
function with_buffer end

"""
    Bumper.set_default_buffer_size!(n::Int)

Change the size (in number of bytes) of the default buffer. This should not be done
while any buffers are in use, as their contents may become undefined.
"""
function set_default_buffer_size! end


allow_ptr_array_to_escape() = false

"""
    Bumper.reset_buffer!(buf::AllocBuffer=default_buffer())

This resets an AllocBuffer's offset to zero, effectively making it like a freshly allocated buffer. This might be
necessary to use if you accidentally over-allocate a buffer.
"""
function reset_buffer! end


struct Checkpoint{Buffer, Offset}
    buf::Buffer
    offset::Offset
end

"""
    Bumper.checkpoint_save(buf::AllocBuffer = default_buffer()) -> Checkpoint

Returns a `Checkpoint` object which stores the state of an `AllocBuffer` at a given point in
a program. One can then use `Bumper.checkpoint_restore!(cp::Checkpoint)` to later on restore
the state of the buffer to it's earlier saved state, undoing any bump allocations which
happened in the meantime on that buffer.

Users should prefer to use `@no_escape` instead of `checkpoint_save` and `checkpoint_restore`,
which is a safer and more structured way of doing the same thing.
"""
function checkpoint_save end

"""
    Bumper.checkpoint_restore!(cp::Checkpoint)

Restore a buffer (the one used to create the checkpoint) to the state it was in when the
checkpoint was created, undoing any bump allocations which happened in the meantime on that
buffer. See also `Bumper.checkpoint_save`

Users should prefer to use `@no_escape` instead of `checkpoint_save` and `checkpoint_restore`,
which is a safer and more structured way of doing the same thing.
"""
function checkpoint_restore! end

# mutable struct MemSlab{Size}
#     data::NTuple{Size, UInt8}
#     MemSlab{Size}() where {Size} = new{convert(Int, Size)}()
# end
mutable struct SlabBuffer{SlabSize}
    current    ::Ptr{Cvoid}
    offset     ::Int
    slabs      ::Vector{Ptr{Cvoid}}
    outline_buf::Vector{Ptr{Cvoid}} #Vector{Vector{UInt8}}
    function SlabBuffer{_SlabSize}() where {_SlabSize}
        SlabSize = convert(Int, _SlabSize)
        
        first_slab  = malloc(SlabSize) #MemSlab{SlabSize}()
        current     = first_slab#pointer(first_slab)
        slabs       = [first_slab]
        outline_buf = Vector{UInt8}[]
        buf = new{SlabSize}(current, 0, slabs, outline_buf)
        finalizer(buf) do x
            for ptr ∈ buf.slabs
                free(ptr)
            end
            resize!(buf.slabs, 0)
            for ptr ∈ buf.outline_buf
                free(ptr)
            end
            resize!(buf.outline_buf, 0)
        end
        buf
    end
end

## Buffer implementations
# ------------------------------------------------------
include("SlabBuffer.jl")
include("AllocBuffer.jl")


## Private
# ------------------------------------------------------
include("internals.jl")


end # Bumper
