module Internals

using UnsafeArrays: UnsafeArrays, UnsafeArray
import Bumper:
    @no_escape,
    alloc!,
    default_buffer,
    allow_ptr_array_to_escape,
    with_buffer,
    reset_buffer!,
    checkpoint_save,
    checkpoint_restore!,
    alloc_ptr!


macro no_escape(b_ex, ex)
    _no_escape_macro(b_ex, ex, __module__)
end

macro no_escape(ex)
    _no_escape_macro(:($default_buffer()), ex, __module__)
end

get_task() = Base.current_task()

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
                         :($tsk === $get_task() || $tsk_err()),
                         Expr(:call, alloc!, b, recursive_handler.(ex.args[3:end])...))
                elseif ex.args[1] == Symbol("@alloc_ptr")
                    Expr(:block,
                         :($tsk === $get_task() || $tsk_err()),
                         Expr(:call, alloc_ptr!, b, recursive_handler.(ex.args[3:end])...))
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
        $(esc(tsk)) = get_task()
        local cp = checkpoint_save($e_b)
        local res = $(esc(ex))
        checkpoint_restore!(cp)
        if res isa UnsafeArray && !(allow_ptr_array_to_escape())
           esc_err()
        end
        res
    end
end

@noinline tsk_err() =
    error("Tried to use @alloc from a different task than its parent @no_escape block, that is not allowed for thread safety reasons. If you really need to do this, see Bumper.alloc instead of @alloc.")

@noinline esc_err() =
    error("Tried to return a UnsafeArray from a `no_escape` block. If you really want to do this, evaluate Bumper.allow_ptrarray_to_escape() = true")

function alloc!(buf, ::Type{T}, s::Vararg{Integer, N}) where {T, N}
    ptr::Ptr{T} = alloc_ptr!(buf, prod(s) * sizeof(T))
    UnsafeArray(ptr, s)
end


malloc(n::Integer) = Libc.malloc(Int(n))
free(p::Ptr) = Libc.free(p)


end
