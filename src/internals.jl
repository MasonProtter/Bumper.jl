module Internals

using StrideArraysCore
import Bumper: AllocBuffer,  alloc, default_buffer, allow_ptr_array_to_escape, set_default_buffer_size!,
    with_buffer, @no_escape, alloc_nothrow, reset_buffer!, Checkpoint, checkpoint_save, checkpoint_restore!

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

"""
    buffer_size :: RefValue{Int}

The default size in bytes of buffers created by calling `AllocBuffer()`
"""
const buffer_size = Ref(total_physical_memory() ÷ 8)

Base.pointer(b::AllocBuffer) = pointer(b.buf)

"""
    AllocBuffer(max_size::Int) -> AllocBuffer{Vector{UInt8}}

Create an AllocBuffer storing a vector of bytes which can store as most `max_size` bytes
"""
AllocBuffer(max_size::Int)  = AllocBuffer(Vector{UInt8}(undef, max_size), UInt(0))

"""
    AllocBuffer(storage::T) -> AllocBuffer{T}

Create an AllocBuffer using `storage` as the memory slab. Whatever `storage` is, it must
support `Base.pointer`, and the `sizeof` function must give the number of bytes available
to that pointer.
"""
AllocBuffer(storage) = AllocBuffer(storage, UInt(0))

"""
    AllocBuffer() -> AllocBuffer{Vector{UInt8}}

Create an AllocBuffer whose size is determined by `Bumper.buffer_size[]`. 
"""
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
    b.offset > sizeof(b.buf) && oom_error()
    ptr
end

function alloc_ptr_nothrow(b::AllocBuffer, sz::Int)
    ptr = pointer(b) + b.offset
    b.offset += sz
    ptr
end


@noinline function oom_error()
    error("alloc: Buffer out of memory. This might be a sign of a memory leak.
Use Bumper.reset_buffer!() or Bumper.reset_buffer!(b::AllocBuffer) to reclaim its memory.")
end

macro no_escape(b_ex, ex)
    _no_escape_macro(b_ex, ex, __module__)
end

macro no_escape(ex)
    _no_escape_macro(:(default_buffer()), ex, __module__)
end

isexpr(ex) = ex isa Expr
isexpr(ex, head) = isexpr(ex) && ex.head == head

function _no_escape_macro(b_ex, _ex, __module__)
    @gensym b offset tsk
    e_offset = esc(offset)
    # This'll be the variable labelling the active buffer
    e_b = esc(b)
    function recursive_handler(ex)
        if isexpr(ex)
            if isexpr(ex, :macrocall)
                if ex.args[1] == Symbol("@alloc")
                    # replace calls to @alloc(T, size...) with alloc(T, buf, size...) where buf
                    # is the current buffer in use.
                    Expr(:block,
                         :($tsk === $current_task() || $tsk_err()),
                         Expr(:call, _alloc, b, recursive_handler.(ex.args[3:end])...))
                elseif ex.args[1] == Symbol("@alloc_nothrow")
                    Expr(:call, _alloc_nothrow, b, recursive_handler.(ex.args[3:end])...)
                elseif ex.args[1] == Symbol("@no_escape")
                    # If we encounter nested @no_escape blocks, we'll leave them alone
                    ex
                else
                    # All other macros must be macroexpanded in case the user has a macro
                    # in the body which has return or goto in it
                    expanded = macroexpand(__module__, ex; recursive=false)
                    recursive_handler(expanded)
                end
            elseif isexpr(ex, :return)
                error("The `return` keyword is not allowed to be used inside the `@no_escape` macro")
            elseif isexpr(ex, :symbolicgoto) 
                error("`@goto` statements are not allowed to be used inside the `@no_escape` macro")
            elseif isexpr(ex, :symboliclabel) 
                error("`@label` statements are not allowed to be used inside the `@no_escape` macro")
            else
                Expr(ex.head, recursive_handler.(ex.args)...)
            end
        else
            ex
        end
    end
    ex = recursive_handler(_ex)

    quote
        $e_b = $(esc(b_ex))
        $(esc(tsk)) = current_task()
        local cp = checkpoint_save($e_b)
        local res = $(esc(ex))
        checkpoint_restore!(cp)
        if res isa PtrArray && !(allow_ptr_array_to_escape())
           esc_err()
        end
        res
    end
end

@noinline tsk_err() =
    error("Tried to use @alloc from a different task than its parent @no_escape block, that is not allowed for thread safety reasons. If you really need to do this, see Bumper.alloc instead of @alloc.")

@noinline esc_err() =
    error("Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate Bumper.allow_ptrarray_to_escape() = true")

with_buffer(f, b::AllocBuffer{Vector{UInt8}}) = task_local_storage(f, default_buffer_key, b)

struct NoThrow end

function StrideArraysCore.PtrArray{T}(b::AllocBuffer, s::Vararg{Integer, N}) where {T, N}
    ptr = convert(Ptr{T}, alloc_ptr(b, prod(s) * sizeof(T)))
    PtrArray(ptr, s)
end

# alloc(::Type{T}, s::Integer...) where {T} = PtrArray{T}(default_buffer(), s...)
alloc(::Type{T}, buf::AllocBuffer, s::Integer...) where {T} = PtrArray{T}(buf, s...)
_alloc(buf::AllocBuffer, ::Type{T}, s::Integer...) where {T} = PtrArray{T}(buf, s...)

function StrideArraysCore.PtrArray{T}(b::AllocBuffer, ::NoThrow, s::Vararg{Integer, N}) where {T, N}
    ptr = convert(Ptr{T}, alloc_ptr_nothrow(b, prod(s) * sizeof(T)))
    PtrArray(ptr, s)
end

alloc_nothrow(::Type{T}, buf::AllocBuffer, s...) where {T}  = PtrArray{T}(buf, NoThrow(), s...) 
_alloc_nothrow(buf::AllocBuffer, ::Type{T}, s...) where {T} = PtrArray{T}(buf, NoThrow(), s...) 


checkpoint_save(buf::AllocBuffer = default_buffer()) = Checkpoint(buf, buf.offset)

function checkpoint_restore!(cp::Checkpoint)
    cp.buf.offset = cp.offset
    nothing
end

end # Internals
