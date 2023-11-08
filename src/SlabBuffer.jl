module SlabBufferImpl

import Bumper:
    SlabBuffer,
    alloc_ptr!,
    checkpoint_save,
    checkpoint_restore!,
    reset_buffer!,
    default_buffer,
    malloc,
    free,
    with_buffer

const default_slab_size = 16_384

"""
    SlabBuffer()

Create a slab allocator whose slabs are of size $default_slab_size
"""
SlabBuffer() = SlabBuffer{default_slab_size}()

const default_buffer_key = gensym(:slab_buffer)

"""
    default_buffer(::Type{SlabBuffer}) -> SlabBuffer{16_384}

Return the current task-local default `SlabBuffer`, if one does not exist in the current task, it will
create one automatically. This currently only works with `SlabBuffer{16_384}`, and you cannot adjust
the slab size it creates.
"""
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
    if sz > SlabSize
        custom = malloc(sz)
        push!(buf.custom_slabs, custom)
        custom
    else
        new_slab = malloc(SlabSize)
        buf.current = new_slab + sz
        buf.slab_end = new_slab + SlabSize
        push!(buf.slabs, new_slab)
        new_slab
    end
end

struct SlabCheckpoint{SlabSize}
    buf::SlabBuffer{SlabSize}
    current::Ptr{Cvoid}
    slab_end::Ptr{Cvoid}
    slabs_length::Int
    custom_slabs_length::Int
end

function checkpoint_save(buf::SlabBuffer=default_buffer())
    SlabCheckpoint(buf, buf.current, buf.slab_end, length(buf.slabs), length(buf.custom_slabs))
end
function checkpoint_restore!(cp::SlabCheckpoint)
    buf = cp.buf
    slabs = buf.slabs
    custom = buf.custom_slabs
    if length(slabs) > cp.slabs_length
        restore_slabs!(cp)
    end
    if length(custom) > cp.custom_slabs_length
        restore_custom_slabs!(cp)
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
    nothing
end

@noinline function restore_custom_slabs!(cp)
    buf = cp.buf
    custom = buf.custom_slabs
    for i ∈ (cp.custom_slabs_length+1):length(custom)
        free(custom[i])
    end
    resize!(custom, cp.custom_slabs_length)
    nothing
end

function reset_buffer!(buf::SlabBuffer{SlabSize}) where {SlabSize}
    buf.current = buf.slabs[1]
    buf.slab_end = buf.current + SlabSize
    for ptr ∈ @view buf.slabs[2:end]
        free(ptr)
    end
    for ptr ∈ buf.custom_slabs
        free(ptr)
    end
    resize!(buf.slabs, 1)
    resize!(buf.custom_slabs, 0)
    buf
end

with_buffer(f, b::SlabBuffer{default_slab_size}) =  task_local_storage(f, default_buffer_key, b)


end # module SlabBufferImpl
