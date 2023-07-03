# machine code generation

# final preparations for the module to be compiled to machine code
# these passes should not be run when e.g. compiling to write to disk.
function prepare_execution!(@nospecialize(job::CompilerJob), mod::LLVM.Module)
        global current_job
        current_job = job
    if use_newpm
        @dispose pb=PassBuilder() mpm=NewPMModulePassManager(pb) begin
            add!(mpm, GlobalOptPass())
            add!(mpm) do m, mam
                if resolve_cpu_references!(m)
                    return no_analyses_preserved()
                else
                    return all_analyses_preserved()
                end
            end
            add!(mpm, GlobalDCEPass())
            add!(mpm, StripDeadPrototypesPass())
            analysis_managers() do lam, fam, cam, mam
                register!(pb, lam, fam, cam, mam)
                dispose(run!(mpm, mod, mam))
            end
        end
    else
        @dispose pm=ModulePassManager() begin

            global_optimizer!(pm)

            add!(pm, ModulePass("ResolveCPUReferences", resolve_cpu_references!))

            global_dce!(pm)
            strip_dead_prototypes!(pm)

            run!(pm, mod)
        end
    end

    return
end

# some Julia code contains references to objects in the CPU run-time,
# without actually using the contents or functionality of those objects.
#
# prime example are type tags, which reference the address of the allocated type.
# since those references are ephemeral, we can't eagerly resolve and emit them in the IR,
# but at the same time the GPU can't resolve them at run-time.
#
# this pass performs that resolution at link time.
function resolve_cpu_references!(mod::LLVM.Module)
    job = current_job::CompilerJob
    changed = false

    for f in functions(mod)
        fn = LLVM.name(f)
        if isdeclaration(f) && !LLVM.isintrinsic(f) && startswith(fn, "jl_")
            # eagerly resolve the address of the binding
            address = ccall(:jl_cglobal, Any, (Any, Any), fn, UInt)
            dereferenced = unsafe_load(address)
            dereferenced = LLVM.ConstantInt(dereferenced)

            function replace_bindings!(value)
                changed = false
                for use in uses(value)
                    val = user(use)
                    if isa(val, LLVM.ConstantExpr)
                        # recurse
                        changed |= replace_bindings!(val)
                    elseif isa(val, LLVM.LoadInst)
                        # resolve
                        replace_uses!(val, dereferenced)
                        unsafe_delete!(LLVM.parent(val), val)
                        # FIXME: iterator invalidation?
                        changed = true
                    end
                end
                changed
            end

            changed |= replace_bindings!(f)
        end
    end

    return changed
end


function mcgen(@nospecialize(job::CompilerJob), mod::LLVM.Module, format=LLVM.API.LLVMAssemblyFile)
    tm = llvm_machine(job.config.target)

    return String(emit(tm, mod, format))
end
