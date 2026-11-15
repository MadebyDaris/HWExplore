# VerilogEmitter.jl
# Depends on DFG_Builder types and Scheduler (finish_cycle) being available.

export emit_verilog, emit_fsm_verilog

# Map a DFG opcode to its SystemVerilog operator.
function op_to_sv(op::Opcode)::String
    op == OP_ADD && return "+"
    op == OP_SUB && return "-"
    op == OP_MUL && return "*"
    op == OP_SHR && return ">>"
    op == OP_SHL && return "<<"
    op == OP_AND && return "&"
    op == OP_OR && return "|"
    op == OP_XOR && return "^"
    op == OP_MOD && return "%"
    op == OP_EQ && return "=="
    op == OP_NEQ && return "!="
    op == OP_LT && return "<"
    op == OP_LE && return "<="
    op == OP_GT && return ">"
    op == OP_GE && return ">="
    error("No SV operator for opcode: $op")
end

# Right-hand-side SystemVerilog expression for a compute node, with operand
# names supplied by `resolve(dep_id, consumer_cycle)`. Shared by the plain
# pipeline emitter and the resource-sharing emitter so both agree on operator
# semantics (signed comparisons, 1-bit results zero-extended to W bits, MUX).
function node_rhs(node::DFGNode, resolve::Function, cyc::Int, W::Int)::String
    if node.op == OP_MUX
        cond = resolve(node.inputs[1], cyc)
        t = resolve(node.inputs[2], cyc)
        f = resolve(node.inputs[3], cyc)
        return "|$cond ? $t : $f"
    end
    a = resolve(node.inputs[1], cyc)
    b = resolve(node.inputs[2], cyc)
    if node.op in (OP_LT, OP_LE, OP_GT, OP_GE)
        return "{$(W-1)'b0, \$signed($a) $(op_to_sv(node.op)) \$signed($b)}"
    elseif node.op in (OP_EQ, OP_NEQ, OP_LTU, OP_LEU, OP_GTU, OP_GEU)
        return "{$(W-1)'b0, $a $(op_to_sv(node.op)) $b}"
    end
    return "$a $(op_to_sv(node.op)) $b"
end

comb_wire(id::Int) = "n$(id)_comb"
reg_wire(id::Int, c::Int) = "n$(id)_r$(c)"
# State FSM-specific wire names
state_ff_wire(id::Int) = "n$(id)_ff"

# --- OP_PRIMITIVE support -------------------------------------------------
#
# An OP_PRIMITIVE node isn't a combinational expression like node_rhs's other
# opcodes -- it's a real, separately-pipelined SystemVerilog module (from
# PrimitiveLibrary.jl) instantiated inline, with its own start_i/done_o
# handshake. Timing derivation (see the pipeline model this emitter already
# uses for ordinary multi-cycle nodes): a node scheduled at `scheduled_cycle`
# has its inputs' registered values valid starting at tick `scheduled_cycle -
# 1` (tick 0 = the cycle the module's own start_i pulses), since
# schedule_asap!/schedule_list! always place a node strictly after every
# dependency finishes. So the primitive's own start_i must pulse at that same
# tick -- `scheduled_cycle - 1` ticks after the module's start_i -- which is
# exactly what the delay shift register below produces (0 ticks = start_i
# directly, matching how a normal cycle-1 node needs no delay either). Its
# rd_o is then valid exactly `node.latency` ticks later, i.e. at tick
# `finish_cycle(node)`, so it's wired directly into reg_wire(id, finish_cycle)
# -- the same wire name any consumer already expects a node's finished value
# to live in.

# Return the PrimitiveSpec for an OP_PRIMITIVE node, or error with a specific,
# actionable reason if it can't actually be instantiated as real RTL.
function primitive_spec_for(node::DFGNode)::PrimitiveSpec
    node.primitive !== nothing || error("primitive_spec_for called on a non-OP_PRIMITIVE node $(node.id)")
    haskey(PRIMITIVES, node.primitive) || error(
        "OP_PRIMITIVE node $(node.id) references unregistered primitive :$(node.primitive) -- " *
        "it has no backing SystemVerilog module in PrimitiveLibrary.jl. This placeholder key is " *
        "inserted by IRTranslator.jl for calls it can't lower yet (e.g. :opaque, :bram_read/:bram_write); " *
        "it can't be synthesized as-is. Register a real PrimitiveSpec for it first."
    )
    spec = PRIMITIVES[node.primitive]
    spec.variable_latency && error(
        "OP_PRIMITIVE node $(node.id) uses :$(node.primitive), a variable-latency primitive " *
        "(PrimitiveSpec.variable_latency = true). This emitter assumes every node's result is ready " *
        "at a statically-known cycle, which a variable-latency module can't guarantee -- instantiate " *
        "it directly (e.g. via the dispatcher/build manifest) instead of embedding it in a DFG."
    )
    length(node.inputs) == 2 || error(
        "OP_PRIMITIVE node $(node.id) (:$(node.primitive)) has $(length(node.inputs)) input(s); " *
        "the emitter only supports the canonical 2-operand (rs1_i/rs2_i) primitive interface."
    )
    return spec
end

sv_literal(v::Integer) = string(v)
sv_literal(v) = string(v)  # best-effort fallback for non-integer param overrides

# Merge a primitive's registered default parameters with the node's own
# overrides (node wins), formatted as SystemVerilog `#( ... )` instance text,
# or "" if there's nothing to override.
function primitive_param_text(spec::PrimitiveSpec, node::DFGNode)::String
    merged = merge(spec.params, node.primitive_params)
    isempty(merged) && return ""
    items = ["." * String(k) * "(" * sv_literal(v) * ")" for (k, v) in sort(collect(merged); by=first)]
    return " #(\n        " * join(items, ",\n        ") * "\n    )"
end

# Declarations + instantiation for one OP_PRIMITIVE node. `resolve` is the
# same operand-resolution closure emit_verilog already builds for ordinary
# nodes, so a primitive's operands are sourced exactly like any other node's.
function primitive_instance_lines(node::DFGNode, resolve::Function)::Vector{String}
    spec = primitive_spec_for(node)
    id = node.id
    delay = node.scheduled_cycle - 1   # ticks after module start_i (see note above)
    start_sig = delay == 0 ? "start_i" : "prim$(id)_start_sr[$(delay-1)]"

    lines = String[]
    delay > 0 && push!(lines, "    logic [$(delay-1):0] prim$(id)_start_sr;")
    push!(lines, "    logic prim$(id)_done;")
    rs1 = resolve(node.inputs[1], node.scheduled_cycle)
    rs2 = resolve(node.inputs[2], node.scheduled_cycle)
    push!(lines, "    $(spec.module_name)$(primitive_param_text(spec, node)) u_prim$(id) (")
    push!(lines, "        .clk_i   (clk_i),")
    push!(lines, "        .rst_ni  (rst_ni),")
    push!(lines, "        .start_i ($(start_sig)),")
    push!(lines, "        .stall_i (stall_i),")
    push!(lines, "        .rs1_i   ($(rs1)),")
    push!(lines, "        .rs2_i   ($(rs2)),")
    push!(lines, "        .rd_o    ($(reg_wire(id, finish_cycle(node)))),")
    push!(lines, "        .done_o  (prim$(id)_done)")
    push!(lines, "    );")
    return lines
end


"""
    emit_verilog(graph::HWGraph, filepath::String; share=nothing)

Emit a pipelined SystemVerilog module for a feedforward (non-looping)
[`HWGraph`](@ref) to `filepath`, and return `nothing`.

Every emitted module shares one port list: `clk_i`, `rst_ni`, `start_i`,
`stall_i`, `rs1_i` through `rs<n>_i` (one per graph input, up to 8), `rd_o`,
`done_o`. `done_o` asserts exactly `graph.latency` cycles after `start_i`,
the same cycle `rd_o` is valid. Multi-cycle operations are pipelined
automatically via register chains spanning `scheduled_cycle` through
`finish_cycle`.

Precondition: `schedule_asap!(graph)` (or `schedule_asap!(graph; resources=...)`)
must be called first — unless `share` is given, in which case the graph is
re-scheduled for you under that budget.

# Keyword arguments
- `share`: a per-opcode functional-unit budget, e.g. `Dict(OP_MUL => 1)`.
  When given, nodes of a budgeted opcode class are bound onto that many
  physical units instead of getting one operator each, with an operand mux
  selecting which node feeds the shared unit each cycle. See
  `src/HWGen/ResourceSharing.jl` and the "Guide to Using HWExplore" in the
  package documentation for what the emitted RTL looks like and its
  trade-offs. `nothing` (the default) emits one operator per node.

See also [`emit_fsm_verilog`](@ref) for graphs with loops.
"""
function emit_verilog(graph::HWGraph, filepath::String; share=nothing)
    # `share` = Dict(OP_MUL => 1, ...): re-schedule under that per-opcode unit
    # budget and emit shared functional units + operand muxes instead of one
    # operator per node. See src/HWGen/ResourceSharing.jl.
    share === nothing || return emit_verilog_shared(graph, filepath, share)
    W = 32
    arg_ids = graph.graph_inputs
    ret_node = graph.nodes[graph.graph_outputs[1]]
    out_id = ret_node.inputs[1]
    max_cycle = graph.latency

    # Group compute nodes by their scheduled (start) cycle. OP_PRIMITIVE nodes
    # are excluded -- they're emitted as module instances (see "Primitive
    # instances" below), not `assign` statements, and validated up front so a
    # bad primitive reference fails before any RTL text is generated.
    by_cycle = [Int[] for _ in 1:max_cycle]
    primitive_ids = Int[]
    for (id, node) in graph.nodes
        node.op == OP_PRIMITIVE && (primitive_spec_for(node); push!(primitive_ids, id); continue)
        node.op in (OP_ARG, OP_CONST, OP_RET) && continue
        push!(by_cycle[node.scheduled_cycle], id)
    end
    sort!(primitive_ids)

    port_names = ["rs1_i", "rs2_i", "rs3_i", "rs4_i", "rs5_i", "rs6_i", "rs7_i", "rs8_i"]

    # Resolve a dependency node to the correct SV signal at a given consumer cycle.
    # If the dependency finishes before the consumer starts, use the final
    # registered value; otherwise use the combinational wire.
    function resolve(dep_id::Int, consumer_cycle::Int)::String
        dep = graph.nodes[dep_id]
        if dep.op == OP_ARG
            return port_names[findfirst(==(dep_id), arg_ids)]
        elseif dep.op == OP_CONST
            return "$(W)'d$(dep.const_val)"
        end
        dep_finish = finish_cycle(dep)
        if dep_finish < consumer_cycle
            return reg_wire(dep_id, dep_finish)
        else
            return comb_wire(dep_id)
        end
    end

    lines = String[]

    push!(lines, "// Auto-generated by HWExplore VerilogEmitter")
    push!(lines, "// Graph: $(graph.name)  |  Latency: $(graph.latency) cycle(s)")
    push!(lines, "")
    push!(lines, "module $(graph.name) (")
    push!(lines, "    input  logic        clk_i,")
    push!(lines, "    input  logic        rst_ni,")
    push!(lines, "    input  logic        start_i,")
    push!(lines, "    input  logic        stall_i,")
    # Canonical 2-input interface — always emit rs1_i and rs2_i
    push!(lines, "    input  logic [$(W-1):0] rs1_i,")
    push!(lines, "    input  logic [$(W-1):0] rs2_i,")
    # Extra inputs beyond 2
    for k in 3:length(arg_ids)
        push!(lines, "    input  logic [$(W-1):0] $(port_names[k]),")
    end
    push!(lines, "    output logic [$(W-1):0] rd_o,")
    push!(lines, "    output logic        done_o")
    push!(lines, ");")
    push!(lines, "")

    # Combinational wires
    push!(lines, "    // Combinational result wires")
    for (id, node) in graph.nodes
        node.op in (OP_ARG, OP_CONST, OP_RET, OP_PRIMITIVE) && continue
        push!(lines, "    logic [$(W-1):0] $(comb_wire(id));")
    end
    push!(lines, "")

    # A primitive instance drives reg_wire(id, finish_cycle) directly from its
    # rd_o (see primitive_instance_lines) rather than through the generic
    # register chain below, but that wire still needs a declaration -- always,
    # not just when max_cycle > 1, since a latency-1 primitive is possible.
    if !isempty(primitive_ids)
        push!(lines, "    // Primitive output registers")
        for id in primitive_ids
            node = graph.nodes[id]
            push!(lines, "    logic [$(W-1):0] $(reg_wire(id, finish_cycle(node)));")
        end
        push!(lines, "")
    end

    # Pipeline register declarations — one register per cycle from
    # scheduled_cycle through finish_cycle for each compute node.
    if max_cycle > 1
        push!(lines, "    // Pipeline stage registers")
        for (id, node) in graph.nodes
            node.op in (OP_ARG, OP_CONST, OP_RET, OP_PRIMITIVE) && continue
            fc = finish_cycle(node)
            for cyc in node.scheduled_cycle:fc
                push!(lines, "    logic [$(W-1):0] $(reg_wire(id, cyc));")
            end
        end
        push!(lines, "")
    end

    # done shift register
    if max_cycle == 1
        push!(lines, "    logic done_r;")
    else
        push!(lines, "    logic [$(max_cycle-1):0] done_shift;")
    end
    push!(lines, "")

    # Combinational assignments
    push!(lines, "    // Combinational logic")
    for cyc in 1:max_cycle
        for id in by_cycle[cyc]
            node = graph.nodes[id]
            push!(lines, "    assign $(comb_wire(id)) = $(node_rhs(node, resolve, cyc, W));")
        end
    end
    push!(lines, "")

    # Primitive instances — real pipelined modules from PrimitiveLibrary.jl,
    # each with its own start-pulse delay (see the design note above
    # primitive_instance_lines) so its result lands in reg_wire(id,
    # finish_cycle) on exactly the cycle any consumer already expects it.
    if !isempty(primitive_ids)
        push!(lines, "    // Primitive instances")
        for id in primitive_ids
            append!(lines, primitive_instance_lines(graph.nodes[id], resolve))
        end
        push!(lines, "")

        delayed_ids = [id for id in primitive_ids if graph.nodes[id].scheduled_cycle > 1]
        if !isempty(delayed_ids)
            push!(lines, "    // Primitive start-pulse delay registers")
            push!(lines, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
            push!(lines, "        if (!rst_ni) begin")
            for id in delayed_ids
                push!(lines, "            prim$(id)_start_sr <= '0;")
            end
            push!(lines, "        end else if (!stall_i) begin")
            for id in delayed_ids
                delay = graph.nodes[id].scheduled_cycle - 1
                shift_in = delay == 1 ? "start_i" : "{prim$(id)_start_sr[$(delay-2):0], start_i}"
                push!(lines, "            prim$(id)_start_sr <= $(shift_in);")
            end
            push!(lines, "        end")
            push!(lines, "    end")
            push!(lines, "")
        end
    end

    # Pipeline flip-flops — chain registers across multi-cycle latency
    if max_cycle > 1
        push!(lines, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
        push!(lines, "        if (!rst_ni) begin")
        for (id, node) in graph.nodes
            node.op in (OP_ARG, OP_CONST, OP_RET, OP_PRIMITIVE) && continue
            for cyc in node.scheduled_cycle:finish_cycle(node)
                push!(lines, "            $(reg_wire(id, cyc)) <= '0;")
            end
        end
        push!(lines, "        end else if (!stall_i) begin")
        for (id, node) in graph.nodes
            node.op in (OP_ARG, OP_CONST, OP_RET, OP_PRIMITIVE) && continue
            fc = finish_cycle(node)
            # First register captures combinational result
            push!(lines, "            $(reg_wire(id, node.scheduled_cycle)) <= $(comb_wire(id));")
            # Subsequent registers shift the value forward
            for cyc in (node.scheduled_cycle+1):fc
                push!(lines, "            $(reg_wire(id, cyc)) <= $(reg_wire(id, cyc - 1));")
            end
        end
        push!(lines, "        end")
        push!(lines, "    end")
        push!(lines, "")
    end

    # Output wire — use the final registered value of the output-producing node
    final_node = graph.nodes[out_id]
    final_wire = if final_node.op == OP_ARG
        port_names[findfirst(==(out_id), arg_ids)]
    elseif final_node.op == OP_CONST
        "$(W)'d$(final_node.const_val)"
    elseif final_node.op == OP_PRIMITIVE || max_cycle > 1
        reg_wire(out_id, finish_cycle(final_node))
    else
        comb_wire(out_id)
    end
    push!(lines, "    assign rd_o = $final_wire;")
    push!(lines, "")

    # done_o — shift register matching total pipeline depth
    push!(lines, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
    push!(lines, "        if (!rst_ni) begin")
    if max_cycle == 1
        push!(lines, "            done_r <= 1'b0;")
    else
        push!(lines, "            done_shift <= '0;")
    end
    push!(lines, "        end else if (!stall_i) begin")
    if max_cycle == 1
        push!(lines, "            done_r <= start_i;")
    else
        push!(lines, "            done_shift <= {done_shift[$(max_cycle-2):0], start_i};")
    end
    push!(lines, "        end")
    push!(lines, "    end")
    push!(lines, "")
    if max_cycle == 1
        push!(lines, "    assign done_o = done_r;")
    else
        push!(lines, "    assign done_o = done_shift[$(max_cycle-1)];")
    end
    push!(lines, "")
    push!(lines, "endmodule")

    write(filepath, join(lines, "\n") * "\n")
    println("Emitted: $filepath  (latency = $(graph.latency) cycle(s))")
end


# Sequential / FSM Verilog emitter
#
# For generating a state-machine wrapper around the per-state DFG datapath.
# Interface is identical to emit_verilog so modules are plug-compatible:
#   clk_i, rst_ni, start_i, stall_i, rs1_i [...], rd_o, done_o
#
# State encoding
#   S_IDLE  waiting for start_i
#   S_INIT  one-cycle initialisation (seed OP_REG registers from args)
#   S_B<n>  one state per basic block (entry block first, then body, exit)
#   S_DONE  asserts done_o for one cycle, then returns to S_IDLE
#
# If any state's DFG nodes have latency > 1 (as computed by schedule_asap),
# a `cycle_ctr` register tracks progress within that state.  The state machine
# stays in S_B<n> until cycle_ctr reaches the body latency.
#
# Precondition: schedule_asap!(graph) must be called before this function.
"""
    emit_fsm_verilog(graph::HWGraph, fsm::FSMGraph, filepath::String;
                     analysis::Union{FSMAnalysis,Nothing}=nothing)
Emit a sequential (FSM-based) SystemVerilog module for the given graph.
If `analysis` is not provided, `analyse_fsm` is called automatically.
"""
function emit_fsm_verilog(graph::HWGraph, fsm::FSMGraph, filepath::String;
    analysis::Union{FSMAnalysis,Nothing}=nothing)

    # Check that the FSM is valid, if not, run analysis
    if analysis === nothing
        analysis = analyse_fsm(graph, fsm)
    end

    W = 32 # default data width (same as combinational emitter)
    arg_ids = graph.graph_inputs
    ret_node = graph.nodes[graph.graph_outputs[1]]
    out_id = ret_node.inputs[1]

    port_names = ["rs1_i", "rs2_i", "rs3_i", "rs4_i",
        "rs5_i", "rs6_i", "rs7_i", "rs8_i"]

    lines = String[]

    # helpers
    # Emit a signal name for a DFGNode in FSM context.
    # OP_ARG  -> port input directly
    # OP_CONST -> literal
    # live-across or OP_REG -> state_ff_wire (the persisting register)
    # everything else -> comb_wire
    function fsm_resolve(dep_id::Int)::String
        dep = graph.nodes[dep_id]
        if dep.op == OP_ARG
            idx = findfirst(==(dep_id), arg_ids)
            return idx !== nothing ? port_names[idx] : "rs1_i"
        elseif dep.op == OP_CONST
            cv = dep.const_val !== nothing ? dep.const_val : 0
            return "$(W)'d$(cv)"
        elseif dep_id in analysis.live_across || dep.op == OP_REG
            return state_ff_wire(dep_id)
        else
            return comb_wire(dep_id)
        end
    end

    # State name for a block id
    state_name(bid::Int) = "S_B$(bid)"

    # Total number of states: IDLE + INIT + one per block + DONE
    n_blocks = length(fsm.states)
    total_states = n_blocks + 3   # IDLE, INIT, blocks..., DONE
    sbits = max(1, ceil(Int, log2(total_states + 1)))

    # Assign numeric encoding
    S_IDLE = 0
    S_INIT = 1
    # Block states start at 2; we sort by state_order for a clean encoding
    block_enc = Dict{Int,Int}()
    for (i, bid) in enumerate(analysis.state_order)
        block_enc[bid] = i + 1   # 2, 3, 4, ...
    end
    S_DONE = n_blocks + 2

    # port list
    push!(lines, "// Auto-generated by HWExplore VerilogEmitter (FSM backend)")
    push!(lines, "// Graph: $(graph.name)  |  States: $(n_blocks) block(s)")
    push!(lines, "")
    push!(lines, "module $(graph.name) (")
    push!(lines, "    input  logic        clk_i,")
    push!(lines, "    input  logic        rst_ni,")
    push!(lines, "    input  logic        start_i,")
    push!(lines, "    input  logic        stall_i,")
    push!(lines, "    input  logic [$(W-1):0] rs1_i,")
    push!(lines, "    input  logic [$(W-1):0] rs2_i,")
    for k in 3:length(arg_ids)
        push!(lines, "    input  logic [$(W-1):0] $(port_names[k]),")
    end
    push!(lines, "    output logic [$(W-1):0] rd_o,")
    push!(lines, "    output logic        done_o")
    push!(lines, ");")
    push!(lines, "")

    # state encoding
    push!(lines, "    // State encoding")
    push!(lines, "    localparam integer S_IDLE = $(S_IDLE);")
    push!(lines, "    localparam integer S_INIT = $(S_INIT);")
    for bid in analysis.state_order
        push!(lines, "    localparam integer $(state_name(bid)) = $(block_enc[bid]);")
    end
    push!(lines, "    localparam integer S_DONE = $(S_DONE);")
    push!(lines, "")
    push!(lines, "    logic [$(sbits-1):0] state, state_next;")
    push!(lines, "")

    # compute per-state max latency for sub-cycle counter
    # Group DFG nodes (excluding ARG/CONST/RET) by their state
    nodes_by_state = Dict{Int,Vector{Int}}(bid => Int[] for bid in keys(fsm.states))
    for (nid, sid) in fsm.node_state
        node = graph.nodes[nid]
        node.op in (OP_ARG, OP_CONST, OP_RET) && continue
        haskey(nodes_by_state, sid) && push!(nodes_by_state[sid], nid)
    end

    # Max latency within each state (after schedule_asap!)
    state_latency = Dict{Int,Int}()
    for (bid, nids) in nodes_by_state
        if isempty(nids)
            state_latency[bid] = 1
        else
            max_lat = maximum(
                finish_cycle(graph.nodes[nid]) - graph.nodes[nid].scheduled_cycle + 1
                for nid in nids
            )
            state_latency[bid] = max(1, max_lat)
        end
    end

    max_body_lat = isempty(state_latency) ? 1 : maximum(values(state_latency))
    need_ctr = max_body_lat > 1
    ctr_bits = need_ctr ? max(1, ceil(Int, log2(max_body_lat + 1))) : 1

    if need_ctr
        push!(lines, "    // Sub-cycle counter for multi-cycle states")
        push!(lines, "    logic [$(ctr_bits-1):0] cycle_ctr;")
        push!(lines, "")
    end

    # combinational wire declarations
    push!(lines, "    // Combinational result wires")
    for (id, node) in graph.nodes
        node.op in (OP_ARG, OP_CONST, OP_RET, OP_REG) && continue
        push!(lines, "    logic [$(W-1):0] $(comb_wire(id));")
    end
    push!(lines, "")

    # state-crossing FF declarations
    cross_ff_ids = sort(collect(
        union(analysis.live_across, analysis.reg_nodes)
    ))
    if !isempty(cross_ff_ids)
        push!(lines, "    // State-crossing flip-flops")
        for id in cross_ff_ids
            push!(lines, "    logic [$(W-1):0] $(state_ff_wire(id));")
        end
        push!(lines, "")
    end

    # output capture register
    push!(lines, "    logic [$(W-1):0] rd_capture;")
    push!(lines, "")

    # state register
    push!(lines, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
    push!(lines, "        if (!rst_ni) state <= $(sbits)'(S_IDLE);")
    push!(lines, "        else if (!stall_i) state <= state_next;")
    push!(lines, "    end")
    push!(lines, "")

    if need_ctr
        push!(lines, "    // Sub-cycle counter register")
        push!(lines, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
        push!(lines, "        if (!rst_ni) begin")
        push!(lines, "            cycle_ctr <= '0;")
        push!(lines, "        end else if (!stall_i) begin")
        push!(lines, "            if (state != state_next)")
        push!(lines, "                cycle_ctr <= '0;")
        push!(lines, "            else")
        push!(lines, "                cycle_ctr <= cycle_ctr + 1'b1;")
        push!(lines, "        end")
        push!(lines, "    end")
        push!(lines, "")
    end

    # next-state combinational logic
    push!(lines, "    // Next-state logic")
    push!(lines, "    always_comb begin")
    push!(lines, "        state_next = state;")
    push!(lines, "        case (state)")
    push!(lines, "            S_IDLE: begin")
    push!(lines, "                if (start_i) state_next = $(sbits)'(S_INIT);")
    push!(lines, "            end")
    push!(lines, "            S_INIT: state_next = $(sbits)'($(state_name(analysis.state_order[1])));")

    for bid in analysis.state_order
        state = fsm.states[bid]
        lat = get(state_latency, bid, 1)
        enc = block_enc[bid]

        push!(lines, "            $(state_name(bid)): begin")

        if lat > 1 && need_ctr
            push!(lines, "                if (cycle_ctr < $(ctr_bits)'d$(lat - 1)) begin")
            push!(lines, "                    state_next = $(sbits)'d$(enc); // stay")
            push!(lines, "                end else begin")
            indent = "                    "
        else
            indent = "                "
        end

        true_succ = state.true_successor
        false_succ = state.false_successor

        if true_succ !== nothing && false_succ !== nothing
            # Conditional branch
            cond_id = state.entry_cond
            cond_sig = cond_id !== nothing ? fsm_resolve(cond_id) : "1'b1"
            t_name = haskey(block_enc, true_succ) ? state_name(true_succ) : "S_DONE"
            f_name = haskey(block_enc, false_succ) ? state_name(false_succ) : "S_DONE"
            push!(lines, "$(indent)if (|$(cond_sig))")
            push!(lines, "$(indent)    state_next = $(sbits)'($(t_name));")
            push!(lines, "$(indent)else")
            push!(lines, "$(indent)    state_next = $(sbits)'($(f_name));")
        elseif true_succ !== nothing
            # Unconditional branch
            # Detect if this is a loop back-edge
            if (bid, true_succ) in analysis.back_edges
                # Back to loop header
                t_name = haskey(block_enc, true_succ) ? state_name(true_succ) : "S_DONE"
                push!(lines, "$(indent)state_next = $(sbits)'($(t_name));")
            else
                t_name = haskey(block_enc, true_succ) ? state_name(true_succ) : "S_DONE"
                push!(lines, "$(indent)state_next = $(sbits)'($(t_name));")
            end
        else
            # No successor → done
            push!(lines, "$(indent)state_next = $(sbits)'(S_DONE);")
        end

        if lat > 1 && need_ctr
            push!(lines, "                end")
        end
        push!(lines, "            end")
    end

    push!(lines, "            S_DONE: state_next = $(sbits)'(S_IDLE);")
    push!(lines, "            default: state_next = $(sbits)'(S_IDLE);")
    push!(lines, "        endcase")
    push!(lines, "    end")
    push!(lines, "")

    # per-state combinational datapath
    push!(lines, "    // Per-state combinational datapath")
    push!(lines, "    always_comb begin")
    # Default all comb wires to 0 to avoid latches
    for (id, node) in graph.nodes
        node.op in (OP_ARG, OP_CONST, OP_RET, OP_REG) && continue
        push!(lines, "        $(comb_wire(id)) = '0;")
    end
    push!(lines, "")

    for bid in analysis.state_order
        state = fsm.states[bid]
        nids = sort(get(nodes_by_state, bid, Int[]))
        isempty(nids) && continue

        push!(lines, "        if (state == $(sbits)'($(state_name(bid)))) begin")
        for nid in nids
            node = graph.nodes[nid]
            node.op in (OP_ARG, OP_CONST, OP_RET, OP_REG) && continue
            lhs = comb_wire(nid)

            if node.op == OP_MUX
                length(node.inputs) >= 3 || continue
                rhs_cond = fsm_resolve(node.inputs[1])
                rhs_true = fsm_resolve(node.inputs[2])
                rhs_false = fsm_resolve(node.inputs[3])
                push!(lines, "            assign $(lhs) = |$(rhs_cond) ? $(rhs_true) : $(rhs_false);")
            elseif length(node.inputs) >= 2
                rhs_a = fsm_resolve(node.inputs[1])
                rhs_b = fsm_resolve(node.inputs[2])
                if node.op == OP_LT
                    push!(lines, "            assign $(lhs) = {$(W-1)'b0, \$signed($(rhs_a)) < \$signed($(rhs_b))};")
                elseif node.op == OP_LE
                    push!(lines, "            assign $(lhs) = {$(W-1)'b0, \$signed($(rhs_a)) <= \$signed($(rhs_b))};")
                elseif node.op == OP_GT
                    push!(lines, "            assign $(lhs) = {$(W-1)'b0, \$signed($(rhs_a)) > \$signed($(rhs_b))};")
                elseif node.op == OP_GE
                    push!(lines, "            assign $(lhs) = {$(W-1)'b0, \$signed($(rhs_a)) >= \$signed($(rhs_b))};")
                elseif node.op in (OP_EQ, OP_NEQ, OP_LTU, OP_LEU, OP_GTU, OP_GEU)
                    sv_op = op_to_sv(node.op)
                    push!(lines, "            assign $(lhs) = {$(W-1)'b0, $(rhs_a) $(sv_op) $(rhs_b)};")
                else
                    sv_op = op_to_sv(node.op)
                    push!(lines, "            assign $(lhs) = $(rhs_a) $(sv_op) $(rhs_b);")
                end
            elseif length(node.inputs) == 1
                rhs_a = fsm_resolve(node.inputs[1])
                push!(lines, "            assign $(lhs) = $(rhs_a);")
            end
        end
        push!(lines, "        end")
    end

    push!(lines, "    end")
    push!(lines, "")

    # state-crossing flip-flops
    # Two kinds of registers:
    #   OP_REG (loop-carried phi)  :  mux between init-value and update-value
    #   live_across (wire capture) :  capture comb_wire at end of producing state
    if !isempty(cross_ff_ids)
        push!(lines, "    // State-crossing and loop-carried registers")
        push!(lines, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
        push!(lines, "        if (!rst_ni) begin")
        for id in cross_ff_ids
            push!(lines, "            $(state_ff_wire(id)) <= '0;")
        end
        push!(lines, "        end else if (!stall_i) begin")

        for id in cross_ff_ids
            node = graph.nodes[id]
            ff = state_ff_wire(id)

            if node.op == OP_REG
                # OP_REG: inputs = [init_val, update_val]
                # init_val  comes from the non-back-edge predecessor (pre-loop forward edge)
                # update_val comes from the loop body (back-edge predecessor)
                # We use the producing state of init_val to decide when to load init vs update.
                if length(node.inputs) >= 2
                    init_id = node.inputs[1]
                    update_id = node.inputs[2]
                    init_sig = fsm_resolve(init_id)
                    update_sig = fsm_resolve(update_id)
                    # Find the state that holds the OP_REG itself (the loop header)
                    header_bid = get(fsm.node_state, id, -1)
                    # Pre-loop state: any predecessor of the header that is NOT a back-edge
                    pre_loop_bids = filter(
                        p -> (p, header_bid) ∉ analysis.back_edges,
                        get(fsm.states[header_bid].predecessors, header_bid, fsm.states[header_bid].predecessors)
                    )
                    # Fallback: use S_INIT as the pre-loop state
                    if isempty(pre_loop_bids)
                        pre_cond = "state == $(sbits)'(S_INIT)"
                    else
                        pre_cond = join(
                            ["state == $(sbits)'($(state_name(p)))" for p in pre_loop_bids],
                            " || "
                        )
                    end
                    push!(lines, "            if ($(pre_cond))")
                    push!(lines, "                $(ff) <= $(init_sig);")
                    push!(lines, "            else")
                    push!(lines, "                $(ff) <= $(update_sig);")
                end
            else
                # live_across: capture the combinational result in the producing state
                producer_state_bid = get(fsm.node_state, id, -1)
                if producer_state_bid != -1 && haskey(block_enc, producer_state_bid)
                    push!(lines, "            if (state == $(sbits)'($(state_name(producer_state_bid))))")
                    push!(lines, "                $(ff) <= $(comb_wire(id));")
                else
                    push!(lines, "            $(ff) <= $(comb_wire(id));")
                end
            end
        end

        push!(lines, "        end")
        push!(lines, "    end")
        push!(lines, "")
    end

    # output capture and rd_o
    push!(lines, "    // Output capture")
    out_node = graph.nodes[out_id]
    out_sig = if out_node.op == OP_ARG
        port_names[findfirst(==(out_id), arg_ids)]
    elseif out_node.op == OP_CONST
        "$(W)'d$(out_node.const_val !== nothing ? out_node.const_val : 0)"
    elseif out_id in analysis.live_across || out_node.op == OP_REG
        state_ff_wire(out_id)
    else
        comb_wire(out_id)
    end

    push!(lines, "    always_ff @(posedge clk_i or negedge rst_ni) begin")
    push!(lines, "        if (!rst_ni) rd_capture <= '0;")
    push!(lines, "        else if (state == $(sbits)'(S_DONE)) rd_capture <= $(out_sig);")
    push!(lines, "    end")
    push!(lines, "")
    push!(lines, "    assign rd_o   = rd_capture;")
    push!(lines, "    assign done_o = (state == $(sbits)'(S_DONE));")
    push!(lines, "")
    push!(lines, "endmodule")

    write(filepath, join(lines, "\n") * "\n")
    println("Emitted (FSM): $filepath  ($(n_blocks) state(s))")
end

