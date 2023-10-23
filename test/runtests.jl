using Test, Bumper

# set_default_buffer_size!(1000)

function f(x, buf=default_buffer())
    @no_escape buf begin
        y = @alloc(Int, length(x))
        y .= x .+ 1
        sum(y)
    end
end

function g(x, buf::AllocBuffer)
    @no_escape buf begin 
        y = Bumper.alloc(Int, buf, length(x)) 
        y .= x .+ 1
        sum(y)
    end
end



@testset "basic" begin
    v = [1,2,3]
    b = AllocBuffer(100)

    @test f(v) == 9
    @test b.offset == 0
    @test f(v, b) == 9
    @test b.offset == 0
    @test g(v, b) == 9
    @test b.offset == 0
    
    @test @allocated(f(v)) == 0
    @test @allocated(f(v, b)) == 0
    @test @allocated(g(v, b)) == 0

    @no_escape b begin
        y = @alloc(Int, length(v))
        off1 = b.offset
        @no_escape b begin
            z = @alloc(Int, length(v))
            
            @test pointer(z) != pointer(y)
            @test Int(pointer(z)) == Int(pointer(y)) + 8*length(v)
            @test b.offset == off1 + 8*length(v)
        end
        b2 = AllocBuffer(100)
        @no_escape b2 begin
            z = @alloc(Int, length(v))
            @test pointer(z) == pointer(b2) 
        end
        
        @test b.offset == off1
    end

    let b1 = default_buffer()
        b2 = AllocBuffer(Vector{UInt8}(undef, 100))
        with_buffer(b2) do
            @test default_buffer() == b2
        end
        @test default_buffer() == b1
    end
    let b2 = AllocBuffer(Vector{Int}(undef, 100))
        @test_throws MethodError with_buffer(b2) do
            default_buffer()
        end 
    end

    @test_throws Exception Bumper.alloc(Int, b, 100000)
    Bumper.reset_buffer!(b)
    Bumper.reset_buffer!()
    @test_throws Exception @no_escape begin
        alloc(Int, 10)
    end

    @no_escape b begin
        v = @alloc_nothrow(Int, 100000)
        @test 8*length(v) > length(b.buf)
    end

    @test_throws Exception @no_escape begin
        @sync Threads.@spawn begin
            @alloc(Int, 10)
        end
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
    @test_throws Exception Bumper.Internals._no_escape_macro(
        :(default_buffer()),
        :(@label lab),
        @__MODULE__()
    )
end

@testset "tasks and buffer switching" begin
    @test default_buffer() === default_buffer()
    @test default_buffer() !== fetch(@async default_buffer())

    @test default_buffer() !== with_buffer(default_buffer, AllocBuffer(100))
end
