module SlabBufferImpl

import Bumper:
    alloc_ptr!,
    checkpoint_save,
    checkpoint_restore!,
    reset_buffer!,
    default_buffer,
    with_buffer

import Bumper.Internals: malloc, free
const default_slab_size = 1_048_576

"""
    mutable struct SlabBuffer{SlabSize}

A slab-based bump allocator which can dynamically grow to hold an arbitrary amount of memory.
Small allocations live within a specific slab of memory, and if that slab fills up, a new slab
is allocated and future allocations happen on that slab. Small allocations are stored in slabs
of size `SlabSize` bytes, and the list of live slabs are tracked in the `slabs` field.
Allocations which are too large to fit into one slab are stored and tracked in the `custom_slabs`
field.

The default slab size is $default_slab_size bytes.

`SlabBuffer`s are nearly as fast as stack allocation (typically up to within a couple of nanoseconds) for typical
use. One potential performance pitfall is if that `SlabBuffer`'s current position is at the end of a slab, then
the next allocation will be slow because it requires a new slab to be created. This means that if you do something
like

    buf = SlabBuffer{N}()
    @no_escape buf begin
        @alloc(Int8, N÷2 - 1) # Take up just under half the first slab
        @alloc(Int8, N÷2 - 1) # Take up another half of the first slab
        # Now buf should be practically out of room. 
        for i in 1:1000
            @no_escape buf begin
                y = @alloc(Int8, 10) # This will allocate a new slab because there's no room
                f(y)
            end # At the end of this block, we delete the new slab because it's not needed.
        end
    end

then the inner loop will run slower than normal because at each iteration, a new slab of size `N` bytes must be freshly
allocated. This should be a rare occurance, but is possible to encounter.

Do not manipulate the fields of a SlabBuffer that is in use.
"""
mutable struct SlabBuffer{SlabSize}
    current      ::Ptr{Cvoid}
    slab_end     ::Ptr{Cvoid}
    slabs        ::Vector{Ptr{Cvoid}}
    custom_slabs ::Vector{Ptr{Cvoid}}

    function SlabBuffer{_SlabSize}(; finalize::Bool=true) where {_SlabSize}
        SlabSize = convert(Int, _SlabSize)
        current  = malloc(SlabSize)
        slab_end = current + SlabSize
        slabs = [current]
        custom_slabs = Ptr{Cvoid}[]
        buf = new{SlabSize}(current, slab_end, slabs, custom_slabs)
        finalize && finalizer(free, buf)
        buf
    end
end

@doc """
    SlabBuffer{SlabSize}(;finalize::Bool = true)

Create a slab allocator whose slabs are of size `SlabSize`. If you set the
`finalize` keyword argument to `false`, then you will need to explicitly
call `Bumper.free()` when you are done with a `SlabBuffer`. This is not
recommended.
""" SlabBuffer{SlabSize}()

"""
    SlabBuffer(;finalize::Bool = true)

Create a slab allocator whose slabs are of size $default_slab_size. If you set
the `finalize` keyword argument to `false`, then you will need to explicitly
call `Bumper.free()` when you are done with a `SlabBuffer`. This is not
recommended.
"""
SlabBuffer(;finalize=true) = SlabBuffer{default_slab_size}(;finalize)

function free(buf::SlabBuffer)
    for ptr ∈ buf.slabs
        free(ptr)
    end
    for ptr ∈ buf.custom_slabs
        free(ptr)
    end
end

const default_buffer_key = gensym(:slab_buffer)

"""
    default_buffer(::Type{SlabBuffer}) -> SlabBuffer{$default_slab_size}

Return the current task-local default `SlabBuffer`, if one does not exist in the current task, it will
create one automatically. This currently can only create `SlabBuffer{$default_slab_size}`, and you
cannot adjust the slab size it creates.
"""
function default_buffer(::Type{SlabBuffer})
    get!(() -> SlabBuffer{default_slab_size}(), task_local_storage(), default_buffer_key)::SlabBuffer{default_slab_size}
end

"""
    default_buffer() -> SlabBuffer{$default_slab_size}

Return the current task-local default `SlabBuffer`, if one does not exist in the current task, it will
create one automatically. This currently only works with `SlabBuffer{$default_slab_size}`, and you
cannot adjust the slab size it creates.
"""
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
    if sz >= (SlabSize ÷ 2)
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
