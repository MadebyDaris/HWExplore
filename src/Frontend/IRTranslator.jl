# IRTranslator.jl
#
# Walks IRTools SSA IR and constructs a NexusV Data-Flow Graph.
# Because the IR is in SSA form, every SSA value maps to a physical wire.

export translate_ir_to_dfg, FSMState, FSMGraph, analyse_fsm

using IRTools: IRTools, IR, Block, Variable, Statement,
    blocks, arguments, branches, isreturn, xcall

"""
    FSMState

Represents one basic block as a state in a hardware FSM.
- `block_id`:        IRTools block index
- `entry_cond`:      DFGNode id of the condition that selects this state
                     (nothing for the entry block or unconditional targets)
- `predecessors`:    block ids that can transition into this state
- `true_successor`:  block id for the "then" branch (or unconditional target)
- `false_successor`: block id for the "else" branch (nothing if unconditional)
- `is_loop_header`:  true iff at least one predecessor is a back-edge (pred_id >= self)
- `back_edge_preds`: subset of predecessors that are back-edges
"""
mutable struct FSMState
    block_id::Int
    entry_cond::Union{Nothing,Int}   # DFGNode id of the select condition
    predecessors::Vector{Int}
    true_successor::Union{Nothing,Int}
    false_successor::Union{Nothing,Int}
    is_loop_header::Bool
    back_edge_preds::Vector{Int}
end

# Convenience constructor matching old 5-field call sites
FSMState(bid, ec, preds, ts, fs) = FSMState(bid, ec, preds, ts, fs, false, Int[])

"""
    FSMGraph
Collection of FSM states extracted from the IR's basic blocks.
`node_state` maps every DFGNode id to the block_id of the state it was
computed in.
"""
struct FSMGraph
    states::Dict{Int,FSMState}       # block_id → FSMState
    node_state::Dict{Int,Int}        # DFGNode id → block_id
end

FSMGraph() = FSMGraph(Dict{Int,FSMState}(), Dict{Int,Int}())

# Operation Dispatch Table
# Maps Julia intrinsic / Base function names to DFG opcodes.
# The keys are Symbols matching what IRTools stores as the callee.
const JULIA_OP_MAP = Dict{Symbol,Opcode}(
    # Integer arithmetic intrinsics
    :add_int => OP_ADD,
    :sub_int => OP_SUB,
    :mul_int => OP_MUL,
    :srem_int => OP_MOD,
    :urem_int => OP_MOD,

    # Bitwise intrinsics
    :and_int => OP_AND,
    :or_int => OP_OR,
    :xor_int => OP_XOR,
    :lshr_int => OP_SHR,
    :ashr_int => OP_SHR,
    :shl_int => OP_SHL,

    # Comparison intrinsics
    :eq_int => OP_EQ,
    :ne_int => OP_NEQ,
    :slt_int => OP_LT,
    :sle_int => OP_LE,
    :ult_int => OP_LTU,
    :ule_int => OP_LEU,

    # Floating-point arithmetic intrinsics
    :add_float => OP_ADD,
    :sub_float => OP_SUB,
    :mul_float => OP_MUL,
    :rem_float => OP_MOD,

    # Floating-point comparisons
    :eq_float => OP_EQ,
    :ne_float => OP_NEQ,
    :lt_float => OP_LT,
    :le_float => OP_LE,

    # Negation (sub from zero — handled specially below)
    :neg_int => OP_SUB,
    :neg_float => OP_SUB,
)

# Higher-level Base calls that appear before full intrinsic lowering.
const BASE_OP_MAP = Dict{Any,Opcode}(
    :+ => OP_ADD,
    :- => OP_SUB,
    :* => OP_MUL,
    :% => OP_MOD,
    :& => OP_AND,
    :| => OP_OR,
    :⊻ => OP_XOR,
    :>> => OP_SHR,
    :<< => OP_SHL,
    :(==) => OP_EQ,
    :(!=) => OP_NEQ,
    :(<) => OP_LT,
    :(<=) => OP_LE,
    :(>) => OP_GT,
    :(>=) => OP_GE,
)

# Infer hardware bit-width from a Julia type.
function julia_type_to_bitwidth(::Type{T}) where T
    T === Bool && return 1
    T === Int8 && return 8
    T === UInt8 && return 8
    T === Int16 && return 16
    T === UInt16 && return 16
    T === Int32 && return 32
    T === UInt32 && return 32
    T === Int64 && return 64
    T === UInt64 && return 64
    T === Float32 && return 32
    T === Float64 && return 64
    return 32  # default fallback for unknown types
end

# Core IRTranslator
"""
    translate_ir_to_dfg(ir::IR, name::String; argtypes=nothing) → (HWGraph, FSMGraph)
Walk an IRTools `IR` object and construct a NexusV Data-Flow Graph.
# Arguments
- `ir`:       IRTools IR (from `IRTools.@code_ir` or `IRTools.IR(...)`)
- `name`:     Name for the generated hardware module
- `argtypes`: Optional tuple of Julia types for input arguments (for bit-width
              inference and type preservation)

# Returns
A `(HWGraph, FSMGraph)` tuple.
"""
function translate_ir_to_dfg(ir::IR, name::String; argtypes=nothing)
    next_id = Ref(0)
    new_id() = (next_id[] += 1; next_id[])

    nodes = Dict{Int,DFGNode}()
    ssa_map = Dict{Any,Int}()          # IRTools Variable/value → DFGNode id
    globalref_map = Dict{Any,Any}()    # Variable → GlobalRef (for indirect calls)
    graph_inputs = Int[]
    graph_outputs = Int[]

    fsm = FSMGraph()

    # Helper: resolve an SSA operand to a DFGNode id.
    # If the operand is a constant literal, create an OP_CONST node on the fly.
    function resolve_operand(val)
        if val isa Variable
            key = val
        elseif val isa GlobalRef
            # GlobalRef to a known function
            return nothing
        else
            key = val
        end

        if haskey(ssa_map, key)
            return ssa_map[key]
        end

        # Constant literal: Int, Float, Bool
        if val isa Integer
            id = new_id()
            bw = val isa Int32 ? 32 : val isa Int64 ? 64 : val isa Int16 ? 16 : val isa Int8 ? 8 : 32
            node = DFGNode(id, OP_CONST, bw, Int[], Int(val), 0, 0, nothing, Dict{Symbol,Any}(), typeof(val))
            nodes[id] = node
            ssa_map[key] = id
            return id
        elseif val isa AbstractFloat
            # Encode float bits as integer for hardware
            id = new_id()
            bw = val isa Float32 ? 32 : 64
            int_val = val isa Float32 ? reinterpret(Int32, Float32(val)) : reinterpret(Int64, Float64(val))
            node = DFGNode(id, OP_CONST, bw, Int[], Int(int_val), 0, 0, nothing, Dict{Symbol,Any}(), typeof(val))
            nodes[id] = node
            ssa_map[key] = id
            return id
        elseif val isa Bool
            id = new_id()
            node = DFGNode(id, OP_CONST, 1, Int[], val ? 1 : 0, 0, 0, nothing, Dict{Symbol,Any}(), Bool)
            nodes[id] = node
            ssa_map[key] = id
            return id
        end

        # Unknown
        return nothing
    end

    # Map function arguments to OP_ARG nodes
    blks = blocks(ir)
    entry_block = blks[1]
    entry_args = arguments(entry_block)

    for (i, arg) in enumerate(entry_args)
        if i == 1
            # Skip the function object ("self") argument
            ssa_map[arg] = -1
            continue
        end

        id = new_id()
        arg_idx = i - 1

        # Infer bit-width and capture Julia type
        jtype = nothing
        bw = 32
        if argtypes !== nothing
            type_params = argtypes isa Type ? Base.unwrap_unionall(argtypes).parameters : ()
            if arg_idx <= length(type_params)
                jtype = type_params[arg_idx]
                bw = julia_type_to_bitwidth(jtype)
            end
        end

        node = DFGNode(id, OP_ARG, bw, Int[], nothing, 0, 0, nothing, Dict{Symbol,Any}(), jtype)
        nodes[id] = node
        push!(graph_inputs, id)
        ssa_map[arg] = id
    end

    # Walk basic blocks and translate statements
    for (blk_idx, block) in enumerate(blks)
        # Register FSM state for this block
        fsm.states[blk_idx] = FSMState(blk_idx, nothing, Int[], nothing, nothing)

        # Process statements in this block
        for (var, stmt) in block
            expr = stmt.expr

            if !Meta.isexpr(expr, :call)
                # Non-call expressions: GlobalRef loads, variable aliases, etc.
                if expr isa GlobalRef
                    # IRTools pattern: %4 = Base.add_int  (loading a function ref)
                    globalref_map[var] = expr
                elseif expr isa Variable && haskey(ssa_map, expr)
                    ssa_map[var] = ssa_map[expr]
                elseif expr isa Variable && haskey(globalref_map, expr)
                    globalref_map[var] = globalref_map[expr]
                end
                continue
            end

            # Extract callee and operands
            raw_callee = expr.args[1]
            operands = expr.args[2:end]

            # Resolve indirect calls: if the callee is a Variable that was
            # assigned from a GlobalRef (e.g. %4 = Base.mul_int), use that.
            callee = raw_callee
            if raw_callee isa Variable && haskey(globalref_map, raw_callee)
                callee = globalref_map[raw_callee]
            end

            # Resolve the callee to an opcode
            opcode = _resolve_opcode(callee)

            if opcode !== nothing
                # Arithmetic / Logic / Comparison node
                input_ids = Int[]
                for op_val in operands
                    dep_id = resolve_operand(op_val)
                    if dep_id !== nothing && dep_id != -1
                        push!(input_ids, dep_id)
                    end
                end

                # Handle negation (unary -> binary with zero)
                callee_name = _callee_name(callee)
                if callee_name in (:neg_int, :neg_float) && length(input_ids) == 1
                    zero_id = new_id()
                    bw = length(input_ids) > 0 ? nodes[input_ids[1]].bit_width : 32
                    zero_node = DFGNode(zero_id, OP_CONST, bw, Int[], 0, 0, 0, nothing, Dict{Symbol,Any}())
                    nodes[zero_id] = zero_node
                    pushfirst!(input_ids, zero_id)  # 0 - x
                end

                # Determine bit-width from inputs
                bw = 32
                if !isempty(input_ids) && haskey(nodes, input_ids[1])
                    bw = nodes[input_ids[1]].bit_width
                end

                id = new_id()
                node = DFGNode(id, opcode, bw, input_ids, nothing, 0, 0, nothing, Dict{Symbol,Any}())
                nodes[id] = node
                ssa_map[var] = id
                fsm.node_state[id] = blk_idx

            elseif _is_memory_op(callee)
                # Memory access (getindex / setindex!)
                id = new_id()
                input_ids = Int[]
                for op_val in operands
                    dep_id = resolve_operand(op_val)
                    if dep_id !== nothing && dep_id != -1
                        push!(input_ids, dep_id)
                    end
                end

                prim = _is_setindex(callee) ? :bram_write : :bram_read
                params = Dict{Symbol,Any}()

                # Capture element type from the array argument's julia_type
                if !isempty(input_ids) && haskey(nodes, input_ids[1])
                    arr_type = nodes[input_ids[1]].julia_type
                    if arr_type !== nothing
                        params[:element_type] = eltype(arr_type)
                        if arr_type <: AbstractArray
                            params[:dimensions] = ndims(arr_type)
                        end
                    end
                end

                bw = get(params, :element_type, nothing) !== nothing ?
                     julia_type_to_bitwidth(params[:element_type]) : 32
                node = DFGNode(id, OP_PRIMITIVE, bw, input_ids, nothing, 0, 0, prim, params)
                nodes[id] = node
                ssa_map[var] = id
                fsm.node_state[id] = blk_idx
            else
                # Unknown / unsupported call
                callee_sym = _callee_name(callee)

                # Detect type constructors: Int32(x), Float32(x), etc.
                is_type_ctor = false
                if callee isa GlobalRef
                    # Check if the GlobalRef resolves to a Type
                    try
                        resolved = getfield(callee.mod, callee.name)
                        if resolved isa Type
                            is_type_ctor = true
                        end
                    catch
                        # Could not resolve: treat as unknown
                    end
                end

                if is_type_ctor && length(operands) >= 1
                    # Type constructor: pass through the input wire
                    dep_id = resolve_operand(operands[end])
                    if dep_id !== nothing && dep_id != -1
                        ssa_map[var] = dep_id
                        continue
                    end
                end

                if callee_sym !== nothing
                    # Skip known passthrough intrinsics (type conversions, etc.)
                    if callee_sym in (:bitcast, :trunc_int, :zext_int, :sext_int,
                        :sitofp, :fptosi, :fpext, :fptrunc,
                        :checked_trunc_sint, :checked_trunc_uint,
                        :check_top_bit, :toInt32, :toInt64,
                        :convert, :unsafe_convert,
                        :Int32, :Int64, :UInt32, :UInt64,
                        :Float32, :Float64, :Bool)
                        # Type conversion: pass through the input wire
                        if length(operands) >= 1
                            dep_id = resolve_operand(operands[end])
                            if dep_id !== nothing && dep_id != -1
                                ssa_map[var] = dep_id
                                continue
                            end
                        end
                    end
                end

                # Truly opaque emit warning and insert placeholder node
                input_ids = Int[]
                for op_val in operands
                    dep_id = resolve_operand(op_val)
                    if dep_id !== nothing && dep_id != -1
                        push!(input_ids, dep_id)
                    end
                end

                id = new_id()
                params = Dict{Symbol,Any}(:callee => string(callee))
                # Use latency=1 so the scheduler doesn't crash on unknown primitives
                node = DFGNode(id, OP_PRIMITIVE, 32, input_ids, nothing, 0, 1, :opaque, params)
                nodes[id] = node
                ssa_map[var] = id
                fsm.node_state[id] = blk_idx
                @warn "[IRTranslator] Unsupported call mapped to :opaque primitive" callee
            end
        end

        # Process branches (control flow)
        for br in branches(block)
            if isreturn(br)
                # ReturnNode → OP_RET
                ret_val = br.args[1]
                dep_id = resolve_operand(ret_val)
                if dep_id !== nothing && dep_id != -1
                    id = new_id()
                    node = DFGNode(id, OP_RET, nodes[dep_id].bit_width, [dep_id],
                        nothing, 0, 0, nothing, Dict{Symbol,Any}())
                    nodes[id] = node
                    push!(graph_outputs, id)
                    # Map the return node to the block it was created in.   
                    fsm.node_state[id] = blk_idx
                end
            else
                # GotoNode / GotoIfNot (conditional or unconditional branch)
                target_blk = br.block
                if target_blk === nothing
                    continue
                end

                target_id = target_blk isa Integer ? target_blk : target_blk

                if br.condition !== nothing
                    # Conditional branch: GotoIfNot(cond, target)
                    cond_id = resolve_operand(br.condition)
                    fsm.states[blk_idx].true_successor = target_id

                    # The condition wire becomes the entry_cond for the target block
                    if cond_id !== nothing && cond_id != -1
                        if !haskey(fsm.states, target_id)
                            fsm.states[target_id] = FSMState(target_id, cond_id, Int[], nothing, nothing)
                        else
                            fsm.states[target_id].entry_cond = cond_id
                        end
                    end
                else
                    # Unconditional branch
                    if fsm.states[blk_idx].true_successor === nothing
                        fsm.states[blk_idx].true_successor = target_id
                    else
                        fsm.states[blk_idx].false_successor = target_id
                    end
                end

                # Record predecessor
                if !haskey(fsm.states, target_id)
                    fsm.states[target_id] = FSMState(target_id, nothing, [blk_idx], nothing, nothing)
                else
                    push!(fsm.states[target_id].predecessors, blk_idx)
                end

                # Map branch arguments (PhiNode equivalent)
                # In IRTools, phi-like behavior is encoded as branch arguments:
                # br(target, val1, val2, ...) maps to the target block's arguments.
                #
                # We handle two structurally distinct cases:
                #   (A) LOOP-HEADER PHI: the target is (or will become) a loop header
                #       AND this predecessor is a back-edge (blk_idx >= target_id).
                #       And emit an OP_REG node: inputs[1]=init_val, inputs[2]=update_val.
                #   (B) NORMAL MERGE PHI: a forward-edge convergence point.
                #       And promote to OP_MUX, or chain MUX nodes.
                if !isempty(br.args) && haskey(fsm.states, target_id)
                    target_block = blks[target_id]
                    target_args = arguments(target_block)
                    is_back_edge = (blk_idx >= target_id)

                    for (j, br_arg) in enumerate(br.args)
                        if j > length(target_args)
                            break
                        end
                        targ_var = target_args[j]
                        dep_id = resolve_operand(br_arg)
                        if dep_id === nothing || dep_id == -1
                            continue
                        end

                        if haskey(ssa_map, targ_var)
                            existing_id = ssa_map[targ_var]
                            existing_node = nodes[existing_id]

                            if is_back_edge
                                # ── Case A: back-edge arriving at (potential) loop header ──
                                # The existing_id is the init value (from the pre-loop
                                # forward predecessor); dep_id is the loop-body update.
                                # Promote to OP_REG if not already one; otherwise just
                                # update inputs[2] (the update port).
                                if existing_node.op == OP_REG
                                    existing_node.inputs[2] = dep_id
                                else
                                    bw = max(nodes[existing_id].bit_width,
                                        haskey(nodes, dep_id) ? nodes[dep_id].bit_width : 32)
                                    reg_id = new_id()
                                    # inputs: [init_val, update_val]
                                    reg_node = DFGNode(reg_id, OP_REG, bw,
                                        [existing_id, dep_id],
                                        nothing, 0, 1, nothing, Dict{Symbol,Any}())
                                    nodes[reg_id] = reg_node
                                    ssa_map[targ_var] = reg_id
                                    fsm.node_state[reg_id] = target_id
                                end
                                # Mark the target as a loop header
                                fsm.states[target_id].is_loop_header = true
                                if blk_idx ∉ fsm.states[target_id].back_edge_preds
                                    push!(fsm.states[target_id].back_edge_preds, blk_idx)
                                end
                            else
                                # ── Case B: normal forward-edge merge ──
                                if existing_node.op == OP_MUX
                                    # Already a MUX. Chain a new MUX rather than
                                    # clobbering inputs[2] (fixes the >2-predecessor drop).
                                    select_id = fsm.states[target_id].entry_cond
                                    if select_id === nothing
                                        select_id = existing_id
                                    end
                                    bw = max(existing_node.bit_width,
                                        haskey(nodes, dep_id) ? nodes[dep_id].bit_width : 32)
                                    chain_mux_id = new_id()
                                    chain_mux = DFGNode(chain_mux_id, OP_MUX, bw,
                                        [select_id, existing_id, dep_id],
                                        nothing, 0, 0, nothing, Dict{Symbol,Any}())
                                    nodes[chain_mux_id] = chain_mux
                                    ssa_map[targ_var] = chain_mux_id
                                    fsm.node_state[chain_mux_id] = target_id
                                else
                                    # First collision: promote to MUX
                                    mux_id = new_id()
                                    select_id = fsm.states[target_id].entry_cond
                                    if select_id === nothing
                                        select_id = existing_id
                                    end
                                    bw = max(nodes[existing_id].bit_width,
                                        haskey(nodes, dep_id) ? nodes[dep_id].bit_width : 32)
                                    mux_node = DFGNode(mux_id, OP_MUX, bw,
                                        [select_id, existing_id, dep_id],
                                        nothing, 0, 0, nothing, Dict{Symbol,Any}())
                                    nodes[mux_id] = mux_node
                                    ssa_map[targ_var] = mux_id
                                    fsm.node_state[mux_id] = target_id
                                end
                            end
                        else
                            # First assignment to this target variable
                            ssa_map[targ_var] = dep_id
                        end
                    end
                end
            end
        end
    end

    # Post-walk back-edge detection pass
    # A second pass to catch any back-edges we may have missed during the
    # linear walk (e.g. the first time the target state was seen, its
    # predecessors were not yet fully recorded).
    for (bid, state) in fsm.states
        for pred_id in state.predecessors
            if pred_id >= bid
                state.is_loop_header = true
                if pred_id ∉ state.back_edge_preds
                    push!(state.back_edge_preds, pred_id)
                end
            end
        end
    end

    # Finalize

    # If no OP_RET was created (e.g., void-like function), add one
    if isempty(graph_outputs) && !isempty(nodes)
        # Find the last computed value
        last_id = maximum(keys(nodes))
        id = new_id()
        node = DFGNode(id, OP_RET, nodes[last_id].bit_width, [last_id],
            nothing, 0, 0, nothing, Dict{Symbol,Any}())
        nodes[id] = node
        push!(graph_outputs, id)
    end

    graph = HWGraph(name, nodes, graph_inputs, graph_outputs)
    return (graph, fsm)
end


"""
    _callee_name(callee) → Union{Symbol, Nothing}
Extract a Symbol name from various callee representations in IRTools.
"""
function _callee_name(callee)
    callee isa Symbol && return callee
    callee isa GlobalRef && return callee.name
    callee isa Function && return nameof(callee)
    callee isa QuoteNode && return _callee_name(callee.value)
    # Core.IntrinsicFunction etc.
    if hasproperty(callee, :name)
        return callee.name isa Symbol ? callee.name : Symbol(callee.name)
    end
    return nothing
end

"""
    _resolve_opcode(callee) → Union{Opcode, Nothing}
Look up the DFG opcode for a callee (function or intrinsic).
"""
function _resolve_opcode(callee)
    name = _callee_name(callee)
    name === nothing && return nothing

    # Check intrinsic map first (more specific)
    haskey(JULIA_OP_MAP, name) && return JULIA_OP_MAP[name]

    # Check Base operator map
    haskey(BASE_OP_MAP, name) && return BASE_OP_MAP[name]

    # Handle qualified names like Base.+
    if callee isa GlobalRef
        haskey(BASE_OP_MAP, callee.name) && return BASE_OP_MAP[callee.name]
        haskey(JULIA_OP_MAP, callee.name) && return JULIA_OP_MAP[callee.name]
    end

    return nothing
end

"""
    _is_memory_op(callee) → Bool
Check if the callee is a memory access operation (getindex / setindex!).
"""
function _is_memory_op(callee)
    name = _callee_name(callee)
    name === nothing && return false
    return name in (:getindex, :setindex!, :arrayref, :arrayset,
        :unsafe_load, :unsafe_store!)
end

"""
    _is_setindex(callee) → Bool
Check if the callee is a write (setindex! / arrayset / unsafe_store!).
"""
function _is_setindex(callee)
    name = _callee_name(callee)
    name === nothing && return false
    return name in (:setindex!, :arrayset, :unsafe_store!)
end
