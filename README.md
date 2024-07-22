- [Basics](#basics)
- [Important notes](#important-notes)
- [Concurrency and parallelism](#concurrency-and-parallelism)
- [Allocators provided by Bumper](#allocators-provided-by-bumper)
- [Creating your own allocator types](#creating-your-own-allocator-types)
- [Usage with StaticCompiler.jl](#usage-with-staticcompilerjl)
- [Docstrings](Docstrings.md)


# Bumper.jl

Bumper.jl is a package that aims to make working with bump allocators (also known as arena allocators)
easier and safer. You can dynamically allocate memory to these bump allocators, and reset
them at the end of a code block, just like Julia's stack. Allocating to a bump allocator with Bumper.jl
can be just as efficient as stack allocation. Bumper.jl is still a young package, and may have bugs. 
Let me know if you find any.

If you use Bumper.jl, please consider submitting a sample of your use-case so I can include it in the test suite.

## Basics 

Bumper.jl has a task-local default allocator, using a *slab allocation strategy* which can dynamically
grow to arbitary sizes.

The simplest way to use Bumper is to rely on its default buffer implicitly like so:

``` julia
using Bumper

function f(x)
    # Set up a scope where memory may be allocated, and does not escape:
    @no_escape begin
        # Allocate a `UnsafeVector{eltype(x)}` (see UnsafeArrays.jl) using memory from the default buffer.
        y = @alloc(eltype(x), length(x))
        # Now do some stuff with that vector:
        y .= x .+ 1
        sum(y) # It's okay for the sum of y to escape the block, but references to y itself must not do so!
    end
end

f([1,2,3])
```
```
9
```

When you use `@no_escape`, you are promising that the code enclosed in the macro will not leak **any** memory
created by `@alloc`. That is, you are *only* allowed to do intermediate `@alloc` allocations inside a `@no_escape` block,
and the lifetime of those allocations is the block. **This is important.** Once a `@no_escape` block finishes running, it
will reset its internal state to the position it had before the block started, potentially overwriting or freeing any 
arrays which were created in the block.

In addition to `@alloc` for creating arrays, you can use `@alloc_ptr(n)` to get an `n`-byte pointer (of type
`Ptr{Nothing}`) directly.

Let's compare the performance of `f` to the equivalent with an intermediate heap allocation:

``` julia
using BenchmarkTools
@benchmark f(x) setup=(x = rand(1:10, 30))
```

```
BenchmarkTools.Trial: 10000 samples with 995 evaluations.
 Range (min … max):  28.465 ns … 49.843 ns  ┊ GC (min … max): 0.00% … 0.00%
 Time  (median):     28.718 ns              ┊ GC (median):    0.00%
 Time  (mean ± σ):   28.840 ns ±  0.833 ns  ┊ GC (mean ± σ):  0.00% ± 0.00%

  ▃▄▂▇█▅▆▇▅▂▂▁▁▂▁                                             ▂
  ██████████████████▆▇▅▄▅▅▅▆▃▄▄▁▃▄▄▃▄▃▁▁▁▁▁▃▁▁▁▄▅▅▅▅▄▄▃▄▁▃▃▃▄ █
  28.5 ns      Histogram: log(frequency) by time      31.5 ns <

 Memory estimate: 0 bytes, allocs estimate: 0.
```

and

``` julia
function g(x::Vector{Int})
    y = x .+ 1
    sum(y)
end

@benchmark g(x) setup=(x = rand(1:10, 30))
```
```
BenchmarkTools.Trial: 10000 samples with 993 evaluations.
 Range (min … max):  32.408 ns …  64.986 μs  ┊ GC (min … max):  0.00% … 99.87%
 Time  (median):     37.443 ns               ┊ GC (median):     0.00%
 Time  (mean ± σ):   55.929 ns ± 651.009 ns  ┊ GC (mean ± σ):  14.68% ±  5.87%

  ▆█▅▃▁▁▁▁                       ▁▁ ▁                       ▂▁ ▁
  ████████▇██▅▄▃▄▁▁▃▁▁▁▁▁▁▁▁▃▃▁▁██████▇▇▅▁▄▃▃▃▁▁▃▁▁▁▄▃▄▅▄▄▅▇██ █
  32.4 ns       Histogram: log(frequency) by time       227 ns <

 Memory estimate: 304 bytes, allocs estimate: 1.
```

So, using Bumper.jl in this benchmark gives a slight speedup relative to regular julia `Vector`s,
and a major increase in performance *consistency* due to the lack of heap allocations.

However, we can actually go a little faster better if we're okay with manually passing around a buffer.
The way I invoked `@no_escape` and `@alloc` implicitly used the task's default buffer, and fetching that
default buffer is not as fast as using a `const` global variable, because Bumper.jl is trying to protect
you against concurrency bugs (more on that later).

If we provide the allocator to `f` explicitly, we go even faster:

``` julia
function f(x, buf)
    @no_escape buf begin # <----- Notice I specified buf here
        y = @alloc(Int, length(x)) 
        y .= x .+ 1
        sum(y)
    end
end

@benchmark f(x, buf) setup = begin
    x   = rand(1:10, 30)
    buf = default_buffer()
end
```
```
BenchmarkTools.Trial: 10000 samples with 997 evaluations.
 Range (min … max):  19.425 ns … 40.367 ns  ┊ GC (min … max): 0.00% … 0.00%
 Time  (median):     19.494 ns              ┊ GC (median):    0.00%
 Time  (mean ± σ):   19.620 ns ±  0.983 ns  ┊ GC (mean ± σ):  0.00% ± 0.00%

  █▅                                                          ▁
  ██▅█▇▄▃▄▄▃▃▃▄▅▄▅▄▅▄▇▇▅▄▄▅▆▅▅▅▄▄▄▁▄▃▃▃▁▁▄▃▃▄▁▁▁▁▃▃▃▁▄▄▃▁▄▃▁▃ █
  19.4 ns      Histogram: log(frequency) by time      25.3 ns <

 Memory estimate: 0 bytes, allocs estimate: 0.
```

If you manually specify a buffer like this, it is your responsibility to ensure that you don't have
multiple concurrent tasks using that buffer at the same time.

Running `default_buffer()` will give you the current task's default buffer. You can explicitly construct
your own `N` byte buffer by calling `AllocBuffer(N)`, or you can create a buffer which can dynamically
grow by calling `SlabBuffer()`. `AllocBuffer`s are *slightly* faster than `SlabBuffer`s, but will throw 
an error if you overfill them.

## Important notes

- `@no_escape` blocks can be nested as much as you want, just don't let references outlive the specific block they were created in.
- At the end of a `@no_escape` block, all memory allocations from inside that block are erased and the buffer is reset to its previous state
- The `@alloc` marker can only be used directly inside of a `@no_escape` block, and it will always use the buffer that the
  corresponding `@no_escape` block uses.
- You cannot use `@alloc` from a different concurrent task than its parent `@no_escape` block as this can cause concurrency bugs. 
- If for some reason you need to be able to use `@alloc` outside of the scope of the `@no_escape` block, there is a
  function  =`Bumper.alloc!(bug, T, n...)`= which takes in an explicit buffer `buf` and uses it to allocate an array of
  element type `T`, and dimensions `n...`. Using this is not as safe as `@alloc` and not recommended.
- Bumper.jl only supports `isbits` types. You cannot use it for allocating vectors containing mutable, abstract, or
  other pointer-backed objects. 
- As mentioned previously, *Do not allow any array which was initialized inside a* `@no_escape`
  *block to escape the block.* Doing so will cause incorrect results.
- If you accidentally overfill a buffer, via e.g. a memory leak and need to reset the buffer, use
  `Bumper.reset_buffer!` to do this.
- You are not allowed to use `return` or `@goto` inside a `@no_escape` block, since this could compromise the cleanup it performs after the block finishes.


## Concurrency and parallelism

<details><summary>Click me!</summary>
<p>

Every task has its own *independent* default buffer. A task's buffer is only created if it is
used, so this does not slow down the spawning of Julia tasks in general. Here's a demo
showing that the default buffers are different:

``` julia
using Bumper
let b = default_buffer() # The default buffer on the main task
    t = @async default_buffer() # Get the default buffer on an asychronous task
    fetch(t) === b
end
```
```
false
```

Whereas if we don't spawn any tasks, there is no unnecessary buffer creation:

``` julia
let b = default_buffer()
    b2 = default_buffer() 
    b2 === b
end
```
```
true
```

Because of this, we don't have to worry about `@no_escape begin ... @alloc() ... end` blocks on
different threads or tasks interfering with each other, so long as they are only operating on
buffers local to that task or the `default_buffer()`.

</details>
</p>

## Allocators provided by Bumper

<details><summary>Click me!</summary>
<p>

### SlabBuffer

`SlabBuffer` is a slab-based bump allocator which can dynamically grow to hold an arbitrary amount of memory.
Small allocations from a `SlabBuffer` will live within a specific slab of memory, and if that slab fills up, 
a new slab is allocated and future allocations will then happen on that slab. Small allocations are stored 
in slabs of size `SlabSize` bytes (default 1 megabyte), and the list of live slabs are tracked in a field called 
`slabs`. Allocations which are too large to fit into one slab are stored and tracked in a field called
`custom_slabs`.

`SlabBuffer`s are nearly as fast as stack allocation (typically up to within a couple of nanoseconds) for typical
use. One potential performance pitfall is if that `SlabBuffer`'s current position is at the end of a slab, then
the next allocation will be slow because it requires a new slab to be created. This means that if you do something
like

``` julia
buf = SlabBuffer{N}()
@no_escape buf begin
    @alloc(Int8, N÷2 - 1) # Take up just under half the first slab
    @alloc(Int8, N÷2 - 1) # Take up another half of the first slab
    # Now buf should be practically out of room. 
    for i in 1:1000
        @no_escape buf begin
            y = @alloc(Int8, 10) # This will allocate a new slab because there's no room
            f(y)
        end # At the end of this block, we delete the new slab because it's not needed.
    end
end
```

then the inner loop will run slower than normal because at each iteration, a new slab of size `N` bytes must be freshly
allocated. This should be a rare occurance, but is possible to encounter.


Do not manipulate the fields of a SlabBuffer that is in use.

### AllocBuffer

`AllocBuffer{StorageType}` is a very simple bump allocator that could be used to store a fixed amount of memory of type
`StorageType`, so long as `::StoreageType` supports `pointer`, and `sizeof`. If it runs out of memory to allocate, an error
will be thrown. By default, `AllocBuffer` stores a `Vector{UInt8}` of `1` megabyte.

Allocations using `AllocBuffer`s should be just as fast as stack allocation.

Do not manually manipulate the fields of an AllocBuffer that is in use.

</details>
</p>

## Creating your own allocator types

<details><summary>Click me!</summary>
<p>

Bumper.jl's `SlabBuffer` type is very flexible and fast, and so should almost always be preferred, but you
may have specific use-cases where you want to use a different design or make different tradeoffs, but want
to be able to interoperate with Bumper.jl's other features. Hence, Bumper.jl provides an API for you to hook
custom allocator types into it.

When someone writes 

``` julia
@no_escape buf begin
    y = @alloc(T, n, m, o)
    f(y)
end 
```
this turns into the equivalent of

``` julia
begin
    local cp = Bumper.checkpoint_save(buf)
    local result = begin 
        y = Bumper.alloc!(buf, T, n, m, o)
        f(y)
    end
    Bumper.checkpoint_restore!(cp)
    result
end
```
`checkpoint_save` should save the state of `buf`, `alloc!` should create an array using memory from `buf`, and `checkpoint_restor!` needs to reset `buf` to the state it was in when the checkpoint was created.

Hence, in order to use your custom allocator with Bumper.jl, all you need to write is the following methods:
+ `Bumper.alloc_ptr!(::YourAllocator, n::Int)::Ptr{Nothing}` which returns a pointer that can hold up to `n` bytes, and should be created from memory supplied with your allocator type however you see fit.
  + Alternatively, you could implement `Bumper.alloc!(::YourAllocator, ::Type{T}, s::Vararg{Integer})` which should return a multidimensional array whose sizes are determined by `s...`, created from memory supplied by your custom allocator. The default implementation of this method calls `Bumper.alloc_ptr!`.
+ `Bumper.checkpoint_save(::YourAllocator)::YourAllocatorCheckpoint` which saves whatever information your allocator needs to save in order to later on deallocate all objects which were created after `checkpoint_save` was called.
+ `checkpoint_restore!(::YourAllocatorCheckpoint)` which resets the allocator back to the state it was in when the checkpoint was created.


Let's look at a concrete example where we make our own simple copy of `AllocBuffer`:

``` julia
mutable struct MyAllocBuffer
    buf::Vector{UInt8} # The memory chunk we'll use for allocations
    offset::UInt       # A simple offset saying where the current position of the allocator is.
	
    #Default constructor
    MyAllocBuffer(n::Int) = new(Vector{UInt8}(undef, n), UInt(0))
end

struct MyCheckpoint
    buf::MyAllocBuffer # The buffer we want to store
    offset::UInt       # The buffer's offset when the checkpoint was created
end

function Bumper.alloc_ptr!(b::MyAllocBuffer, sz::Int)::Ptr{Cvoid}
    ptr = pointer(b.buf) + b.offset
    b.offset += sz
    b.offset > sizeof(b.buf) && error("alloc: Buffer out of memory.")
    ptr
end

function Bumper.checkpoint_save(buf::MyAllocBuffer)
    MyCheckpoint(buf, buf.offset)
end
function Bumper.checkpoint_restore!(cp::MyCheckpoint)
    cp.buf.offset = cp.offset
    nothing
end
```
that's it!

``` julia
julia> let x = [1, 2, 3], buf = MyAllocBuffer(100)
           @btime f($x, $buf)
       end
  9.918 ns (0 allocations: 0 bytes)
9
```

As a bonus, this isn't required, but if you want to have functionality like `default_buffer`, it can be simply implemented as follows:

``` julia
#Some default size, say 16kb
MyAllocBuffer() = MyAllocBuffer(16_000)

const default_buffer_key = gensym(:my_buffer)
function Bumper.default_buffer(::Type{MyAllocBuffer})
    get!(() -> MyAllocBuffer(), task_local_storage(), default_buffer_key)::MyAllocBuffer
end
```

You may also want to implemet `Bumper.reset_buffer!` for refreshing you allocator to a freshly initialized state.

</details>
</p>

## Usage with StaticCompiler.jl

<details><summary>Click me!</summary>
<p>

Bumper.jl is in the process of becoming a dependancy of 
[StaticTools.jl](https://github.com/brenhinkeller/StaticTools.jl) (and thus 
[StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl)), which extends Bumper.jl 
with a new buffer type, `MallocSlabBuffer` which is like `SlabBuffer` but designed to work
without needing Julia's runtime at all. This allows for code like the following

``` julia
using Bumper, StaticTools
function times_table(argc::Int, argv::Ptr{Ptr{UInt8}})
    argc == 3 || return printf(c"Incorrect number of command-line arguments\n")
    rows = argparse(Int64, argv, 2)            # First command-line argument
    cols = argparse(Int64, argv, 3)            # Second command-line argument

    buf = MallocSlabBuffer()
    @no_escape buf begin
        M = @alloc(Int, rows, cols)
        for i=1:rows
            for j=1:cols
                M[i,j] = i*j
            end
        end
        printf(M)
    end
    free(buf)
end

using StaticCompiler
filepath = compile_executable(times_table, (Int64, Ptr{Ptr{UInt8}}), "./")
```
giving
```
shell> ./times_table 12, 7
1   2   3   4   5   6   7
2   4   6   8   10  12  14
3   6   9   12  15  18  21
4   8   12  16  20  24  28
5   10  15  20  25  30  35
6   12  18  24  30  36  42
7   14  21  28  35  42  49
8   16  24  32  40  48  56
9   18  27  36  45  54  63
10  20  30  40  50  60  70
11  22  33  44  55  66  77
12  24  36  48  60  72  84
```



</details>
</p>

## Docstrings
See the full list of docstrings [here](Docstrings.md).
