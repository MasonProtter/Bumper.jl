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

    @test b.offset == 0
    
    @test_throws Exception alloc(Int, b, 100000)
    Bumper.reset_buffer!(b)
    @test_throws Exception @no_escape begin
        alloc(Int, 10)
    end
end

macro sneaky_return(ex)
    esc(:(return $ex))
end

macro sneaky_goto(label)
    esc(:(@goto $label))
end

@testset "trying to break out of no_escape blocks" begin
    # It is very tricky to properly deal with code which uses @goto or return inside
    # a @no_escape code block, because could bypass the mechanism for resetting the
    # buffer's offset after the block completes.
    
    # I played with some mechanisms for cleaning it up, but they were sometimes incorrect
    # if one nested multuple @no_escape blocks, so I decided that they should simply be
    # disabled, and throw an error at macroexpansion time.
    
    @test_throws Exception Bumper.Internals._no_escape_macro(
        :(default_buffer()),
        :(return sum(alloc(Int, 10) .= 1)),
        @__MODULE__()
    )
    @test_throws Exception Bumper.Internals._no_escape_macro(
        :(default_buffer()),
        :(@sneaky_return sum(alloc(Int, 10) .= 1)),
        @__MODULE__()
    )
    @test_throws Exception Bumper.Internals._no_escape_macro(
        :(default_buffer()),
        :(@goto lab),
        @__MODULE__()
    )
    @test_throws Exception Bumper.Internals._no_escape_macro(
        :(default_buffer()),
        :(@sneaky_goto lab),
        @__MODULE__()
    )
end

@testset "tasks and buffer switching" begin
    @test default_buffer() === default_buffer()
    @test default_buffer() !== fetch(@async default_buffer())

    @test default_buffer() !== with_buffer(default_buffer, AllocBuffer(100))
end
