# Scheduler.jl
# Depends on DFG_Builder types being available in the caller's scope.
# Includes single-producer ALU muxing and list scheduling with resource constraints.

using DataStructures: PriorityQueue

export schedule_asap!, topological_sort, finish_cycle, schedule_alap!, resource_requirements, resource_usage_timeline, schedule_list!, mux_alu_pathways!

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

# Returns node IDs in topological order (sources first) via Kahn's algorithm.
# OP_REG nodes have a structural back-edge in inputs[2] (the loop-body update
# value). That edge is loop-carried and must NOT be counted as a forward
# dependency — only inputs[1] (the init value) is a true forward edge.
#
# NOTE: A node may list the same input id more than once (e.g. ADD(x, x)).
# We treat the graph as a multi-graph for edge counting so that Kahn's
# in-degree arithmetic stays consistent: each slot in forward_inputs contributes
# one unit of in-degree, and each processing step decrements exactly the count
# of times the processed id appears in the consumer's forward_inputs.
function topological_sort(graph::HWGraph)::Vector{Int}
    # Helper: return the forward-edge inputs for a node.
    # For OP_REG, only inputs[1] is a forward dependency (inputs[2] is back-edge).
    function forward_inputs(node)
        node.op == OP_REG && length(node.inputs) >= 2 ? node.inputs[1:1] : node.inputs
    end

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
    # First: assign latencies where unspecified
    for node in values(graph.nodes)
        if is_primitive_node(node)
            node.latency = primitive_latency(node)
        elseif node.latency == 0 && !(node.op == OP_ARG || node.op == OP_CONST || node.op == OP_RET)
            node.latency = opcode_latency(node.op)
        end
    end

    # Quick unconstrained ASAP to get a baseline latency and earliest starts
    for id in topological_sort(graph)
        node = graph.nodes[id]
        if isempty(node.inputs) || node.op == OP_ARG || node.op == OP_CONST
            node.scheduled_cycle = 1
        elseif node.op == OP_RET
            dep = graph.nodes[node.inputs[1]]
            node.scheduled_cycle = finish_cycle(dep)
        elseif node.op == OP_REG
            # OP_REG: only inputs[1] (init value) is a forward dependency.
            # inputs[2] is the loop-body update — a back-edge, not a data
            # dependency in the combinational scheduling sense.
            dep = graph.nodes[node.inputs[1]]
            node.scheduled_cycle = finish_cycle(dep) + 1
        else
            max_dep_finish = maximum(finish_cycle(graph.nodes[dep]) for dep in node.inputs)
            node.scheduled_cycle = max_dep_finish + 1
        end
    end

    # Baseline graph latency (may increase under resource constraints)
    compute_nodes = [n for n in values(graph.nodes) if n.latency > 0]
    graph.latency = isempty(compute_nodes) ? 1 : maximum(finish_cycle(n) for n in compute_nodes)

    # Compute ALAP and slack based on baseline schedule
    latest_start, slack = schedule_alap!(graph)

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

        # Group ready nodes by opcode and sort by least slack first
        scheduled_this_cycle = false
        by_op = Dict{Any,Vector{Int}}()
        for id in ready
            key = resource_key(graph.nodes[id])
            push!(get!(by_op, key, Int[]), id)
        end

        for (key, ids) in by_op
            # sort by slack (least slack first) then by earlier baseline ASAP then id
            sort!(ids, by=x -> (slack[x], graph.nodes[x].scheduled_cycle == 0 ? typemax(Int) : graph.nodes[x].scheduled_cycle, x))
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

function schedule_alap!(graph::HWGraph)
    # Ensure graph latency and per-node latencies/scheduled_cycle are available
    if graph.latency == 0
        schedule_asap!(graph)
    end

    # Build consumer lists: for each node, which nodes use it as input
    consumers = Dict(id => Int[] for id in keys(graph.nodes))
    for (id, node) in graph.nodes
        for inp in node.inputs
            push!(consumers[inp], id)
        end
    end

    # We'll walk nodes in reverse topological order so consumers are processed
    # before their dependencies.
    rev_order = reverse(topological_sort(graph))

    # latest_start hold the latest cycle a node may start while still
    # meeting the overall graph latency. Initialize conservatively to
    # the graph latency for every node.
    latest_start = Dict{Int,Int}(id => graph.latency for id in keys(graph.nodes))

    for id in rev_order
        node = graph.nodes[id]

        if isempty(consumers[id])
            # No consumers: value must be ready by the graph latency
            latest_start[id] = graph.latency
        else
            # For each consumer c, the dependency must finish by
            # latest_start[c] - 1. Thus the latest start for this node
            # is min_c ( latest_start[c] - node.latency ).
            candidate = typemax(Int)
            for c in consumers[id]
                v = latest_start[c] - node.latency
                if v < candidate
                    candidate = v
                end
            end
            # Ensure at least cycle 1
            latest_start[id] = max(1, candidate)
        end
    end

    # Compute slack = latest_start - earliest_start (earliest stored
    # previously in node.scheduled_cycle by schedule_asap!). Return both
    # mappings so callers can inspect or use them.
    slack = Dict{Int,Int}()
    for (id, node) in graph.nodes
        slack[id] = latest_start[id] - node.scheduled_cycle
    end

    return latest_start, slack
end