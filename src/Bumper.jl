module Bumper

export AllocBuffer, @alloc, default_buffer, @no_escape, with_buffer


## Public API
# ------------------------------------------------------

"""
    AllocBuffer{StorageType}

This is a single bump allocator that could be used to store some memory of type `StorageType`.
Do not manually manipulate the fields of an AllocBuffer that is in use.
"""
mutable struct AllocBuffer{Storage}
    buf::Storage
    offset::UInt
end


"""
    @no_escape([buf=default_buffer()], expr)

Record the current state of `buf` (which defaults to the `default_buffer()` if there is only one argument), and then run
the code in `expr` and then reset `buf` back to the state it was in before the code ran. This allows us to allocate memory
within the `expr` using `@alloc`, and then have those arrays be automatically de-allocated once the expression is over. This
is a restrictive but highly efficient form of memory management.

Using `return`, `@goto`, and `@label` are not allowed inside of `@no_escape` block.

Example:

    function f(x::Vector{Int})
        # Set up a scope where memory may be allocated, and does not escape:
        @no_escape begin
            # Allocate a `PtrArray` from StrideArraysCore.jl using memory from the default buffer.
            y = @alloc(Int, length(x))
            # Now do some stuff with that vector:
            y .= x .+ 1
           sum(y)
        end
    end
"""
macro no_escape end

"""
    @alloc(T, n::Int...) -> PtrArray{T, length(n)}

This can only be used inside a `@no_escape` block to allocate a `PtrArray` whose dimensions
are determined by `n`. The memory used to allocate this array will come from the buffer
associated with the enclosing `@no_escape` block.

Do not allow any references to these arrays to escape the enclosing `@no_escape` block, and do
not pass these arrays to concurrent tasks unless that task is guaranteed to terminate before the
`@no_escape` block ends. Any array allocated in this way which is found outside of it's parent
`@no_escape` block has undefined contents.
"""
macro alloc(args...)
    error("The @alloc macro may only be used inside of a @no_escape block.")
end

"""
    @alloc_nothrow(T, n::Int...) -> PtrArray{T, length(n)}

Just like `@alloc` but it won't throw an error if the size you requested is too big. Don't use this
unless you're doing something weird like using StaticCompiler.jl and can't handle errors.
"""
macro alloc_nothrow(args...)
    error("The @alloc macro may only be used inside of a @no_escape block.")
end
function alloc_nothrow end

"""
   default_buffer() -> AllocBuffer{Vector{UInt8}}

Return the current task-local default buffer, if one does not exist in the current task, it will
create one.
"""
function default_buffer end

"""
    alloc(T, b::AllocBuffer, n::Int...) -> PtrArray{T, length(n)}

Function-based alternative to `@alloc` which allocates onto a specified `AllocBuffer`.
You must obey all the rules from `@alloc`.
"""
function alloc end


"""
    with_buffer(f, buf::AllocBuffer{Vector{UInt8}})

Execute the function `f()` in a context where `default_buffer()` will return `buf` instead of the normal `default_buffer`. This currently only works with `AllocBuffer{Vector{UInt8}}`.

Example:

    julia> let b1 = default_buffer()
               b2 = AllocBuffer(10000)
               with_buffer(b2) do
                   @show default_buffer() == b2
               end
               @show default_buffer() == b1
           end
    default_buffer() == b2 = true
    default_buffer() == b1 = true
    true
"""
function with_buffer end

"""
    Bumper.set_default_buffer_size!(n::Int)

Change the size that future `AllocBuffer()`s will be created with.
"""
function set_default_buffer_size! end


allow_ptr_array_to_escape() = false

"""
    Bumper.reset_buffer!(buf::AllocBuffer=default_buffer())

This resets an AllocBuffer's offset to zero, effectively making it like a freshly allocated buffer. This might be
necessary to use if you accidentally over-allocate a buffer.
"""
function reset_buffer! end



## Private
# ------------------------------------------------------
module Internals

using StrideArraysCore
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
    @gensym b offset
    e_offset = esc(offset)
    # This'll be the variable labelling the active buffer
    e_b = esc(b)
    function recursive_handler(ex)
        if isexpr(ex)
            if isexpr(ex, :macrocall)
                if ex.args[1] == Symbol("@alloc")
                    # replace calls to @alloc(T, size...) with alloc(T, buf, size...) where buf
                    # is the current buffer in use.
                    Expr(:call, _alloc, b, recursive_handler.(ex.args[3:end])...)
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

with_buffer(f, b::AllocBuffer{Vector{UInt}}) = task_local_storage(f, default_buffer_key, b)

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

end # Internals

end # Bumper
