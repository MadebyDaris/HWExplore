module DFG_Builder

export Opcode, OP_ARG, OP_CONST, OP_ADD, OP_SUB, OP_MUL, OP_RET
export OP_SHR, OP_SHL, OP_AND, OP_OR, OP_XOR, OP_MOD, OP_MUX, OP_EQ, OP_NEQ, OP_LT, OP_LE, OP_GT, OP_GE, OP_LTU, OP_LEU, OP_GTU, OP_GEU, OP_PRIMITIVE
export OP_REG  # Registered D flip-flop: clocked at state boundaries (FSM backend only)
export DFGNode, HWGraph, OP_LATENCY

@enum Opcode begin
    OP_ARG    # Input argument (maps to rs1, rs2, ...)
    OP_CONST  # Literal constant embedded in the graph
    OP_ADD
    OP_SUB
    OP_MUL
    OP_SHR    # Logical shift right
    OP_SHL    # Logical shift left
    OP_AND    # Bitwise AND
    OP_OR     # Bitwise OR
    OP_XOR    # Bitwise XOR
    OP_MOD    # Modulo (remainder)
    OP_MUX # Ternary select: cond ? a : b  (3 inputs)
    OP_RET    # Return / output node
    OP_EQ     # Equality (used for mux select)
    OP_NEQ    # Inequality (used for mux select)
    OP_LT     # Less than (signed)
    OP_LE     # Less than or equal (signed)
    OP_GT     # Greater than (signed)
    OP_GE     # Greater than or equal (signed)
    OP_LTU    # Less than (unsigned)
    OP_LEU    # Less than or equal (unsigned)
    OP_GTU    # Greater than (unsigned)
    OP_GEU    # Greater than or equal (unsigned)
    OP_PRIMITIVE
    OP_REG      # Registered D flip-flop: clocked at state boundaries (FSM backend only)
end

# Default cycle latency per opcode.
# OP_ARG / OP_CONST / OP_RET have 0 latencym no consumption compute cycles.
const OP_LATENCY = Dict{Opcode,Int}(
    OP_ARG => 0,
    OP_CONST => 0,
    OP_RET => 0,
    OP_ADD => 1,
    OP_SUB => 1,
    OP_MUL => 2,
    OP_SHR => 1,
    OP_SHL => 1,
    OP_AND => 1,
    OP_OR => 1,
    OP_XOR => 1,
    OP_MOD => 3,
    OP_MUX => 1,
    OP_EQ => 1,
    OP_NEQ => 1,
    OP_LT => 1,
    OP_LE => 1,
    OP_GT => 1,
    OP_GE => 1,
    OP_LTU => 1,
    OP_LEU => 1,
    OP_GTU => 1,
    OP_GEU => 1,
    OP_REG => 1,   # One-cycle registered capture
)

"""
    DFGNode(id, op, bit_width, inputs, const_val, scheduled_cycle, latency,
            primitive, primitive_params[, julia_type])

One node in a [`HWGraph`](@ref) dataflow graph.

- `id`: unique integer identifier.
- `op`: the `Opcode` this node performs.
- `bit_width`: data width in bits (32 by default).
- `inputs`: IDs of the nodes producing this node's operands, in operand order.
- `const_val`: only set for `OP_CONST` nodes.
- `scheduled_cycle`: filled in by the scheduler (e.g. `schedule_asap!`); `0` means unscheduled.
- `latency`: number of clock cycles this operation requires.
- `primitive`: for `OP_PRIMITIVE` nodes, the registered primitive-library key to instantiate instead of auto-scheduling.
- `primitive_params`: extra parameters passed to that primitive.
- `julia_type`: the pre-lowered Julia type, preserved for downstream use; defaults to `nothing`.
"""
mutable struct DFGNode
    id::Int
    op::Opcode
    bit_width::Int
    inputs::Vector{Int}
    const_val::Union{Nothing,Int}
    scheduled_cycle::Int
    latency::Int
    primitive::Union{Nothing,Symbol}
    primitive_params::Dict{Symbol,Any}
    julia_type::Any
end

# Backward-compatible 9-arg constructor — julia_type defaults to nothing
DFGNode(id, op, bw, inputs, cv, sc, lat, prim, pp) =
    DFGNode(id, op, bw, inputs, cv, sc, lat, prim, pp, nothing)

"""
    HWGraph(name, nodes, graph_inputs, graph_outputs[, latency])

A dataflow graph: the top-level unit HWExplore schedules and emits as one
SystemVerilog module. Build one directly, or get one back from
`extract_and_translate` (see the "Guide to Using HWExplore" in the package
documentation).

- `name`: the emitted Verilog module name.
- `nodes`: `id => `[`DFGNode`](@ref) for every node in the graph.
- `graph_inputs`: ordered [`DFGNode`](@ref) IDs of the `OP_ARG` nodes — operand order, mapped to `rs1_i`, `rs2_i`, ... by the emitter.
- `graph_outputs`: ordered [`DFGNode`](@ref) IDs of the `OP_RET` nodes.
- `latency`: total pipeline depth in cycles; `0` until a scheduler (e.g. `schedule_asap!`) fills it in. The convenience constructor `HWGraph(name, nodes, ins, outs)` defaults this to `0`.
"""
mutable struct HWGraph
    name::String
    nodes::Dict{Int,DFGNode}
    graph_inputs::Vector{Int}
    graph_outputs::Vector{Int}
    latency::Int
end

# Convenience constructor — latency defaults to 0 (unscheduled)
HWGraph(name, nodes, ins, outs) = HWGraph(name, nodes, ins, outs, 0)

end # module DFG_Builder