module Bumper

export no_escape, @no_escape, alloc, with_buffer, AllocBuffer, set_default_buffer_size!, reset_buffer!

using StrideArraysCore, StrideArrays
using StrideArraysCore: calc_strides_len, all_dense
using ContextVariablesX

allow_ptr_array_to_escape() = false

mutable struct AllocBuffer{Storage}
    buf::Storage
    offset::UInt
end
AllocBuffer(max_size)  = AllocBuffer(Vector{UInt8}(undef, max_size), UInt(0))

@contextvar buf = AllocBuffer(0)

function set_default_buffer_size!(sz::Int)
    resize!(buf[].buf, sz)
    sz
end

reset_buffer!(b::AllocBuffer) = b.offset = UInt(0)
reset_buffer!() = reset_buffer!(buf[])

maxsize(b::AllocBuffer) = length(b.buf)
Base.pointer(b::AllocBuffer) = pointer(b.buf)

function alloc_ptr(b::AllocBuffer, sz::Int)
    # @info "Allocating $sz bytes"
    ptr = pointer(b) + b.offset
    b.offset += sz
    b.offset > maxsize(b) && error("alloc: Buffer out of memory. Consider resizing it, or checking for memory leaks.")
    ptr
end

function no_escape(f, b::AllocBuffer)
    offset = b.offset
    res = f()
    b.offset = offset
    if res isa PtrArray && !(allow_ptr_array_to_escape())
        error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate   Bumper.allow_ptrarray_to_escape() = true")
    end
    res
end

macro no_escape(b, ex)
    quote
        b = $(esc(b))
        offset = b.offset
        res = $(esc(ex))
        b.offset = offset
        if res isa PtrArray && !(allow_ptr_array_to_escape())
            error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate   Bumper.allow_ptrarray_to_escape() = true")
        end
        res
    end
end
macro no_escape(ex)
    quote
        b = buf[]
        offset = b.offset
        res = $(esc(ex))
        b.offset = offset
        if res isa PtrArray && !(allow_ptr_array_to_escape())
            error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate   Bumper.allow_ptrarray_to_escape() = true")
        end
        res
    end
end

no_escape(f) = no_escape(f, buf[])

function StrideArraysCore.PtrArray{T}(b::AllocBuffer, s::Vararg{Integer, N}) where {T, N}
    x, L = calc_strides_len(T, s)
    ptr = reinterpret(Ptr{T}, alloc_ptr(b, L))
    PtrArray(ptr, s, x, all_dense(Val{N}()))
end

alloc(::Type{T}, s...) where {T} = PtrArray{T}(buf[], s...)
alloc(::Type{T}, buf::AllocBuffer, s...) where {T} = PtrArray{T}(buf, s...)

with_buffer(f, b::AllocBuffer) = with_context(f, buf => b)

end
