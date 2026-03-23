module ResizeBufferImpl


import Bumper:
    alloc_ptr!,
    checkpoint_save,
    checkpoint_restore!,
    default_buffer,
    reset_buffer!,
    with_buffer
import Bumper.Internals: malloc, free

const default_max_size = 1_048_576

"""
    ResizeBuffer
    ResizeBuffer(max_size = $default_max_size; finalize::Bool = true)

*New in v0.7.2.*

An adaptive bump allocator oriented towards workflows that repeatedly perform a similar operation where
the amount of memory needed is not known a priori. Allocations are served from an internal fixed buffer;
when that buffer is exhausted, overflow allocations are made on the heap so no allocation ever fails.
Upon a full `reset_buffer!`, overflow memory is freed and the internal buffer is resized to the
peak observed usage, so that future iterations of the same operation avoid overflow entirely.

In contrast, `SlabBuffer` frees extra slabs when their allocations are released and does not retain
memory between operations — it "forgets" peak usage and shrinks back to its baseline size.
`ResizeBuffer` is the better choice when you expect to repeat the same memory-intensive operation many
times and want the allocator to warm up to the right size rather than paying the cost of fresh slab
allocation on each call.

The initial buffer capacity is given by `max_size`. If you set the `finalize` keyword argument to
`false`, then you will need to explicitly call `Bumper.free(buf)` when you are done with the
`ResizeBuffer`. This is not recommended.

Do not manually manipulate the fields of a `ResizeBuffer` that is in use.
"""
mutable struct ResizeBuffer
    buf::Ptr{Cvoid}
    buf_len::UInt

    offset::UInt
    max_offset::UInt

    overflow::Vector{Ptr{Cvoid}}

    function ResizeBuffer(max_size::Int = default_max_size; finalize::Bool = true)
        buf = malloc(max_size)
        buf_len = max_size
        overflow = Ptr{Cvoid}[]
        resizebuf = new(buf, buf_len, UInt(0), UInt(0), overflow)
        finalize && finalizer(free, resizebuf)
        return resizebuf
    end
end

function free(buf::ResizeBuffer)
    foreach(free, buf.overflow)
    free(buf.buf)
    return nothing
end

const default_buffer_key = gensym(:buffer)


"""
    default_buffer(::Type{ResizeBuffer}) -> ResizeBuffer

Return the current task-local default `ResizeBuffer`, creating one automatically if it does not yet
exist in the current task.
"""
function default_buffer(::Type{ResizeBuffer})
    return get!(() -> ResizeBuffer(), task_local_storage(), default_buffer_key)::ResizeBuffer
end

function alloc_ptr!(b::ResizeBuffer, sz::Int)::Ptr{Cvoid}
    old_offset = b.offset
    b.offset += sz
    b.max_offset = max(b.max_offset, b.offset)

    # grow the buffer - only available if empty
    if iszero(old_offset) & (b.max_offset > b.buf_len)
        resize_buffer!(b)
    end

    return if b.offset ≤ b.buf_len
        # use the buffer if there is enough space
        b.buf + old_offset
    else
        # add to overflow if not
        add_new_overflow!(b, sz)
    end
end

# Note: @noinline is used here to keep the "happy path" in alloc_ptr! smaller,
# which might lead to more optimized code. Preliminary testing seems to indicate this is true
@noinline function resize_buffer!(b::ResizeBuffer)
    free(b.buf)
    b.buf = malloc(b.max_offset)
    b.buf_len = b.max_offset
    return b
end
@noinline function add_new_overflow!(b::ResizeBuffer, sz::Int)
    ptr = malloc(sz)
    push!(b.overflow, ptr)
    return ptr
end

function reset_buffer!(b::ResizeBuffer)
    b.offset = UInt(0)
    b.max_offset = UInt(0) # do we want this?

    foreach(free, b.overflow)
    resize!(b.overflow, 0)

    return b
end

struct ResizeCheckpoint
    buf::ResizeBuffer
    offset::UInt
    overflow_length::Int
end

checkpoint_save(buf::ResizeBuffer) = ResizeCheckpoint(buf, buf.offset, length(buf.overflow))
function checkpoint_restore!(cp::ResizeCheckpoint)
    # restore overflow
    foreach(free, @view cp.buf.overflow[(cp.overflow_length + 1):end])
    resize!(cp.buf.overflow, cp.overflow_length)

    # restore offset
    cp.buf.offset = cp.offset

    return nothing
end

with_buffer(f, b::ResizeBuffer) = task_local_storage(f, default_buffer_key, b)

end # module ResizeBufferImpl
