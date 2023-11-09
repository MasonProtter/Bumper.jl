module StaticCompilerExt

using Bumper
using StaticCompiler: StaticCompiler, @device_override, @print_and_throw, @c_str
using StaticCompiler.StaticTools

@device_override @noinline Bumper.AllocBufferImpl.oom_error() =
    @print_and_throw c"alloc: Buffer out of memory. This might be a sign of a memory leak."

@device_override @noinline Bumper.Internals.esc_err() =
    @print_and_throw c"Tried to return a PtrArray from a `no_escape` block. If you really want to do this, evaluate Bumper.allow_ptrarray_to_escape() = true"

StaticTools.free(v::AllocBuffer{<:MallocArray}) = StaticTools.free(v.buf)
function Bumper.AllocBufferImpl.AllocBuffer(::Type{<:MallocArray}, n::Int = Bumper.AllocBufferImpl.default_buffer_size)
    AllocBuffer(MallocArray{UInt8}(undef, n))
end

# Just to make the compiler's life a little easier, let's not make it fetch and elide the current task
# since tasks don't actually exist on-device.
@device_override Bumper.Internals.get_task() = 0


end # StaticCompilerExt
