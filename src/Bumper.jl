module Bumper

export SlabBuffer, AllocBuffer, ResizeBuffer, @alloc, @alloc_ptr, default_buffer, @no_escape, with_buffer
using UnsafeArrays: UnsafeArrays, UnsafeArray


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
            # Allocate a `UnsafeArray` from UnsafeArrays.jl using memory from the default buffer.
            y = @alloc(Int, length(x))
            # Now do some stuff with that vector:
            y .= x .+ 1
           sum(y)
        end
    end
"""
macro no_escape end

"""
    @alloc(T, n::Int...) -> UnsafeArray{T, length(n)}

This can be used inside a `@no_escape` block to allocate a `UnsafeArray` whose dimensions
are determined by `n`. The memory used to allocate this array will come from the buffer
associated with the enclosing `@no_escape` block.

Do not allow any references to this array to escape the enclosing `@no_escape` block, and do
not pass these arrays to concurrent tasks unless that task is guaranteed to terminate before the
`@no_escape` block ends. Any array allocated in this way which is found outside of its parent
`@no_escape` block has undefined contents, and writing to this pointer will have undefined behaviour.
"""
macro alloc(args...)
    error("The @alloc macro may only be used inside of a @no_escape block.")
end

"""
    @alloc_ptr(n::Integer) -> Ptr{Nothing}

This can be used inside a `@no_escape` block to allocate a pointer which can hold `n` bytes.
The memory used to allocate this pointer will come from the buffer associated with the
enclosing `@no_escape` block.

Do not allow any references to this pointer to escape the enclosing `@no_escape` block, and do
not pass these pointers to concurrent tasks unless that task is guaranteed to terminate before the
`@no_escape` block ends. Any pointer allocated in this way which is found outside of its parent
`@no_escape` block has undefined contents, and writing to this pointer will have undefined behaviour.
"""
macro alloc_ptr(args...)
    error("The @alloc_ptr macro may only be used inside of a @no_escape block.")
end

function default_buffer end

"""
    Bumper.alloc!(b, ::Type{T}, n::Int...) -> UnsafeArray{T, length(n)}

Function-based alternative to `@alloc` which allocates onto a specified allocator `b`.
You must obey all the rules from `@alloc`, but you can use this outside of the lexical
scope of `@no_escape` for specific (but dangerous!) circumstances where you cannot avoid
a scope barrier between the two.
"""
function alloc! end

"""
    Bumper.alloc_ptr!(b, n::Int) -> Ptr{Nothing}

Take a pointer which can store at least `n` bytes from the allocator `b`.
"""
function alloc_ptr! end

"""
    with_buffer(f, buf)

Execute the function `f()` in a context where `default_buffer()` will return `buf` instead of the normal
`default_buffer`. This currently only works with `SlabBuffer{1_048_576}`, and `AllocBuffer{Vector{UInt8}}`.

Example:

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
"""
function with_buffer end


allow_ptr_array_to_escape() = false

"""
    Bumper.reset_buffer!(buf=default_buffer())

This resets a buffer to its default state, effectively making it like a freshly allocated buffer. This might be
necessary to use if you accidentally over-allocate a buffer or screw up its state in some other way.
"""
function reset_buffer! end


"""
    Bumper.checkpoint_save(buf = default_buffer())

Returns a checkpoint object `cp` which stores the state of a `buf` at a given point in
a program. One can then use `Bumper.checkpoint_restore!(cp)` to later on restore
the state of the buffer to it's earlier saved state, undoing any bump allocations which
happened in the meantime on that buffer.

Users should prefer to use `@no_escape` instead of `checkpoint_save` and `checkpoint_restore`,
which is a safer and more structured way of doing the same thing.
"""
function checkpoint_save end


"""
    Bumper.checkpoint_restore!(cp)

Restore a buffer (the one used to create `cp`) to the state it was in when the
checkpoint was created, undoing any bump allocations which happened in the meantime on that
buffer. See also `Bumper.checkpoint_save`

Users should prefer to use `@no_escape` instead of `checkpoint_save` and `checkpoint_restore`,
which is a safer and more structured way of doing the same thing.
"""
function checkpoint_restore! end

## Private
# ------------------------------------------------------
include("internals.jl") # module Internals


## Allocator implementations
# ------------------------------------------------------
include("SlabBuffer.jl")
import .SlabBufferImpl: SlabBuffer

include("AllocBuffer.jl")
import .AllocBufferImpl: AllocBuffer

include("ResizeBuffer.jl")
import .ResizeBufferImpl: ResizeBuffer


end # Bumper
