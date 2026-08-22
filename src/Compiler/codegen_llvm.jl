# Deprecated
#
#   Pipeline:
#   Julia Function
#       └─► GPUCompiler  (lowers to LLVM Module, a C++ object in memory)
#               └─► Optimization Passes  (e.g. loop unrolling, dead code elim)
#                       └─► LLVM Module  (ready for NexusV backend)
#
# This file provides:
#   - `get_llvm_ir`       : Compiles a Julia function → LLVM Module string.
#   - `apply_unroll_pass` : Runs LLVM's LoopUnrollPass on an existing module.
#   - `@nexus_unroll`     : Julia macro that annotates a for-loop for unrolling.
#                           At compile time it injects the unroll hint into the
#                           LLVM module after GPUCompiler has lowered the code.


# NexusV-specific GPUCompiler target & param
"""
    NexusVCompilerParams

Minimal `AbstractCompilerParams` implementation. GPUCompiler requires params type to create a `CompilerConfig`.
"""
struct NexusVCompilerParams <: GPUCompiler.AbstractCompilerParams end
"""
    NexusVTarget

Minimal `AbstractCompilerTarget` tells GPUCompiler to lower to the host machine's native LLVM target.
We reuse `GPUCompiler.NativeCompilerTarget` under the hood.
"""
const NexusVTarget = GPUCompiler.NativeCompilerTarget

GPUCompiler.runtime_module(::GPUCompiler.CompilerJob{<:Any,NexusVCompilerParams}) = NexusV



# NexusV get LLVM module using LLVM
"""
    get_llvm_module(func::Function, arg_types::Type...) -> LLVM.Module
Lower a Julia function to an LLVM Module using GPUCompiler.

Outputs an `LLVM.Module`, the C++ object managed inside Julia's LLVM context.
This is the starting point for all downstream NexusV optimization passes.
```julia
my_mac(a::Int32, b::Int32, c::Int32) = a * b + c
mod = get_llvm_module(my_mac, Int32, Int32, Int32)
println(mod)   # prints the LLVM IR text
```
"""
function get_llvm_module(func::Function, arg_types::Type...)
    target = NexusVTarget()
    params = NexusVCompilerParams()

    types_tuple = Tuple{arg_types...}

    mi = GPUCompiler.methodinstance(typeof(func), types_tuple)

    config = GPUCompiler.CompilerConfig(target, params; kernel=false)
    job = GPUCompiler.CompilerJob(mi, config)

    # Compile inside a fresh JuliaContext (owns the LLVM context lifetime)
    llvm_mod, _meta = GPUCompiler.JuliaContext() do ctx
        GPUCompiler.compile(:llvm, job)
    end

    return llvm_mod
end



# Compile Julia to LLVM IR
"""
    get_llvm_ir(func::Function, arg_types::Type...) -> String
Convenience wrapper: compiles `func` to LLVM IR and returns it as a `String`.
# Example
```julia
ir = get_llvm_ir(my_mac, Int32, Int32, Int32)
println(ir)
```
"""
function get_llvm_ir(func::Function, arg_types::Type...)
    mod = get_llvm_module(func, arg_types...)
    return string(mod)
end



# Optimization Passes Loop Unrolling
"""
    apply_unroll_pass(mod::LLVM.Module; factor::Int = 0, full::Bool = false) -> LLVM.Module

Run LLVM's **LoopUnrollPass** on the given module

This is the actual LLVM level unrolling it operates on the LLVM Module derived from GPU Compile
object, not on Julia AST hints. Call this *after* `get_llvm_module`.

# Arguments
- `mod`    : The `LLVM.Module` produced by `get_llvm_module`.
- `factor` : Number of times to replicate the loop body.
             `0` → let LLVM decide (uses default heuristics).
- `full`   : If `true`, fully unroll loops whose trip-count is statically known.

# Returns
The same `mod` (mutated in-place) with loops unrolled.

# How it works
LLVM's PassManager pipeline used here:
  1. `mem2reg`         – promotes stack allocations to SSA registers (required
                         before loop passes so induction variables are in SSA).
  2. `loop-simplify`  – normalises loop structure (single backedge, preheader).
  3. `indvars`        – canonicalises induction variables.
  4. `loop-unroll`    – performs the actual unrolling.
"""
function apply_unroll_pass(mod::LLVM.Module; factor::Int=0, full::Bool=false)
    LLVM.@dispose pm = LLVM.NewPMModulePassManager() begin
        # Prerequisite: lift allocas → SSA so the loop passes see clean IR
        LLVM.add!(pm, LLVM.NewPMFunctionPassManager() do fpm
            LLVM.add!(fpm, LLVM.PromoteMemoryToRegisterPass())
            LLVM.add!(fpm, LLVM.LoopSimplifyPass())
            LLVM.add!(fpm, LLVM.IndVarSimplifyPass())

            # LoopUnrollPass honour the user's factor / full flags
            if full
                LLVM.add!(fpm, LLVM.LoopUnrollPass(; full_unroll_max_count=-1))
            elseif factor > 0
                LLVM.add!(fpm, LLVM.LoopUnrollPass(; unroll_count=factor))
            else
                LLVM.add!(fpm, LLVM.LoopUnrollPass())
            end
        end)

        LLVM.run!(pm, mod)
    end

    return mod
end



# @nexus_unroll macro annotate Julia loops for LLVM unrolling
"""
    @nexus_unroll [factor=n] [full=true] for_loop

**NexusV loop-unroll annotation macro.**

Marks a `for` loop so that NexusV will apply LLVM's `LoopUnrollPass` after
GPUCompiler has lowered the enclosing function to an LLVM Module.

## How it is different from the hint approach

apply_unroll_pass` is called on the LLVM Module produced by `get_llvm_module`. LLVM physically unrolls the loop in the IR before the NexusV backend sees it.

## Parameters

| Keyword | Type | Default | Meaning |
|---------|------|---------|---------|
| `factor` | `Int` | `0` | Replicate loop body N times. `0` → LLVM heuristics. |
| `full`   | `Bool` | `false` | Fully unroll (entire loop → parallel hardware). |

## Example

```julia
# Define a kernel
function my_mac(a::Int32, b::Int32, c::Int32)
    result = Int32(0)
    @nexus_unroll factor=4 for i in 1:16
        result += a * b + c
    end
    return result
end

# Compile to LLVM 
mod = get_llvm_module(my_mac, Int32, Int32, Int32)

# Apply the unroll pass (factor comes from the macro's registration)
apply_unroll_pass(mod; factor = 4)

println(mod)   # IR now contains 4× unrolled loop body
```

## Full unroll for small, statically-bounded loops

```julia
function dot8(A::NTuple{8,Float32}, B::NTuple{8,Float32})
    s = 0.0f0
    @nexus_unroll full=true for i in 1:8
        s += A[i] * B[i]
    end
    return s
end
```
"""
macro nexus_unroll(args...)
    # Parse keyword arguments and the mandatory loop expression
    if isempty(args)
        error("@nexus_unroll requires at least a loop expression")
    end

    factor = 0
    full = false
    loop_expr = nothing

    if length(args) == 1
        # Bare form: @nexus_unroll for i in ...
        loop_expr = args[end]
    else
        # Keyword form: @nexus_unroll factor=(number) for i in ...
        for i in 1:(length(args)-1)
            arg = args[i]
            if Meta.isexpr(arg, :(=))
                kw, val = arg.args[1], arg.args[2]
                if kw == :factor
                    val isa Integer || error("@nexus_unroll: `factor` must be an integer, got $val")
                    factor = Int(val)
                elseif kw == :full
                    val isa Bool || error("@nexus_unroll: `full` must be true or false, got $val")
                    full = val
                else
                    error("@nexus_unroll: unknown keyword `$kw`. Valid keywords: factor, full")
                end
            else
                error("@nexus_unroll: expected keyword=value, got $arg")
            end
        end
        loop_expr = args[end]
    end

    # Validate: must be a for loop (while loops are not unrollable
    # by LLVM without extra analysis, so we keep it strict for now)
    Meta.isexpr(loop_expr, :for) ||
        error("@nexus_unroll expects a `for` loop, got: $(loop_expr.head)")

    # Register the unroll hint so downstream passes can query it
    # (uses the same thread-safe registry pattern as FPGA_Compiler)
    loop_id = UInt64(hash(loop_expr))

    return quote
        # Register the hint at runtime (safe across modules)
        NexusV.register_unroll_hint!($(loop_id), $(factor), $(full))

        # Execute the loop unchanged — CPU simulation semantics are preserved
        $(esc(loop_expr))
    end
end

# Global unroll-hint registry (mirrored from FPGA_Compiler pattern)
# Downstream code calls: NexusV.get_unroll_hint(loop_id) -> (factor=4, full=false)
# and uses it to call apply_unroll_pass with the right settings.

const _UNROLL_HINTS = Dict{UInt64,NamedTuple{(:factor, :full),Tuple{Int,Bool}}}()
const _REGISTRY_LOCK = ReentrantLock()

"""
    register_unroll_hint!(id::UInt64, factor::Int, full::Bool)

Register an unroll hint produced by `@nexus_unroll` at the given loop hash.
"""
function register_unroll_hint!(id::UInt64, factor::Int, full::Bool)
    lock(_REGISTRY_LOCK) do
        _UNROLL_HINTS[id] = (factor=factor, full=full)
    end
end

"""
    get_unroll_hint(id::UInt64) -> NamedTuple or nothing

Retrieve the unroll hint for a loop identified by its hash.
Returns `nothing` if the loop was not annotated.
"""
function get_unroll_hint(id::UInt64)
    lock(_REGISTRY_LOCK) do
        get(_UNROLL_HINTS, id, nothing)
    end
end

"""
    clear_unroll_hints!()

Clear all registered unroll hints (useful for unit tests).
"""
function clear_unroll_hints!()
    lock(_REGISTRY_LOCK) do
        empty!(_UNROLL_HINTS)
    end
end
