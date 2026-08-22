# Deprecated
#
# Moving away from LLVM IR and targeting Julia’s Typed SSA IR (often casually
# referred to as the AST or lowered IR) to avoid the "LLVM optimization destruction" 
# problem
#
#   Pipeline:
#   Julia Function
#       └─► DFG Builder  (builds a DFG Graph)
#               └─► Optimization Passes  (e.g. loop unrolling, dead code elim)
#                       └─► DFG Graph  (ready for NexusV backend)
#export DFGNode, DFGEdge, DFGGraph, add_node!, add_edge!

"""
Represents a data dependency or flow between two DFG nodes.
"""
struct DFGEdge
    source_id::Int
    dest_id::Int
    source_port::Int
    dest_port::Int
end

"""
Represents an operation, instruction, or a constant value in the Data Flow Graph.
"""
mutable struct DFGNode
    id::Int
    opcode::Symbol          # e.g., :add, :mul, :load, :store, :const, :branch
    value::Any              # to hold constant values, variable names, or other metadata
    inputs::Vector{Int}     # node IDs that provide input to this node
    outputs::Vector{Int}    # node IDs that consume output from this node
end

"""
The top-level Data Flow Graph structure.
"""
mutable struct DFGGraph
    nodes::Dict{Int,DFGNode}
    edges::Vector{DFGEdge}
    next_id::Int            # Counter for unique node IDs

    DFGGraph() = new(Dict{Int,DFGNode}(), DFGEdge[], 1)
end

# --- Basic API Stubs ---

"""
    add_node!(graph::DFGGraph, opcode::Symbol, value=nothing) -> Int

Add a new node to the DFG and return its unique ID.
"""
function add_node!(graph::DFGGraph, opcode::Symbol, value::Any=nothing)
    id = graph.next_id
    graph.next_id += 1
    node = DFGNode(id, opcode, value, Int[], Int[])
    graph.nodes[id] = node
    return id
end

"""
    add_edge!(graph::DFGGraph, src_id::Int, dst_id::Int, src_port::Int=1, dst_port::Int=1)

Create a directed edge from the source node to the destination node.
"""
function add_edge!(graph::DFGGraph, src_id::Int, dst_id::Int, src_port::Int=1, dst_port::Int=1)
    push!(graph.edges, DFGEdge(src_id, dst_id, src_port, dst_port))
    push!(graph.nodes[src_id].outputs, dst_id)
    push!(graph.nodes[dst_id].inputs, src_id)
    return nothing
end
