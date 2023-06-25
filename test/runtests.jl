using Test, Bumper

# set_default_buffer_size!(1000)

function f(x::Vector{Int})
    @no_escape begin
        y = alloc(Int, length(x))
        y .= x .+ 1
        sum(y)
    end
end

function f(x, buf::AllocBuffer)
    @no_escape buf begin 
        y = alloc(Int, buf, length(x)) 
        y .= x .+ 1
        sum(y)
    end
end

@testset "basic" begin
    v = [1,2,3]
    b = AllocBuffer(100)

    @test f(v) == 9
    @test f(v, b) == 9
    
    @test @allocated(f(v)) == 0
    @test @allocated(f(v, b)) == 0

end

@testset "tasks and buffer switching" begin
    @test default_buffer() === default_buffer()
    @test default_buffer() !== fetch(@async default_buffer())

    @test default_buffer() !== with_buffer(default_buffer, AllocBuffer(100))
end
