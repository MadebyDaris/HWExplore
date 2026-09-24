# ResourceSharing.jl
#
# Phase 0 resource sharing: turn a *time-multiplexed schedule* into *shared
# hardware*. schedule_asap!(graph; resources=budget) already serializes
# operations so that no more than `budget[op]` of them are in flight in any
# cycle; this file does the other half, binding those operations and emitting the operand muxes.
#
#   graph = ...                                   # any HWGraph
#   emit_verilog(graph, "out.sv"; share=Dict(OP_MUL => 1))
#
# What the emitted module looks like, per shared unit
#
#   assign mul0_a = sel_9 ? <node 9 lhs> : sel_10 ? <node 10 lhs> : ... : '0;
#   assign mul0_b = sel_9 ? <node 9 rhs> : ...;
#   assign mul0_y = mul0_a * mul0_b;                 // ONE multiplier
#   always_ff ... if (sel_9) n9_hold <= mul0_y; ...  // each node keeps its result
#
# `sel_<id>` is high in exactly the cycle node <id> is scheduled to start:
# `start_i` for the first compute cycle, `done_shift[c-3]` for cycle c >= 3.
# Because the mux selects are one-hot in time, the shared unit is never asked
# to do two things at once, the scheduler guarantees it.
#
# Consequences worth knowing:
#   * A shared design has initiation interval == graph.latency: a new start_i
#     must not arrive until done_o. (The CV-X-IF shell already behaves this
#     way.)
#   * EVERY compute node (shared or not) keeps its result in an `n<id>_hold`
#     register loaded only in its own start cycle, instead of the plain
#     emitter's free-running shift chain. A shared unit's output is garbage in
#     every cycle but its owner's, so results must be captured and held; doing
#     it uniformly also means the module no longer needs rs*_i held stable
#     (the plain emitter's chains only stay correct while the inputs do).
#   * Operands read from an input port after the first compute cycle are read
#     from `rs<k>_q` latches captured on start_i, so the design no longer
#     depends on the caller holding rs*_i stable.

export SHAREABLE_OPS, UnitBinding, bind_units, emit_verilog_shared, sharing_report

const SHAREABLE_OPS = (OP_ADD, OP_SUB, OP_MUL, OP_MOD, OP_SHL, OP_SHR, OP_AND, OP_OR, OP_XOR)

"""
    UnitBinding(op, index, nodes)
One physical functional unit: `nodes` (DFG node ids, in start-cycle order) all
execute on unit `index` of class `op`, never overlapping in time.
"""
struct UnitBinding
    op::Opcode
    index::Int
    nodes::Vector{Int}
end

unit_name(u::UnitBinding) = lowercase(replace(string(u.op), "OP_" => "")) * string(u.index - 1)

# Validate a budget BEFORE scheduling: a budget of 0 would make the list
# scheduler wait forever for a unit that never exists.
function check_budget(budget)::Dict{Opcode,Int}
    b = Dict{Opcode,Int}(budget)
    for (op, n) in b
        op in SHAREABLE_OPS || error("[HWExplore] sharing $op is not supported; shareable: $(SHAREABLE_OPS)")
        n >= 1 || error("[HWExplore] unit budget for $op must be >= 1, got $n")
    end
    return b
end

"""
    bind_units(graph, budget) -> Vector{UnitBinding}

Assign every node of each budgeted opcode class to a unit by greedy interval
coloring over each node's `(scheduled_cycle, finish_cycle)` span. This is
optimal for interval graphs, so it needs exactly max-overlap units, which a
schedule produced with the same budget keeps at or under that budget. Errors
if the current schedule needs more units than the budget allows; call
`schedule_asap!(graph; resources=budget)` first.
"""
function bind_units(graph::HWGraph, budget)::Vector{UnitBinding}
    bindings = UnitBinding[]
    for (op, limit) in sort!(collect(budget); by = kv -> Int(kv[1]))
        op in SHAREABLE_OPS || error("[HWExplore] sharing $op is not supported; shareable: $(SHAREABLE_OPS)")
        limit >= 1 || error("[HWExplore] unit budget for $op must be >= 1, got $limit")
        # Think about primitive module sharing

        ids = sort!([id for (id, n) in graph.nodes if n.op == op && n.primitive === nothing];
                    by = id -> (graph.nodes[id].scheduled_cycle, id))
        free_at = Int[]                    # per unit: first cycle it is free again
        members = Vector{Int}[]
        
        for id in ids
            node = graph.nodes[id]
            u = findfirst(t -> t <= node.scheduled_cycle, free_at)
            if u === nothing
                push!(free_at, 0)
                push!(members, Int[])
                u = length(free_at)
            end
            free_at[u] = finish_cycle(node) + 1
            push!(members[u], id)
        end
        length(members) <= limit ||
            error("[HWExplore] schedule needs $(length(members)) $op units but budget is $limit; " *
                  "run schedule_asap!(graph; resources=Dict($op => $limit)) first")
        for (i, m) in enumerate(members)
            push!(bindings, UnitBinding(op, i, m))
        end
    end
    return bindings
end

"""
    sharing_report(graph, budget) -> NamedTuple

Numbers for a design-space sweep, without emitting anything: after scheduling
under `budget`, how many operators the plain emitter would instantiate for the
budgeted classes vs how many shared units, and the resulting latency.
"""
function sharing_report(graph::HWGraph, budget)
    b = check_budget(budget)
    schedule_asap!(graph; resources=b)
    units = bind_units(graph, b)
    nodes = sum(length(u.nodes) for u in units; init=0)
    return (latency = graph.latency, operators_unshared = nodes, units = length(units),
            per_class = Dict(op => count(u -> u.op == op, units) for op in keys(b)))
end

function emit_verilog_shared(graph::HWGraph, filepath::String, budget)
    W = 32
    FIRST = 2                                   # first compute cycle == start_i cycle
    budget = check_budget(budget)
    schedule_asap!(graph; resources=budget)
    units = bind_units(graph, budget)
    shared = [u for u in units if length(u.nodes) >= 2]
    unit_of = Dict{Int,UnitBinding}(id => u for u in shared for id in u.nodes)

    arg_ids = graph.graph_inputs
    length(arg_ids) <= 8 || error("[HWExplore] at most 8 inputs supported, got $(length(arg_ids))")
    out_id = graph.nodes[graph.graph_outputs[1]].inputs[1]
    max_cycle = graph.latency
    port_names = ["rs$(k)_i" for k in 1:8]
    compute = [(id, n) for (id, n) in sort!(collect(graph.nodes); by = first)
               if !(n.op in (OP_ARG, OP_CONST, OP_RET))]

    # Input ports read after the first compute cycle need a latch.
    latched = Set{Int}()
    for (_, n) in compute, dep in n.inputs
        graph.nodes[dep].op == OP_ARG && n.scheduled_cycle > FIRST &&
            push!(latched, findfirst(==(dep), arg_ids))
    end

    hold(id) = "n$(id)_hold"
    sel(id) = "sel_$(id)"
    function resolve(dep_id::Int, cyc::Int)::String
        dep = graph.nodes[dep_id]
        if dep.op == OP_ARG
            k = findfirst(==(dep_id), arg_ids)
            return cyc > FIRST ? "rs$(k)_q" : port_names[k]
        elseif dep.op == OP_CONST
            return "$(W)'d$(dep.const_val)"
        end
        return hold(dep_id)
    end

    L = String[]
    push!(L, "// Auto-generated by HWExplore VerilogEmitter (resource-shared)")
    push!(L, "// Graph: $(graph.name)  |  Latency: $(graph.latency) cycle(s)  |  Initiation interval: $(graph.latency)")
    push!(L, "// Budget: " * join(sort!(["$(replace(string(op), "OP_" => ""))=$n" for (op, n) in budget]), ", ") *
             "  |  Shared units: " * (isempty(shared) ? "none" :
             join(["$(unit_name(u)) (x$(length(u.nodes)) nodes)" for u in shared], ", ")))
    push!(L, "")
    push!(L, "module $(graph.name) (")
    push!(L, "    input  logic        clk_i,")
    push!(L, "    input  logic        rst_ni,")
    push!(L, "    input  logic        start_i,")
    push!(L, "    input  logic        stall_i,")
    push!(L, "    input  logic [$(W-1):0] rs1_i,")
    push!(L, "    input  logic [$(W-1):0] rs2_i,")
    for k in 3:length(arg_ids)
        push!(L, "    input  logic [$(W-1):0] $(port_names[k]),")
    end
    push!(L, "    output logic [$(W-1):0] rd_o,")
    push!(L, "    output logic        done_o")
    push!(L, ");")
    push!(L, "")

    push!(L, "    // done_shift[k] is high k+1 cycles after start_i; it doubles as the cycle counter")
    push!(L, "    logic [$(max(max_cycle, 1)-1):0] done_shift;")
    for k in sort!(collect(latched))
        push!(L, "    logic [$(W-1):0] rs$(k)_q;   // rs$(k)_i captured on start_i")
    end
    push!(L, "")

    push!(L, "    // Combinational result wires")
    for (id, _) in compute
        push!(L, "    logic [$(W-1):0] $(comb_wire(id));")
    end
    push!(L, "")

    if !isempty(shared)
        push!(L, "    // One-hot-in-time start selects for nodes on shared units")
        for u in shared, id in u.nodes
            c = graph.nodes[id].scheduled_cycle
            push!(L, "    logic $(sel(id));")
            push!(L, "    assign $(sel(id)) = $(c == FIRST ? "start_i" : "done_shift[$(c-3)]");   // node $id starts in cycle $c")
        end
        push!(L, "")
        push!(L, "    // Shared functional units")
        for u in shared
            n = unit_name(u)
            sv = op_to_sv(u.op)
            push!(L, "    // $(n): $(join(u.nodes, ", ")) share one $(replace(string(u.op), "OP_" => "")) operator")
            push!(L, "    logic [$(W-1):0] $(n)_a, $(n)_b, $(n)_y;")
            for (side, slot) in (("a", 1), ("b", 2))
                terms = ["$(sel(id)) ? $(resolve(graph.nodes[id].inputs[slot], graph.nodes[id].scheduled_cycle)) : "
                         for id in u.nodes]
                push!(L, "    assign $(n)_$(side) = " * join(terms) * "'0;")
            end
            push!(L, "    assign $(n)_y = $(n)_a $sv $(n)_b;")
            for id in u.nodes
                push!(L, "    assign $(comb_wire(id)) = $(n)_y;")
            end
            push!(L, "")
        end
    end

    dedicated = [(id, n) for (id, n) in compute if !haskey(unit_of, id)]
    push!(L, "    // Start selects for dedicated (unshared) nodes")
    for (id, n) in dedicated
        c = n.scheduled_cycle
        push!(L, "    logic $(sel(id));")
        push!(L, "    assign $(sel(id)) = $(c == FIRST ? "start_i" : "done_shift[$(c-3)]");   // node $id starts in cycle $c")
    end
    push!(L, "")
    push!(L, "    // Result holds: each node's value is captured in its own start cycle")
    for (id, _) in compute
        push!(L, "    logic [$(W-1):0] $(hold(id));")
    end
    push!(L, "")
    if !isempty(dedicated)
        push!(L, "    // Dedicated operators")
        for (id, n) in sort!(dedicated; by = t -> (t[2].scheduled_cycle, t[1]))
            push!(L, "    assign $(comb_wire(id)) = $(node_rhs(n, resolve, n.scheduled_cycle, W));")
        end
        push!(L, "")
    end

    push!(L, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
    push!(L, "        if (!rst_ni) begin")
    push!(L, "            done_shift <= '0;")
    for k in sort!(collect(latched))
        push!(L, "            rs$(k)_q <= '0;")
    end
    for (id, _) in compute
        push!(L, "            $(hold(id)) <= '0;")
    end
    push!(L, "        end else if (!stall_i) begin")
    push!(L, max_cycle == 1 ? "            done_shift <= start_i;" :
             "            done_shift <= {done_shift[$(max_cycle-2):0], start_i};")
    for k in sort!(collect(latched))
        push!(L, "            if (start_i) rs$(k)_q <= rs$(k)_i;")
    end
    for (id, _) in compute
        push!(L, "            if ($(sel(id))) $(hold(id)) <= $(comb_wire(id));")
    end
    push!(L, "        end")
    push!(L, "    end")
    push!(L, "")

    fin = graph.nodes[out_id]
    final_wire = fin.op == OP_ARG   ? port_names[findfirst(==(out_id), arg_ids)] :
                 fin.op == OP_CONST ? "$(W)'d$(fin.const_val)" :
                 hold(out_id)
    push!(L, "    assign rd_o = $final_wire;")
    push!(L, "    assign done_o = done_shift[$(max_cycle-1)];")
    push!(L, "")
    push!(L, "endmodule")

    write(filepath, join(L, "\n") * "\n")
    println("Emitted: $filepath  (latency = $(graph.latency) cycle(s), " *
            "$(length(shared)) shared unit(s) covering $(sum(length(u.nodes) for u in shared; init=0)) nodes)")
end
