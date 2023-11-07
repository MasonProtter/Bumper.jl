using Bumper

open("Docstrings.md", "w+") do io
    println(io, "# Docstrings\n")
    println(io, "## User API\n")
    for s ∈ (Symbol("@no_escape"), Symbol("@alloc"), :default_buffer, :SlabBuffer, :reset_buffer!, :with_buffer,)
        println(io, Base.Docs.doc(Base.Docs.Binding(Bumper, s)))
        println(io, "---------------------------------------")
    end
    println(io, "## Allocator API\n")
    for s ∈ (:alloc_ptr!,  :alloc!, :checkpoint_save, :checkpoint_restore!)
        println(io, Base.Docs.doc(Base.Docs.Binding(Bumper, s)))
        println(io, "---------------------------------------")
    end
end
