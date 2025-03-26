using Test, Bumper

function f(x, buf=default_buffer())
    @no_escape buf begin
        y = @alloc(eltype(x), length(x))
        y .= x .+ 1
        sum(y)
    end
end

function g(x, buf)
    @no_escape buf begin
        y = Bumper.alloc!(buf, eltype(x), length(x))
        y .= x .+ 1
        sum(y)
    end
end



@testset "basic" begin
    v = [1,2,3]
    b = AllocBuffer(100)

    @test f(v) == 9
    @test default_buffer().current == default_buffer().slabs[1]
    @test f(v, b)  == 9
    @test b.offset == 0
    @test g(v, b)  == 9
    @test b.offset == 0

    @test @allocated(f(v)) == 0
    @test @allocated(f(v, b)) == 0
    @test @allocated(g(v, b)) == 0

    sb = SlabBuffer{16_384}()
    @no_escape sb begin
        p = sb.current
        e = sb.slab_end
        x = @alloc(Int8, 16_384 ÷ 2 - 1)
        x = @alloc(Int8, 16_384 ÷ 2 - 1)
        for i ∈ 1:5
            @no_escape sb begin
                @test sb.current == p + 16_382
                @test p <= sb.current <= e
                y = @alloc(Int, 10)
                @test !(p <= sb.current <= e)
            end
        end
        z = @alloc(Int, 100_000)
        @test sb.current == p + 16_382
        @test sb.slab_end == e
        @test !(p <= pointer(z) <= e)
        @test pointer(z) == sb.custom_slabs[end]
    end
    @test isempty(sb.custom_slabs)
    @test sb.current == sb.slabs[1]
    @test sb.slab_end == sb.current + 16_384


    @no_escape sb begin
        current = sb.current
        p = @alloc_ptr(10)
        @test p == current
        @test sb.current == p + 10
        p2 = @alloc_ptr(100_000)
        @test p2 == sb.custom_slabs[end]
    end

    try
        @no_escape sb begin
            x = @alloc(Int8, 16_383)
            y = @alloc(Int8, 100_000)
            z = @alloc(Int8, 10)
            throw("Boo!")
        end
    catch e
        @test length(sb.custom_slabs) == 1
        @test length(sb.slabs) == 2
        @test sb.current  == sb.slabs[2] + 10

        Bumper.reset_buffer!(sb)

        @test isempty(sb.custom_slabs)
        @test length(sb.slabs) == 1
        @test sb.current  == sb.slabs[1]
    end

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
            @test pointer(z) == pointer(b2.buf)
        end

        @test b.offset == off1
    end

    @test_throws Exception Bumper.alloc!(b, Int, 100000)
    Bumper.reset_buffer!(b)
    Bumper.reset_buffer!()

    @test_throws Exception @no_escape begin
        @alloc(Int, 10)
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
        :(return sum(@alloc(Int, 10) .= 1)),
        @__MODULE__()
    )
    @test_throws Exception Bumper.Internals._no_escape_macro(
        :(default_buffer()),
        :(@sneaky_return sum(@alloc(Int, 10) .= 1)),
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

    let b1 = default_buffer(AllocBuffer)
        b2 = AllocBuffer(Vector{UInt8}(undef, 100))
        with_buffer(b2) do
            @test default_buffer(AllocBuffer) == b2
        end
        @test default_buffer(AllocBuffer) == b1
    end
    let b2 = AllocBuffer(Vector{Int}(undef, 100))
        @test_throws MethodError with_buffer(b2) do
            default_buffer()
        end
    end

    @test default_buffer() === default_buffer()
    @test default_buffer() !== fetch(@async default_buffer())
    @test default_buffer() !== fetch(Threads.@spawn default_buffer())

    @test default_buffer() !== with_buffer(default_buffer, SlabBuffer())
    @test default_buffer(AllocBuffer) === default_buffer(AllocBuffer)
    @test default_buffer(AllocBuffer) !== with_buffer(() -> default_buffer(AllocBuffer), AllocBuffer())
end

@testset "show" begin
    b = AllocBuffer(100)
    @test sprint(show, b) == "AllocBuffer{Vector{UInt8}}(…used=0, capacity=100…)"
    Bumper.alloc!(b, UInt8, 50)
    @test sprint(show, b) == "AllocBuffer{Vector{UInt8}}(…used=50, capacity=100…)"
    Bumper.alloc!(b, UInt8, 50)
    @test sprint(show, b) == "AllocBuffer{Vector{UInt8}}(…used=100, capacity=100…)"

    @static if VERSION > v"1.8-"
        try
            Bumper.alloc!(b, UInt8, 1)
        catch e
            @test sprint(show, b) == "AllocBuffer{Vector{UInt8}}(…used=100, capacity=100…)"
        else
            @test false
        end
    end

end
