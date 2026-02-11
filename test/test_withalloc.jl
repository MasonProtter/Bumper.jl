using Test, Bumper, LinearAlgebra

##

function mymul!(A, B, C) 
   mul!(A, B, C)
end

function Bumper.whatalloc(::typeof(mymul!), B, C) 
   T = promote_type(eltype(B), eltype(C))
   return (T, size(B, 1), size(C, 2))
end

B = randn(5,10)
C = randn(10, 3)
A1 = B * C
A2glob = nothing
A3glob = nothing 
A4glob = nothing

@no_escape begin 
   A2_alloc_info = Bumper.whatalloc(mymul!, B, C)
   A2 = @alloc(A2_alloc_info...)
   mymul!(A2, B, C)
   A2glob = copy(A2)
end
@test A1 ≈ A2glob

@no_escape begin 
   A3 = @withalloc mymul!(B, C)
   A3glob = copy(A3)
end
@test A1 ≈ A3glob

@no_escape begin 
   A4 = withalloc(mymul!, B, C)
   A4glob = copy(A4)
end
@test A1 ≈ A4glob

## allocation test 

alloctest(B, C) = (@no_escape begin sum( @withalloc mymul!(B, C) ); end)
alloctest_nm(B, C) = (@no_escape begin sum( withalloc(mymul!, B, C) ); end)

nalloc = let    
   B = randn(5,10); C = randn(10, 3)
   @allocated alloctest(B, C)
end
@test nalloc == 0

nalloc_nm = let    
   B = randn(5,10); C = randn(10, 3)
   @allocated alloctest_nm(B, C)
end
@test nalloc_nm == 0
   
## 

# multiple allocations 

B = randn(5,10)
C = randn(10, 3)
D = randn(10, 5)
A1 = B * C 
A2 = B * D


function mymul2!(A1, A2, B, C, D)
   mul!(A1, B, C)
   mul!(A2, B, D)
   return A1, A2 
end

function Bumper.whatalloc(::typeof(mymul2!), B, C, D) 
   T1 = promote_type(eltype(B), eltype(C)) 
   T2 = promote_type(eltype(B), eltype(D))
   return ( (T1, size(B, 1), size(C, 2)), 
            (T2, size(B, 1), size(D, 2)) )
end


@no_escape begin 
   A1b, A2b = @withalloc mymul2!(B, C, D)
   A1glob = copy(A1b)
   A2glob = copy(A2b)
end
@test A1 ≈ A1glob
@test A2 ≈ A2glob

@no_escape begin 
   A1c, A2c = withalloc(mymul2!, B, C, D)
   A1glob = copy(A1c)
   A2glob = copy(A2c)
end
@test A1 ≈ A1glob
@test A2 ≈ A2glob

## allocation test

alloctest2(B, C, D) = 
         (@no_escape begin sum(sum.( @withalloc mymul2!(B, C, D) )); end)

alloctest2_nm(B, C, D) = 
         (@no_escape begin sum(sum.( withalloc(mymul2!, B, C, D) )); end)

nalloc2 = let    
   B = randn(5,10); C = randn(10, 3); D = randn(10, 5)
   @allocated alloctest2(B, C, D)
end
@test nalloc2 == 0

nalloc2_nm = let    
   B = randn(5,10); C = randn(10, 3); D = randn(10, 5)
   @allocated alloctest2_nm(B, C, D)
end
@test nalloc2_nm == 0



##
# multiple allocations of different type 

B = randn(5,10)
C = randn(10, 3)
D = randn(3)
A1 = B * C 
A2 = A1 * D 

function mymul3!(A1, A2, B, C, D)
   mul!(A1, B, C)
   mul!(A2, A1, D)
   return A1, A2 
end

function Bumper.whatalloc(::typeof(mymul3!), B, C, D) 
   T1 = promote_type(eltype(B), eltype(C)) 
   T2 = promote_type(T1, eltype(D))
   return ( (T1, size(B, 1), size(C, 2)), 
            (T2, size(B, 1)) )
end


@no_escape begin 
   A1b, A2b = @withalloc mymul3!(B, C, D)
   A1glob = copy(A1b)
   A2glob = copy(A2b)
end
@test A1 ≈ A1glob
@test A2 ≈ A2glob

## allocation test

alloctest3(B, C, D) = 
      (@no_escape begin sum(sum.( @withalloc mymul3!(B, C, D) )); end)

nalloc3 = let    
   B = randn(5,10)
   C = randn(10, 3)
   D = randn(10, 5)
   @allocated alloctest2(B, C, D)
end

@test nalloc3 == 0
