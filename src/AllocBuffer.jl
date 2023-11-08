module AllocBufferImpl

import Bumper:
    AllocBuffer,
    alloc_ptr!,
    checkpoint_save,
    checkpoint_restore!,
    default_buffer,
    reset_buffer!,
    with_buffer

const default_buffer_size = 128_000
const default_buffer_key = gensym(:buffer)

AllocBuffer(max_size::Int) = AllocBuffer(Vector{UInt8}(undef, max_size), UInt(0))
AllocBuffer(storage) = AllocBuffer(storage, UInt(0))
AllocBuffer() = AllocBuffer(Vector{UInt8}(undef, UInt(default_buffer_size)))

function default_buffer(::Type{AllocBuffer})
    get!(() -> AllocBuffer(), task_local_storage(), default_buffer_key)::AllocBuffer{Vector{UInt8}}
end

with_buffer(f, b::AllocBuffer{Vector{UInt8}}) =  task_local_storage(f, default_buffer_key, b)

function reset_buffer!(b::AllocBuffer = default_buffer())
    b.offset = UInt(0)
    nothing
end
struct AllocCheckpoint{Store}
    buf::AllocBuffer{Store}
    offset::UInt
end
function checkpoint_save(buf::AllocBuffer)
    AllocCheckpoint(buf, buf.offset)
end
function checkpoint_restore!(cp::AllocCheckpoint)
    cp.buf.offset = cp.offset
    nothing
end

function alloc_ptr!(b::AllocBuffer, sz::Int)::Ptr{Cvoid}
    ptr = pointer(b.buf) + b.offset
    b.offset += sz
    b.offset > sizeof(b.buf) && oom_error()
    ptr
end

@noinline function oom_error()
    error("alloc: Buffer out of memory. This might be a sign of a memory leak.
Use Bumper.reset_buffer!(b::AllocBuffer) to reclaim its memory.")
end

end # module AllocBufferImpl
