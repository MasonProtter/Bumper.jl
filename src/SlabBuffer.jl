module SlabBufferImpl

import Bumper:
    SlabBuffer,
    alloc_ptr!,
    checkpoint_save,
    checkpoint_restore!,
    default_buffer,
    malloc,
    free

const default_slab_size = 16_384
SlabBuffer() = SlabBuffer{default_slab_size}()

const default_buffer_key = gensym(:slab_buffer)
function default_buffer(::Type{SlabBuffer})
    get!(() -> SlabBuffer{default_slab_size}(), task_local_storage(), default_buffer_key)::SlabBuffer{default_slab_size}
end
default_buffer() = default_buffer(SlabBuffer)

function alloc_ptr!(buf::SlabBuffer{SlabSize}, sz::Int)::Ptr{Cvoid} where {SlabSize}
    p = buf.current
    next = buf.current + sz
    if next > buf.slab_end
        p = add_new_slab!(buf, sz)
    else
        buf.current = next
    end
    p
end
@noinline function add_new_slab!(buf::SlabBuffer{SlabSize}, sz::Int)::Ptr{Cvoid} where {SlabSize}
    alloc_size = max(sz, SlabSize)

    new_slab = malloc(alloc_size)

    buf.current = new_slab + sz
    buf.slab_end = new_slab + alloc_size
    push!(buf.slabs, new_slab)
    new_slab
end

struct SlabCheckpoint{SlabSize}
    buf::SlabBuffer{SlabSize}
    current::Ptr{Cvoid}
    slab_end::Ptr{Cvoid}
    slabs_length::Int
end

function checkpoint_save(buf::SlabBuffer=default_buffer())
    SlabCheckpoint(buf, buf.current, buf.slab_end, length(buf.slabs))
end
function checkpoint_restore!(cp::SlabCheckpoint)
    buf = cp.buf
    slabs = buf.slabs
    if length(slabs) > cp.slabs_length
        restore_slabs!(cp)
    end
    buf.current  = cp.current
    buf.slab_end = cp.slab_end 
    nothing
end

@noinline function restore_slabs!(cp)
    buf = cp.buf
    slabs = buf.slabs
    for i ∈ (cp.slabs_length+1):length(slabs)
        free(slabs[i])
    end
    resize!(slabs,  cp.slabs_length)
end

function reset_buffer!(buf::SlabBuffer{SlabSize}) where {SlabSize}
    buf.current = pointer(buf.slabs[1])
    buf.slab_end = current + SlabSize
    for ptr ∈ @view buf.slabs[2:end]
        free(ptr)
    end
    resize!(buf.slabs, 1)
    buf
end



end # module SlabBufferImpl
