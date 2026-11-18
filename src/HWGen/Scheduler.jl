# Scheduler.jl
# Depends on DFG_Builder types being available in the caller's scope.
# Includes single-producer ALU muxing and list scheduling with resource constraints.

using DataStructures: PriorityQueue

export schedule_asap!, topological_sort, finish_cycle, schedule_alap!, resource_requirements, resource_usage_timeline, schedule_list!, mux_alu_pathways!
export asap_starts, alap_starts, mobility, check_schedule, forward_inputs

# Timing rules shared by every scheduler in this file (ASAP, ALAP, list):
#   - OP_ARG / OP_CONST start (and finish) at cycle 1.
#   - A compute node (incl. OP_REG) starts the cycle AFTER its last forward input
#     finishes: start(c) >= finish(dep) + 1, and finishes at start + latency - 1.
#   - OP_RET is a marker, not an operation: it sits ON its input's finish cycle
#     (no +1).
#   - Latency L of a schedule = the latest finish of any compute node (1 if none).
# ALAP is these same rules run backwards from L; keep the two in sync.

is_primitive_node(node) = hasproperty(node, :primitive) && node.primitive !== nothing

resource_key(node) = is_primitive_node(node) ? node.primitive : node.op

function opcode_latency(op)
    return OP_LATENCY[op]
end

function primitive_latency(node)
    if haskey(PRIMITIVES, node.primitive)
        return PRIMITIVES[node.primitive].latency
    else
        # Unknown primitive (e.g. :opaque from IRTranslator) — use node's own latency or default 1
        return node.latency > 0 ? node.latency : 1
    end
end

# The cycle on which a node's result becomes available for consumers.
# OP_ARG / OP_CONST are available immediately at their scheduled cycle (1).
# OP_RET is just a marker — returns its input's finish cycle.
# Compute nodes:  finish_cycle = scheduled_cycle + latency - 1
finish_cycle(node::DFGNode)::Int =
    node.op == OP_ARG ? node.scheduled_cycle :
    node.op == OP_CONST ? node.scheduled_cycle :
    node.op == OP_RET ? node.scheduled_cycle :  # passthrough, see schedule_asap!
    node.scheduled_cycle + node.latency - 1

"""
    forward_inputs(node)

The inputs that must be computed before `node` in the same iteration. For
`OP_REG`, `inputs[2]` is the loop-carried update (a back-edge that feeds the
*next* iteration), so only `inputs[1]` (the init value) counts.
"""
forward_inputs(node) = node.op == OP_REG && length(node.inputs) >= 2 ? node.inputs[1:1] : node.inputs

# Latency a node will be scheduled with, computed without mutating it
# (same rule `assign_latencies!` applies).
function effective_latency(node)
    is_primitive_node(node) && return primitive_latency(node)
    node.latency == 0 && node.op ∉ (OP_ARG, OP_CONST, OP_RET) && return opcode_latency(node.op)
    return node.latency
end

"Fill in each node's `latency` from `OP_LATENCY` / `PRIMITIVES` where it is unspecified."
function assign_latencies!(graph::HWGraph)
    for node in values(graph.nodes)
        node.latency = effective_latency(node)
    end
    return graph
end

# finish cycle of `node` if it started at `start` (see the timing rules above)
finish_at(node, start::Int) =
    node.op in (OP_ARG, OP_CONST, OP_RET) ? start : start + effective_latency(node) - 1

# Latency of a schedule given as `id => start`.
function schedule_latency(graph::HWGraph, starts::Dict{Int,Int})
    fins = [finish_at(n, starts[id]) for (id, n) in graph.nodes if effective_latency(n) > 0]
    return isempty(fins) ? 1 : maximum(fins)
end

# Returns node IDs in topological order (sources first) via Kahn's algorithm.
# OP_REG nodes have a structural back-edge in inputs[2] (the loop-body update
# value). That edge is loop-carried and must NOT be counted as a forward
# dependency — only inputs[1] (the init value) is a true forward edge.
# NOTE: A node may list the same input id more than once (e.g. ADD(x, x)).
# We treat the graph as a multi-graph for edge counting so that Kahn's
# in-degree arithmetic stays consistent: each slot in forward_inputs contributes
# one unit of in-degree, and each processing step decrements exactly the count
# of times the processed id appears in the consumer's forward_inputs.
function topological_sort(graph::HWGraph)::Vector{Int}
    # in_degree[id] = number of forward-edge input slots (counting duplicates)
    in_degree = Dict(id => 0 for id in keys(graph.nodes))
    for node in values(graph.nodes)
        for _ in forward_inputs(node)
            in_degree[node.id] += 1
        end
    end

    queue = [id for (id, deg) in in_degree if deg == 0]
    order = Int[]

    while !isempty(queue)
        id = popfirst!(queue)
        push!(order, id)
        for node in values(graph.nodes)
            fi = forward_inputs(node)
            # Count how many times `id` appears in this node's forward inputs
            cnt = count(==(id), fi)
            if cnt > 0
                in_degree[node.id] -= cnt
                if in_degree[node.id] == 0
                    push!(queue, node.id)
                end
            end
        end
    end

    length(order) == length(graph.nodes) || error("Cycle in DFG -- cannot schedule.")
    return order
end


# Multi-cycle-aware ASAP scheduling.
#
# For each node, the earliest start cycle is:
#   max( finish_cycle(dep) ) + 1   across all input dependencies.
#
# OP_ARG / OP_CONST: no data deps, always start at cycle 1 (latency 0).
# OP_RET: just a marker, inherits its input's finish cycle as its own
#         scheduled_cycle (no extra + latency).
# All others:  scheduled_cycle = max(dep_finish) + 1 ,  latency from OP_LATENCY
#              (or overridden per-node).
#
# Graph total latency = max finish_cycle among compute nodes (excl. OP_RET).
function schedule_asap!(graph::HWGraph; resources=Dict())
    assign_latencies!(graph)

    # Unconstrained ASAP gives the minimum latency; ALAP at that latency gives
    # each node's deadline (latest start), used below as the list-scheduling
    # priority. Both are pure: nothing here calls back into a scheduler.
    asap = asap_starts(graph)
    L_min = schedule_latency(graph, asap)
    ls = alap_starts(graph, L_min)

    # Prepare for list scheduling: reset scheduled cycles for non-trivial nodes
    for node in values(graph.nodes)
        if node.op ∉ (OP_ARG, OP_CONST)
            node.scheduled_cycle = 0
        else
            node.scheduled_cycle = 1
        end
    end

    # Resource timeline per opcode: map cycle -> usage count
    resource_timeline = Dict{Any,Dict{Int,Int}}()
    # Helper to get budget for an opcode (keys are kept as-given)
    function budget_for(op)
        get(resources, op, typemax(Int))
    end

    unscheduled = Set([id for id in keys(graph.nodes) if graph.nodes[id].latency > 0])
    cycle = 1

    # Continue until all compute nodes scheduled
    while !isempty(unscheduled)
        # Build ready list: nodes whose inputs are scheduled and earliest_start <= cycle
        ready = Int[]
        for id in collect(unscheduled)
            node = graph.nodes[id]
            deps_scheduled = all(
                graph.nodes[d].scheduled_cycle != 0
                for d in (node.op == OP_REG && length(node.inputs) >= 2
                      ? node.inputs[1:1]   # only forward dep for OP_REG
                      : node.inputs)
            )
            if deps_scheduled
                # earliest dynamic start based on actual forward deps
                fwd_deps = (node.op == OP_REG && length(node.inputs) >= 2
                            ? node.inputs[1:1] : node.inputs)
                earliest = isempty(fwd_deps) ? 1 : maximum(finish_cycle(graph.nodes[d]) for d in fwd_deps) + 1
                if earliest <= cycle
                    push!(ready, id)
                end
            end
        end

        # Group ready nodes by opcode, most urgent first
        scheduled_this_cycle = false
        by_op = Dict{Any,Vector{Int}}()
        for id in ready
            key = resource_key(graph.nodes[id])
            push!(get!(by_op, key, Int[]), id)
        end

        for (key, ids) in by_op
            # Earliest deadline (ALAP start) first. Every node in `ids` is being
            # placed at the same `cycle`, so ordering by ls[x] is ordering by its
            # real remaining slack, ls[x] - cycle, even after resource conflicts
            # have pushed it past its ASAP start. (A precomputed ALAP - ASAP
            # slack goes stale exactly then.) Node id breaks ties deterministically.
            sort!(ids, by=x -> (ls[x], x))
            b = budget_for(key)
            # ensure timeline map exists
            timeline = get!(resource_timeline, key, Dict{Int,Int}())

            for id in ids
                node = graph.nodes[id]
                lat = max(1, node.latency)
                # check availability across the node's occupied cycles
                can_place = true
                for c in cycle:(cycle+lat-1)
                    used = get(timeline, c, 0)
                    if used >= b
                        can_place = false
                        break
                    end
                end
                if can_place
                    # reserve resources
                    for c in cycle:(cycle+lat-1)
                        timeline[c] = get(timeline, c, 0) + 1
                    end
                    node.scheduled_cycle = cycle
                    delete!(unscheduled, id)
                    scheduled_this_cycle = true
                end
            end
        end

        # If nothing could be scheduled this cycle (resource contention), advance cycle
        if !scheduled_this_cycle
            cycle += 1
        end
    end

    # OP_RET was reset to 0 above and never revisited; put it back on its
    # input's finish cycle so the graph state is a consistent schedule.
    for node in values(graph.nodes)
        node.op == OP_RET && !isempty(node.inputs) &&
            (node.scheduled_cycle = finish_cycle(graph.nodes[node.inputs[1]]))
    end

    # Recompute graph latency after resource-constrained scheduling
    compute_nodes = [n for n in values(graph.nodes) if n.latency > 0]
    graph.latency = isempty(compute_nodes) ? 1 : maximum(finish_cycle(n) for n in compute_nodes)

    return graph
end

"""
    resource_usage_timeline(graph)

Return a per-cycle breakdown of active resource usage after scheduling.

The result is `Dict{Int, Dict{Any,Int}}` mapping each cycle to the number of
active nodes per opcode during that cycle.
"""
function resource_usage_timeline(graph::HWGraph)
    timeline = Dict{Int,Dict{Any,Int}}()

    for node in values(graph.nodes)
        if node.latency <= 0
            continue
        end

        for cycle in node.scheduled_cycle:finish_cycle(node)
            usage = get!(timeline, cycle, Dict{Any,Int}())
            key = resource_key(node)
            usage[key] = get(usage, key, 0) + 1
        end
    end

    return timeline
end

"""
    resource_requirements(graph)

Return the peak concurrent usage required per opcode after scheduling.
This is useful for deriving a resource budget such as
`Dict(OP_MUL => 2, OP_ADD => 1)` before muxing shared units.
"""
function resource_requirements(graph::HWGraph)
    peak = Dict{Any,Int}()
    for usage in values(resource_usage_timeline(graph))
        for (op, count) in usage
            peak[op] = max(get(peak, op, 0), count)
        end
    end
    return peak
end

"""
    asap_starts(graph) -> Dict{Int,Int}

Earliest start cycle of every node with unlimited resources (the timing rules at
the top of this file). Pure: reads the graph, mutates nothing.
"""
function asap_starts(graph::HWGraph)::Dict{Int,Int}
    s = Dict{Int,Int}()
    fin(id) = finish_at(graph.nodes[id], s[id])
    for id in topological_sort(graph)
        node = graph.nodes[id]
        s[id] = if isempty(node.inputs) || node.op in (OP_ARG, OP_CONST)
            1
        elseif node.op == OP_RET
            fin(node.inputs[1])                               # sits on its input's finish
        else
            maximum(fin(d) for d in forward_inputs(node)) + 1 # OP_REG: init value only
        end
    end
    return s
end

"""
    alap_starts(graph, L) -> Dict{Int,Int}

Latest start cycle of every node such that every compute node finishes by cycle
`L`: ASAP's rules run backwards. Pure: reads the graph, mutates nothing.

It works with *deadlines* (the cycle by which a node must have finished):
- consumed by a compute node `c`: finish by `ls[c] - 1` (c starts the cycle after);
- consumed by `OP_RET`: finish by `L` (RET sits *on* its input's finish cycle, no +1);
- no consumers: finish by `L`.
A node's latest start is then `min(deadlines) - latency + 1`. Loop back-edges
(`OP_REG` `inputs[2]`) are not dependencies. Values are not clamped: if `L` is
below the minimum latency some starts come out earlier than possible, which
[`mobility`](@ref) / [`schedule_alap!`](@ref) report as an error.
"""
function alap_starts(graph::HWGraph, L::Int)::Dict{Int,Int}
    consumers = Dict(id => Int[] for id in keys(graph.nodes))
    for (id, node) in graph.nodes, inp in forward_inputs(node)
        push!(consumers[inp], id)
    end
    ls = Dict{Int,Int}()
    for id in reverse(topological_sort(graph))
        node = graph.nodes[id]
        if node.op in (OP_ARG, OP_CONST)
            ls[id] = 1                       # graph inputs are available at cycle 1
        elseif node.op == OP_RET
            ls[id] = L                       # placeholder; set from its input below
        else
            deadline = L
            for c in consumers[id]
                need = graph.nodes[c].op == OP_RET ? L : ls[c] - 1
                deadline = min(deadline, need)
            end
            ls[id] = deadline - effective_latency(node) + 1
        end
    end
    for (id, node) in graph.nodes            # RET marks its input's (ALAP) finish
        node.op == OP_RET && !isempty(node.inputs) &&
            (ls[id] = finish_at(graph.nodes[node.inputs[1]], ls[node.inputs[1]]))
    end
    return ls
end

"""
    mobility(graph; latency=nothing) -> Dict{Int,Tuple{Int,Int}}

`id => (earliest, latest)` start cycle of every compute node for a target
`latency` (default: the minimum latency). `latest - earliest` is the node's
slack: 0 on the critical path. Throws if `latency` is below the minimum.
"""
function mobility(graph::HWGraph; latency::Union{Nothing,Int}=nothing)
    asap = asap_starts(graph)
    L_min = schedule_latency(graph, asap)
    L = latency === nothing ? L_min : latency
    L >= L_min || error("latency $L is infeasible for graph '$(graph.name)': minimum latency is $L_min")
    ls = alap_starts(graph, L)
    win = Dict{Int,Tuple{Int,Int}}()
    for (id, node) in graph.nodes
        node.op in (OP_ARG, OP_CONST, OP_RET) && continue
        ls[id] >= asap[id] || error("internal: node $id ($(node.op)) latest start $(ls[id]) " *
                                    "< earliest $(asap[id]) at latency $L >= minimum $L_min")
        win[id] = (asap[id], ls[id])
    end
    return win
end

"""
    schedule_alap!(graph; latency=nothing) -> graph

Schedule every node as late as possible while finishing by `latency` (default:
the minimum latency). Sets each node's `scheduled_cycle` and `graph.latency`;
throws if `latency` is below the minimum. Unlimited resources, like ASAP.
"""
function schedule_alap!(graph::HWGraph; latency::Union{Nothing,Int}=nothing)
    assign_latencies!(graph)
    win = mobility(graph; latency)                 # validates the target
    L = latency === nothing ? schedule_latency(graph, asap_starts(graph)) : latency
    ls = alap_starts(graph, L)
    for (id, node) in graph.nodes
        node.scheduled_cycle = ls[id]
    end
    graph.latency = L
    return graph
end

"""
    check_schedule(graph) -> true

Throw an `ErrorException` listing every violation of the timing rules (top of
this file) in `graph`'s current schedule: inputs not at cycle 1, a compute node
starting before one of its forward inputs has finished, an `OP_RET` not on its
input's finish cycle, or `graph.latency` not matching the latest finish.
Use it after any scheduler (ASAP, ALAP, list, resource-constrained).
"""
function check_schedule(graph::HWGraph)
    bad = String[]
    for id in sort(collect(keys(graph.nodes)))
        node = graph.nodes[id]
        if node.op in (OP_ARG, OP_CONST)
            node.scheduled_cycle == 1 || push!(bad, "node $id ($(node.op)) at cycle $(node.scheduled_cycle), expected 1")
        elseif node.op == OP_RET
            isempty(node.inputs) && continue
            f = finish_cycle(graph.nodes[node.inputs[1]])
            node.scheduled_cycle == f ||
                push!(bad, "node $id (OP_RET) at cycle $(node.scheduled_cycle), expected its input's finish $f")
        else
            node.scheduled_cycle >= 1 || push!(bad, "node $id ($(node.op)) is unscheduled (cycle $(node.scheduled_cycle))")
            for d in forward_inputs(node)
                f = finish_cycle(graph.nodes[d])
                node.scheduled_cycle >= f + 1 ||
                    push!(bad, "node $id ($(node.op)) starts at $(node.scheduled_cycle) but input $d finishes at $f")
            end
        end
    end
    compute = [n for n in values(graph.nodes) if n.latency > 0]
    L = isempty(compute) ? 1 : maximum(finish_cycle(n) for n in compute)
    graph.latency == L || push!(bad, "graph.latency = $(graph.latency) but the latest finish is $L")
    isempty(bad) || error("invalid schedule for '$(graph.name)':\n  " * join(bad, "\n  "))
    return true
end
