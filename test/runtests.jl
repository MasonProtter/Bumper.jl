using Test, Bumper

set_default_buffer_size!(1000)

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

    @test @allocated(f(v)) == 0
    @test @allocated(f(v, b)) == 0

    @test f(v) == 9
    @test f(v, b) == 9
end

@testset "tasks and buffer switching" begin
    @test default_buffer() === default_buffer()
    @test default_buffer() !== fetch(@async default_buffer())

    @test default_buffer() !== with_buffer(default_buffer, AllocBuffer(100))
end

@testset "Buffer spilling" begin
    with_buffer(AllocBuffer(0)) do
        @no_escape begin
            v = @test_logs (:warn,  "alloc: Buffer memory limit reached, auto-resizing now. This may indicate a memory leak.\nTo disable these warnings, run `Bumper.warn_when_resizing_buffer() = false`.") alloc(Int, 10)
            v .= 1
            @test sum(v) == 10
        end
    end
end
