module Bumper

export AllocBuffer, alloc, alloc_nothrow, default_buffer, @no_escape, with_buffer


## Public API
# ------------------------------------------------------
mutable struct AllocBuffer{Storage}
    buf::Storage
    offset::UInt
end

function default_buffer end
function alloc end
macro no_escape end
function no_escape end
function with_buffer end
function set_default_buffer_size! end
allow_ptr_array_to_escape() = false
function alloc_nothrow end
function reset_buffer! end

## Private
# ------------------------------------------------------
module Internals

using StrideArraysCore, MacroTools
import Bumper: AllocBuffer,  alloc, default_buffer, allow_ptr_array_to_escape, set_default_buffer_size!,
    with_buffer, no_escape, @no_escape, alloc_nothrow, reset_buffer!

function total_physical_memory()
    @static if isdefined(Sys, :total_physical_memory)
        Sys.total_physical_memory()
    elseif isdefined(Sys, :physical_memory)
        Sys.physical_memory()
    else
        Sys.total_memory()
    end
end

const default_buffer_key = gensym(:buffer)
const buffer_size = Ref(total_physical_memory() ÷ 8)

Base.pointer(b::AllocBuffer) = pointer(b.buf)

AllocBuffer(max_size::Int)  = AllocBuffer(Vector{UInt8}(undef, max_size), UInt(0))
AllocBuffer(storage) = AllocBuffer(storage, UInt(0))
AllocBuffer() = AllocBuffer(Vector{UInt8}(undef, buffer_size[]), UInt(0))

function default_buffer()
    get!(() -> AllocBuffer(), task_local_storage(), default_buffer_key)::AllocBuffer{Vector{UInt8}}
end

function set_default_buffer_size!(sz::Int)
    buffer_size[] = sz
    resize!(default_buffer(), sz)
    GC.gc()
    sz
end

function reset_buffer!(b::AllocBuffer = default_buffer())
    if b === default_buffer()
        b.buf = Vector{UInt8}(undef, buffer_size[])
        GC.gc()
    end
    b.offset = UInt(0)
end

function alloc_ptr(b::AllocBuffer, sz::Int)
    ptr = pointer(b) + b.offset
    b.offset += sz
    b.offset > sizeof(b.buf) && oom_error(b)
    ptr
end

function alloc_ptr_nothrow(b::AllocBuffer, sz::Int)
    ptr = pointer(b) + b.offset
    b.offset += sz
    ptr
end


@noinline function oom_error(b)
    error("alloc: Buffer out of memory. This might be a sign of a memory leak.
Use Bumper.reset_buffer!() or Bumper.reset_buffer!(b::AllocBuffer) to reclaim its memory.")
end

function no_escape(f, b::AllocBuffer)
    offset = b.offset
    res = f()
    b.offset = offset
    if res isa PtrArray && !(allow_ptr_array_to_escape())
        esc_err()
    end
    res
end
no_escape(f) = no_escape(f, default_buffer())

macro no_escape(b_ex, ex)
    _no_escape_macro(b_ex, ex, __module__)
end

macro no_escape(ex)
    _no_escape_macro(:(default_buffer()), ex, __module__)
end

function _no_escape_macro(b_ex, ex, __module__)
    @gensym b offset
    e_offset = esc(offset)
    e_b = esc(b)
    # We need to macroexpand the code in case the user has a macro in the body which has return or goto in it
    MacroTools.postwalk(macroexpand(__module__, ex)) do x
        @gensym rv
        if MacroTools.isexpr(x, :return) 
            error("The `return` keyword is not allowed to be used inside the `@no_escape` macro")
        elseif MacroTools.isexpr(x, :symbolicgoto) # && (x.args[1] ∉ enclosed_labels)
            error("`@goto` statements are not allowed to be used inside the `@no_escape` macro")
        end
    end
    quote
        $e_b = $(esc(b_ex))
        $e_offset = getfield($e_b, :offset)
        res = $(esc(ex))
        $e_b.offset = $e_offset
        if res isa PtrArray && !(allow_ptr_array_to_escape())
           esc_err()
        end
        res
    end
end

@noinline esc_err() =
    error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate Bumper.allow_ptrarray_to_escape() = true")

with_buffer(f, b::AllocBuffer) = task_local_storage(f, default_buffer_key, b)

struct NoThrow end

function StrideArraysCore.PtrArray{T}(b::AllocBuffer, s::Vararg{Integer, N}) where {T, N}
    ptr = convert(Ptr{T}, alloc_ptr(b, prod(s) * sizeof(T)))
    PtrArray(ptr, s)
end

alloc(::Type{T}, s::Integer...) where {T} = PtrArray{T}(default_buffer(), s...)
alloc(::Type{T}, buf::AllocBuffer, s::Integer...) where {T} = PtrArray{T}(buf, s...)

function StrideArraysCore.PtrArray{T}(b::AllocBuffer, ::NoThrow, s::Vararg{Integer, N}) where {T, N}
    ptr = convert(Ptr{T}, alloc_ptr_nothrow(b, prod(s) * sizeof(T)))
    PtrArray(ptr, s)
end

alloc_nothrow(::Type{T}, buf::AllocBuffer, s...) where {T} = PtrArray{T}(buf, NoThrow(), s...) 


end # Internals

end # Bumper
