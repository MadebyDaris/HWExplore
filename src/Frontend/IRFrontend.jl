# Provides the high-level entry point that captures a Julia function,
# extracts its typed SSA IR via IRTools, and preserves type information.

export extract_and_translate, extract_ir

using IRTools: IRTools, IR, @code_ir

"""
    extract_ir(f, argtypes::Type{<:Tuple})
Extract the IRTools IR for function `f` with the given argument types.
Returns the `IRTools.IR` object representing the typed SSA form.
"""
function extract_ir(f, argtypes::Type{<:Tuple})
    # IRTools.IR(Type...) expects typeof(f) as the first type, followed by arg types.
    # This is the IR(Ts::Type...; slots, prune) method from IRTools.Inner.Wrap.
    ir = IR(typeof(f), argtypes.parameters...)
    if ir === nothing
        error("[HWExplore] Failed to extract IR for $(nameof(f)) with types $argtypes. " *
              "Ensure the function is type-stable and does not use unsupported features.")
    end
    return ir
end

"""
    extract_ir(f, args...)
Extract the IRTools IR by inferring types from concrete arguments.
"""
function extract_ir(f, args...)
    types = Tuple{typeof.(args)...}
    return extract_ir(f, types)
end

"""
    extract_and_translate(f, argtypes::Type{<:Tuple}; name=nothing) → (HWGraph, FSMGraph)
Extract the IR for `f` with `argtypes` and translate it into an HWExplore Data-Flow Graph.
Returns a `(HWGraph, FSMGraph)` tuple ready for scheduling and Verilog emission.
"""
function extract_and_translate(f, argtypes::Type{<:Tuple}; name::Union{String,Nothing}=nothing)
    ir = extract_ir(f, argtypes)

    mod_name = name !== nothing ? name : string(nameof(f))

    graph, fsm = translate_ir_to_dfg(ir, mod_name; argtypes=argtypes)

    println("[HWExplore] Synthesized '$(mod_name)' → $(length(graph.nodes)) DFG nodes, " *
            "$(length(graph.graph_inputs)) inputs, $(length(graph.graph_outputs)) outputs")

    return (graph, fsm)
end

"""
    extract_and_translate(f, args...; name=nothing) → (HWGraph, FSMGraph)
Convenience overload: infer types from concrete arguments.
"""
function extract_and_translate(f, args...; name::Union{String,Nothing}=nothing)
    argtypes = Tuple{typeof.(args)...}
    return extract_and_translate(f, argtypes; name=name)
end