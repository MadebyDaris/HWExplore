
# Analysis pass.
# Computes liveness across FSM state boundaries, identifies loop-carried
# OP_REG nodes, detects back-edges, and produces a topological ordering of
# Must be included after DFG_Builder and IRTranslator are in scope.

export FSMAnalysis, analyse_fsm

"""
    FSMAnalysis
Result of the cross-state liveness analysis over an (HWGraph, FSMGraph) pair.
Fields

- `live_across`  : Set of DFGNode IDs whose value is produced in one FSM
                   state and consumed in a *different* state.  These nodes
                   must be captured into flip-flops at the state boundary.
- `reg_nodes`    : Set of DFGNode IDs with opcode OP_REG (loop-carried phi
                   registers inserted by IRTranslator).
- `state_order`  : Topological order of basic-block IDs, ignoring back-edges,
                   so callers can walk states entry-first.
- `back_edges`   : Set of (from_block_id, to_block_id) tuples for every
                   detected loop back-edge.
"""
struct FSMAnalysis
    live_across::Set{Int}
    reg_nodes::Set{Int}
    state_order::Vector{Int}
    back_edges::Set{Tuple{Int,Int}}
end

"""
    analyse_fsm(graph::HWGraph, fsm::FSMGraph) -> FSMAnalysis
Run the cross-state liveness analysis.
"""
function analyse_fsm(graph::HWGraph, fsm::FSMGraph)::FSMAnalysis
    # Back-edges and OP_REG nodes
    back_edges = Set{Tuple{Int,Int}}()
    reg_nodes = Set{Int}()

    for (bid, state) in fsm.states
        for pred_id in state.back_edge_preds
            push!(back_edges, (pred_id, bid))
        end
    end

    for (nid, node) in graph.nodes
        if node.op == OP_REG
            push!(reg_nodes, nid)
        end
    end

    # Consumer map
    # consumers[n] = [ids of nodes that list n as an input]
    consumers = Dict{Int,Vector{Int}}(id => Int[] for id in keys(graph.nodes))
    for (id, node) in graph.nodes
        for inp in node.inputs
            if haskey(consumers, inp)
                push!(consumers[inp], id)
            end
        end
    end

    # Cross-state liveness
    live_across = Set{Int}()

    for (nid, node) in graph.nodes
        # ARG / CONST are available in all states combinationally
        node.op in (OP_ARG, OP_CONST) && continue

        # If this node has no state assignment (shouldn't happen, but be safe)
        !haskey(fsm.node_state, nid) && continue
        producer_state = fsm.node_state[nid]

        for cid in consumers[nid]
            !haskey(fsm.node_state, cid) && continue
            consumer_state = fsm.node_state[cid]
            if consumer_state != producer_state
                push!(live_across, nid)
                break   # one cross-state consumer is enough
            end
        end
    end

    # Back-edge-free topological order of states
    # Build an adjacency list ignoring back-edges
    fwd_children = Dict{Int,Vector{Int}}(bid => Int[] for bid in keys(fsm.states))
    in_deg = Dict{Int,Int}(bid => 0 for bid in keys(fsm.states))

    for (bid, state) in fsm.states
        for succ_id in filter(!isnothing, [state.true_successor, state.false_successor])
            succ_id === nothing && continue
            # Skip if this is a back-edge
            (bid, succ_id) in back_edges && continue
            push!(fwd_children[bid], succ_id)
            in_deg[succ_id] = get(in_deg, succ_id, 0) + 1
        end
    end

    # Kahn's algorithm on the forward-only DAG
    queue = sort([bid for (bid, deg) in in_deg if deg == 0])
    state_order = Int[]

    while !isempty(queue)
        bid = popfirst!(queue)
        push!(state_order, bid)
        for child in sort(fwd_children[bid])
            in_deg[child] -= 1
            if in_deg[child] == 0
                push!(queue, child)
            end
        end
    end

    # If some states were unreachable from entry (shouldn't happen in
    # well-formed IR) append them at the end.
    visited = Set(state_order)
    for bid in sort(collect(keys(fsm.states)))
        bid ∉ visited && push!(state_order, bid)
    end

    return FSMAnalysis(live_across, reg_nodes, state_order, back_edges)
end
