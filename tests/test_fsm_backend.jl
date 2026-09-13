# tests/test_fsm_backend.jl
#
# Tests for the FSM sequential backend:
# Back-edge detection
# Liveness analysis (live_across)
# >2-predecessor MUX chaining (correctness fix)
# FSM Verilog emission (structural smoke-tests)
#

using Test
using HWExplore

function fsm_acc(a::Int32, n::Int32)
    acc = Int32(0)
    i = Int32(1)
    while i <= n
        acc += a
        i += Int32(1)
    end
    acc
end

function fsm_add(a::Int32, b::Int32)
    Base.add_int(a, b)
end

function fsm_mac(a::Int32, b::Int32)
    Base.add_int(Base.mul_int(a, b), Int32(5))
end

function fsm_3way(a::Int32, b::Int32, c::Int32)
    if a > Int32(0)
        b
    elseif a < Int32(0)
        c
    else
        Int32(0)
    end
end

@testset "HWExplore — FSM Sequential Backend" begin
    @testset "Back-edge detection — simple accumulator loop" begin
        _, fsm = extract_and_translate(fsm_acc, Tuple{Int32,Int32}; name="fsm_acc_be")

        # At least one state should be flagged as a loop header
        @test any(s -> s.is_loop_header, values(fsm.states))

        loop_headers = filter(s -> s.is_loop_header, collect(values(fsm.states)))
        @test !isempty(loop_headers)
        @test any(s -> !isempty(s.back_edge_preds), loop_headers)
    end

    @testset "OP_REG nodes created for loop-carried phi" begin
        graph, _ = extract_and_translate(fsm_acc, Tuple{Int32,Int32}; name="fsm_acc_reg")

        reg_nodes = [n for n in values(graph.nodes) if n.op == OP_REG]
        @test !isempty(reg_nodes)

        # Each OP_REG should have exactly 2 inputs: [init_val, update_val]
        for rn in reg_nodes
            @test length(rn.inputs) == 2
        end
    end

    @testset "FSMGraph.node_state populated" begin
        graph, fsm = extract_and_translate(fsm_add, Tuple{Int32,Int32}; name="fsm_add_ns")

        for (id, node) in graph.nodes
            node.op in (OP_ARG, OP_CONST) && continue
            @test haskey(fsm.node_state, id)
        end
    end

    @testset "schedule_asap! handles OP_REG without cycle error" begin
        graph, _ = extract_and_translate(fsm_acc, Tuple{Int32,Int32}; name="fsm_acc_sched")
        # Must not throw "Cycle in DFG"
        @test_nowarn schedule_asap!(graph)
        @test graph.latency > 0
    end

    @testset "analyse_fsm — liveness on loop function" begin
        graph, fsm = extract_and_translate(fsm_acc, Tuple{Int32,Int32}; name="fsm_acc_live")
        schedule_asap!(graph)
        analysis = analyse_fsm(graph, fsm)

        @test !isempty(analysis.back_edges)
        @test !isempty(analysis.reg_nodes)
        @test sort(analysis.state_order) == sort(collect(keys(fsm.states)))
    end

    @testset "emit_fsm_verilog — structural smoke test (pure add)" begin
        graph, fsm = extract_and_translate(fsm_add, Tuple{Int32,Int32}; name="fsm_add_sv")
        schedule_asap!(graph)

        tmp = mktempdir()
        out = joinpath(tmp, "add_fsm.sv")
        emit_fsm_verilog(graph, fsm, out)
        sv = read(out, String)

        @test occursin("module fsm_add_sv", sv)
        @test occursin("case (state)", sv)
        @test occursin("S_IDLE", sv)
        @test occursin("S_DONE", sv)
        @test occursin("done_o", sv)
        @test occursin("rd_o", sv)
        @test occursin("endmodule", sv)
        @test occursin("clk_i", sv)
        @test occursin("rst_ni", sv)
    end

    @testset "emit_fsm_verilog — loop function produces FF declarations" begin
        graph, fsm = extract_and_translate(fsm_acc, Tuple{Int32,Int32}; name="fsm_acc_loop")
        schedule_asap!(graph)

        tmp = mktempdir()
        out = joinpath(tmp, "acc_loop.sv")
        emit_fsm_verilog(graph, fsm, out)
        sv = read(out, String)

        # State-crossing flip-flop declarations (_ff suffix)
        @test occursin("_ff", sv)
        @test occursin("case (state)", sv)
        @test occursin("S_DONE", sv)
        @test occursin("always_ff", sv)
        @test occursin("endmodule", sv)
    end

    @testset ">2-predecessor MUX chaining — no silent drop" begin
        # A simple conditional (2 predecessors) is sufficient to produce an OP_MUX.
        # Verifying that no OP_MUX has < 3 inputs is the key correctness check.
        graph, _ = extract_and_translate(fsm_3way, Tuple{Int32,Int32,Int32}; name="fsm_3way")

        mux_nodes = [n for n in values(graph.nodes) if n.op == OP_MUX]

        for mn in mux_nodes
            @test length(mn.inputs) == 3
        end
        # The key invariant: no node is missing inputs due to the silent-drop bug.
        for (_, node) in graph.nodes
            if node.op == OP_MUX
                @test length(node.inputs) >= 3
            end
        end

        # Verify the graph is schedulable (no dangling edges from the drop)
        @test_nowarn schedule_asap!(graph)
    end

    @testset "Regression — existing emit_verilog still works after FSM changes" begin
        graph, _ = extract_and_translate(fsm_mac, Tuple{Int32,Int32}; name="mac5_reg")
        schedule_asap!(graph)

        tmp = mktempdir()
        out = joinpath(tmp, "mac5_reg.sv")
        emit_verilog(graph, out)
        sv = read(out, String)

        @test occursin("module mac5_reg", sv)
        @test occursin("clk_i", sv)
        @test occursin("endmodule", sv)
        # Should NOT contain FSM machinery
        @test !occursin("case (state)", sv)
    end

end

println("\n=== FSM backend tests passed! ===")
