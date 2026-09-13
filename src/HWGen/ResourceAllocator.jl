# ResourceAllocator.jl
#
# Resource-constrained list scheduling for HWExplore dataflow graphs.
# Given a resource budget (e.g. "1 multiplier, 2 ALUs"), this module
# serializes operations that would otherwise oversubscribe shared hardware.
# Depends on DFG_Builder types and Scheduler (finish_cycle, topological_sort).

export ResourceBudget, schedule_list!

# Map each opcode to a resource class.
# Operations in the same class share a finite pool of functional units.
const OP_RESOURCE_CLASS = Dict{Opcode,Symbol}(
    OP_ADD => :ALU,
    OP_SUB => :ALU,
    OP_MUL => :MUL,
    OP_SHR => :SHIFT,
    OP_SHL => :SHIFT,
    OP_AND => :ALU,
    OP_OR  => :ALU,
    OP_XOR => :ALU,
    OP_MOD => :DIV,
)

# Resource budget: how many units of each resource class are available.
# ResourceBudget(:ALU => 2, :MUL => 1, :SHIFT => 1, :DIV => 1)
const ResourceBudget = Dict{Symbol,Int}

# Track which cycles each resource is occupied.
# Resource usage is recorded from scheduled_cycle to finish_cycle (inclusive).
mutable struct ResourceTracker
    budget::ResourceBudget
    # usage[resource_class][cycle] = count of units in use
    usage::Dict{Symbol,Vector{Int}}

    function ResourceTracker(budget::ResourceBudget)
        usage = Dict{Symbol,Vector{Int}}()
        for cls in keys(budget)
            usage[cls] = Int[]
        end
        new(budget, usage)
    end
end

# Ensure usage vector extends to at least `cycle`.
function _ensure_cycle!(rt::ResourceTracker, cls::Symbol, cycle::Int)
    vec = rt.usage[cls]
    while length(vec) < cycle
        push!(vec, 0)
    end
end

# Return true if `units` of `cls` are free from `start_cycle` to `end_cycle` inclusive.
function _resource_available(rt::ResourceTracker, cls::Symbol, start_cycle::Int, end_cycle::Int, units::Int)
    limit = get(rt.budget, cls, 0)
    limit == 0 && return false
    for cyc in start_cycle:end_cycle
        _ensure_cycle!(rt, cls, cyc)
        if rt.usage[cls][cyc] + units > limit
            return false
        end
    end
    return true
end

# Reserve `units` of `cls` from `start_cycle` to `end_cycle` inclusive.
function _reserve!(rt::ResourceTracker, cls::Symbol, start_cycle::Int, end_cycle::Int, units::Int)
    for cyc in start_cycle:end_cycle
        _ensure_cycle!(rt, cls, cyc)
        rt.usage[cls][cyc] += units
    end
end

# Find the earliest start cycle for `node` given data dependencies and resource constraints.
function _find_slot(rt::ResourceTracker, graph::HWGraph, node::DFGNode)
    cls = get(OP_RESOURCE_CLASS, node.op, nothing)
    latency = node.latency

    # Earliest cycle based on data dependencies
    earliest = 1
    if !isempty(node.inputs)
        earliest = maximum(finish_cycle(graph.nodes[dep]) for dep in node.inputs) + 1
    end

    # If no resource class (shouldn't happen for compute nodes), just use ASAP
    if cls === nothing
        return earliest
    end

    # Scan forward from `earliest` until we find a slot where the resource is free
    cyc = earliest
    while true
        end_cycle = cyc + latency - 1
        if _resource_available(rt, cls, cyc, end_cycle, 1)
            _reserve!(rt, cls, cyc, end_cycle, 1)
            return cyc
        end
        cyc += 1
    end
end

# Resource-constrained list scheduling.
#
# Like schedule_asap!, but respects a resource budget. Operations that share
# the same functional unit are serialized so that no unit is oversubscribed.
#
# Arguments:
#   - graph:  a scheduled HWGraph (call schedule_asap! first to set latencies)
#   - budget: ResourceBudget, e.g. Dict(:ALU => 2, :MUL => 1)
#
# Returns the graph with updated scheduled_cycle and latency fields.
#
# Example:
#   schedule_asap!(graph)          # sets latencies from OP_LATENCY
#   budget = ResourceBudget(:ALU => 1, :MUL => 1)
#   schedule_list!(graph, budget)  # re-schedules with resource constraints
function schedule_list!(graph::HWGraph, budget::ResourceBudget)
    rt = ResourceTracker(budget)

    for id in topological_sort(graph)
        node = graph.nodes[id]

        # OP_ARG / OP_CONST / OP_RET are not resource-bound
        if node.op in (OP_ARG, OP_CONST, OP_RET)
            if isempty(node.inputs) || node.op in (OP_ARG, OP_CONST)
                node.scheduled_cycle = 1
            elseif node.op == OP_RET
                dep = graph.nodes[node.inputs[1]]
                node.scheduled_cycle = finish_cycle(dep)
            end
            continue
        end

        node.scheduled_cycle = _find_slot(rt, graph, node)
    end

    # Recompute graph latency
    compute_nodes = [n for n in values(graph.nodes)
                     if n.op ∉ (OP_ARG, OP_CONST, OP_RET)]
    graph.latency = isempty(compute_nodes) ? 1 : maximum(finish_cycle(n) for n in compute_nodes)

    return graph
end