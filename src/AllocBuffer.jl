module AllocBufferImpl

import Bumper:
    AllocBuffer,
    alloc_ptr!,
    checkpoint_save,
    checkpoint_restore!,
    default_buffer

# const buffer_size = Ref{Int}(256_000)
# get_default_buffer_size() = buffer_size[]
# function set_default_buffer_size!(sz::Int)
#     buffer_size[] = sz
#     resize!(default_buffer(), sz)
#     GC.gc()
#     sz
# end

const default_buffer_size = 10_028_000
const default_buffer_key = gensym(:buffer)

AllocBuffer(max_size::Int) = AllocBuffer(Vector{UInt8}(undef, max_size), UInt(0))
AllocBuffer(storage::Vector{UInt8}) = AllocBuffer(storage, UInt(0))
AllocBuffer() = AllocBuffer(Vector{UInt8}(undef, UInt(default_buffer_size)))

function default_buffer(::Type{AllocBuffer})
    get!(() -> AllocBuffer(), task_local_storage(), default_buffer_key)::AllocBuffer{Vector{UInt8}}
end

inline_size(b::AllocBuffer) = sizeof(b.inline_buf)
with_buffer(f, b::AllocBuffer) =  task_local_storage(f, default_buffer_key, b)

function reset_buffer!(b::AllocBuffer = default_buffer())
    b.inline_offset = UInt(0)
    resize!(outline_buf, 0)
    b.outline_position = 0
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
