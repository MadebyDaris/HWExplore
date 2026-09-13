# Macros.jl
# Entry-point macros for HWExplore hardware synthesis.
#
# @synthesize — the primary user-facing macro (Phase 2 entry point)
# @nexus_accelerate — legacy macro (kept for backward compatibility)

export @synthesize

# ============================================================================
# @synthesize — Primary Entry Point
# ============================================================================

"""
    @synthesize f(a::T1, b::T2, ...)
    @synthesize f(a, b, ...) types=Tuple{T1, T2}

Synthesize a Julia function into a hardware Data-Flow Graph.

This macro:
1. Captures the function and its argument types
2. Extracts the typed SSA IR via IRTools (Phase 2)
3. Translates the IR into an HWExplore DFG (Phase 3)
4. Returns a `(HWGraph, FSMGraph)` tuple ready for scheduling

# Examples

```julia
# With type annotations on the call expression:
graph, fsm = @synthesize my_func(Int32(0), Int32(0))

# Then pipe through the rest of the HWExplore pipeline:
schedule_asap!(graph)
emit_verilog(graph, "my_func.sv")
```

# Notes
- The arguments in the call expression are used only for type inference.
  Their values serve as representative inputs for IR extraction.
- The function must be type-stable for synthesis to succeed.
"""
macro synthesize(call_expr)
    # Validate: must be a function call expression
    if !Meta.isexpr(call_expr, :call)
        error("[HWExplore] @synthesize expects a function call expression, e.g. @synthesize f(Int32(0), Int32(0))")
    end

    func_name = call_expr.args[1]
    call_args = call_expr.args[2:end]

    # Generate code that:
    # 1. Evaluates the arguments to get concrete values (for type inference)
    # 2. Calls extract_and_translate with the function and inferred types
    quote
        let _f = $(esc(func_name)),
            _args = ($(map(esc, call_args)...),),
            _types = Tuple{typeof.(_args)...}

            extract_and_translate(_f, _types; name=$(string(func_name)))
        end
    end
end

# ============================================================================
# @nexus_accelerate — Legacy Macro (Backward Compatibility)
# ============================================================================

"""
    @nexus_accelerate function_definition

Legacy macro that intercepts a function definition and redirects it to
the HWExplore hardware compilation pipeline.

**Deprecated**: Use `@synthesize f(args...)` instead for the full Phase 2→3 pipeline.
"""
macro nexus_accelerate(fn_def)
    # 1. Validate and capture the function syntax (supports both standard and short forms)
    if !(@capture(fn_def, function name_(args__) body_ end) || @capture(fn_def, name_(args__) = body_))
        error("[HWExplore Compiler Error] Syntax error: @nexus_accelerate must be applied to a valid function definition.")
    end

    # 2. Extract arguments and type annotations
    arg_names = Symbol[]
    arg_types = Symbol[]

    for arg in args
        if @capture(arg, var_::T_)
            push!(arg_names, var)
            push!(arg_types, T)
        else
            push!(arg_names, arg)
            push!(arg_types, :Any) # Default fallback if no type annotation is provided
        end
    end


    # 3. Substitute the function body (prevents normal CPU execution)
    # Reconstructs a stub function that returns an interception tuple for Phase 2/3
    new_body = quote
        println("[HWExplore Exec] Function '$($(QuoteNode(name)))' was bypassed. Redirecting to HW compilation pipeline...")
        return (
            name = $(QuoteNode(name)),
            args = $arg_names,
            types = $arg_types
        )
    end

    # Reconstruct AST with modified body
    modified_function = :(function $name($(args...))
        $new_body
    end)

    return modified_function
end