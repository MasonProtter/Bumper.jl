module Bumper

export default_buffer, alloc_nothrow, @no_escape, alloc, with_buffer, AllocBuffer, set_default_buffer_size!

using StrideArraysCore
using StrideArraysCore: calc_strides_len, all_dense

mutable struct AllocBuffer{Storage}
    buf::Storage
    offset::UInt
end

AllocBuffer(max_size::Int)  = AllocBuffer(Vector{UInt8}(undef, max_size), UInt(0))
AllocBuffer(storage) = AllocBuffer(storage, UInt(0))

Base.pointer(b::AllocBuffer) = pointer(b.buf)

const buffer_size = Ref(1_000_000)
const default_buffer_key = gensym(:buffer)
function default_buffer()
    get!(() -> AllocBuffer(buffer_size[]), task_local_storage(), default_buffer_key)::AllocBuffer{Vector{UInt8}}
end

function set_default_buffer_size!(sz::Int)
    resize!(default_buffer().buf, sz)
    buffer_size[] = sz
    sz
end

reset_buffer!(b::AllocBuffer) = b.offset = UInt(0)
reset_buffer!() = reset_buffer!(default_buffer())

function alloc_ptr(b::AllocBuffer, sz::Int)
    ptr = pointer(b) + b.offset
    b.offset += sz
    b.offset > sizeof(b.buf) && error("alloc: Buffer out of memory. Consider resizing it, or checking for memory leaks.")
    ptr
end

function alloc_ptr_nothrow(b::AllocBuffer, sz::Int)
    ptr = pointer(b) + b.offset
    b.offset += sz
    ptr
end


function no_escape(f, b::AllocBuffer)
    offset = b.offset
    res = f()
    b.offset = offset
    if res isa PtrArray && !(allow_ptr_array_to_escape())
        error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate Bumper.allow_ptrarray_to_escape() = true")
    end
    res
end
no_escape(f) = no_escape(f, default_buffer())

macro no_escape(b, ex)
    quote
        b = $(esc(b))
        offset = b.offset
        res = $(esc(ex))
        b.offset = offset
        if res isa PtrArray && !(allow_ptr_array_to_escape())
            error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate Bumper.allow_ptrarray_to_escape() = true")
        end
        res
    end
end
macro no_escape(ex)
    quote
        b = default_buffer()
        offset = b.offset
        res = $(esc(ex))
        b.offset = offset
        if res isa PtrArray && !(allow_ptr_array_to_escape())
            error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate   Bumper.allow_ptrarray_to_escape() = true")
        end
        res
    end
end

with_buffer(f, b::AllocBuffer) = task_local_storage(f, default_buffer_key, b)

function StrideArraysCore.PtrArray{T}(b::AllocBuffer, s::Vararg{Integer, N}) where {T, N}
    x, L = calc_strides_len(T, s)
    ptr = reinterpret(Ptr{T}, alloc_ptr(b, L))
    PtrArray(ptr, s, x, all_dense(Val{N}()))
end

alloc(::Type{T}, s...) where {T} = PtrArray{T}(default_buffer(), s...)
alloc(::Type{T}, buf::AllocBuffer, s...) where {T} = PtrArray{T}(buf, s...)

struct NoThrow end
function StrideArraysCore.PtrArray{T}(b::AllocBuffer, ::NoThrow, s::Vararg{Integer, N}) where {T, N}
    x, L = calc_strides_len(T, s)
    ptr = reinterpret(Ptr{T}, alloc_ptr_nothrow(b, L))
    PtrArray(ptr, s, x, all_dense(Val{N}()))
end
alloc_nothrow(::Type{T}, buf::AllocBuffer, s...) where {T} = PtrArray{T}(buf, NoThrow(), s...) 


end
