module WithAlloc

import Bumper

"""
   Bumper.whatalloc(fn!, args...)

Specifies how to allocate an output arrays (or arrays) for `fn!`. 
   
### Example with single output array
```julia
mymul!(A, B, C) = mul!(A, B, C)  # returns A 

# specify how to allocate memory for `mymul!`
Bumper.whatalloc(::typeof(mymul!), B, C) = 
          (promote_type(eltype(B), eltype(C)), size(B, 1), size(C, 2))

# call `mymul!` with an implicit Bumper-allocated array.
@no_escape begin 
   # ...
   A = @withalloc mymul!(B, C)
   # ... 
end 
```

### Example with multiple output arrays
```julia
mymul2!(A1, A2, B, C, D) = mul!(A1, B, C), mul!(A2, B, D)

function Bumper.whatalloc(::typeof(mymul2!), B, C, D) 
   T1 = promote_type(eltype(B), eltype(C)) 
   T2 = promote_type(eltype(B), eltype(D))
   return ( (T1, size(B, 1), size(C, 2)), 
            (T2, size(B, 1), size(D, 2)) )
end

@no_escape begin 
   # ... 
   A1b, A2b = @withalloc mymul2!(B, C, D)
   # ...
end
```
"""
function whatalloc end 

"""
   Bumper.@withalloc
   Bumper.withalloc(fn!, args...)

Allocate output array(s) and call an in-place function, within a 
@no_escape block. The allocation is specified via `Bumper.whatalloc`. 

### Example

```julia
mymul!(A, B, C) = mul!(A, B, C)  

@no_escape begin 
   # ...
   A = @withalloc mymul!(B, C)
   A = withalloc(mymul!, B, C)
   # ... 
end 
```

See `?Bumper.whatalloc` for more details on how to specify the 
allocation of the output array. 
"""
macro withalloc(ex)
   esc_args = esc.(ex.args)
   quote
      withalloc($(esc_args...))
   end
end

"""
see `Bumper.@withalloc` for details.
"""
@inline function withalloc(fncall, args...)
   allocinfo = whatalloc(fncall, args...)
   _genwithalloc(allocinfo, fncall, args...) 
end

@inline function _bumper_alloc(allocinfo::Tuple{<: Type, Vararg{Int, N}}) where {N}
   Bumper.alloc!(Bumper.default_buffer(), allocinfo...)
end

@inline @generated function _genwithalloc(allocinfo::TT, fncall, args...)  where {TT <: Tuple}
   code = Expr[] 
   LEN = length(TT.types) 
   if TT.types[1] <: Tuple 
      for i in 1:LEN
         push!(code, Meta.parse("tmp$i = _bumper_alloc(allocinfo[$i])"))
      end
   else 
      push!(code, Meta.parse("tmp1 = _bumper_alloc(allocinfo)"))
      LEN = 1 
   end
   push!(code, Meta.parse("fncall($(join(["tmp$i, " for i in 1:LEN])) args...)"))
   quote
      $(code...)
   end
end 


end 
