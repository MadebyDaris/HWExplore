# tests/runtests.jl
# Julia automated test suite for HWExplore — run with: julia --project=. tests/runtests.jl

using Test
using HWExplore

@testset "HWExplore — DFG Types & Scheduler" begin

    @testset "Opcode enum" begin
        @test OP_ARG   == OP_ARG
        @test OP_ADD   != OP_SUB
        @test OP_MUX   != OP_RET
        @test length(instances(Opcode)) >= 12  # we have at least 12 opcodes
    end

    @testset "OP_LATENCY table" begin
        @test OP_LATENCY[OP_ARG]   == 0
        @test OP_LATENCY[OP_CONST] == 0
        @test OP_LATENCY[OP_RET]   == 0
        @test OP_LATENCY[OP_ADD]   == 1
        @test OP_LATENCY[OP_MUL]   == 2
        @test OP_LATENCY[OP_MOD]   == 3
        @test OP_LATENCY[OP_MUX]   == 1
    end

    @testset "DFGNode construction" begin
        n = DFGNode(1, OP_ADD, 32, [2, 3], nothing, 0, 0, nothing, Dict())
        @test n.id == 1
        @test n.op == OP_ADD
        @test n.bit_width == 32
        @test n.inputs == [2, 3]
        @test n.const_val === nothing
        @test n.latency == 0  # before scheduling
        @test n.primitive === nothing
    end

    @testset "HWGraph construction" begin
        nodes = Dict(
            1 => DFGNode(1, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
            2 => DFGNode(2, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
            3 => DFGNode(3, OP_ADD,   32, [1,2], nothing, 0, 0, nothing, Dict()),
            4 => DFGNode(4, OP_RET,   32, [3],   nothing, 0, 0, nothing, Dict()),
        )
        g = HWGraph("adder", nodes, [1, 2], [4])
        @test g.name == "adder"
        @test g.graph_inputs == [1, 2]
        @test g.graph_outputs == [4]
        @test length(g.nodes) == 4
    end
end

@testset "HWExplore — Scheduling" begin
    nodes = Dict(
        1 => DFGNode(1, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
        2 => DFGNode(2, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
        3 => DFGNode(3, OP_CONST, 32, [],    5,       0, 0, nothing, Dict()),
        4 => DFGNode(4, OP_MUL,   32, [1,2], nothing, 0, 0, nothing, Dict()),
        5 => DFGNode(5, OP_ADD,   32, [4,3], nothing, 0, 0, nothing, Dict()),
        6 => DFGNode(6, OP_RET,   32, [5],   nothing, 0, 0, nothing, Dict()),
    )
    g = HWGraph("mac_plus_5", nodes, [1, 2], [6])

    @testset "topological_sort" begin
        order = topological_sort(g)
        @test length(order) == 6
        @test order[1] ∈ [1, 2, 3]  # sources first
        @test order[end] == 6       # RET last
    end

    @testset "schedule_asap! — multi-cycle" begin
        schedule_asap!(g)
        @test g.nodes[1].scheduled_cycle == 1
        @test g.nodes[4].scheduled_cycle == 2   # MUL starts at 2
        @test g.nodes[4].latency == 2            # MUL takes 2 cycles
        @test finish_cycle(g.nodes[4]) == 3       # MUL finishes at 3
        @test g.nodes[5].scheduled_cycle == 4    # ADD starts at 4
        @test g.latency == 4                      # total pipeline depth
    end

    @testset "Resource-constrained scheduling" begin
        # Two MULs competing for 1 multiplier with 1 ALU
        nodes2 = Dict(
            1 => DFGNode(1, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
            2 => DFGNode(2, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
            3 => DFGNode(3, OP_MUL,   32, [1,2], nothing, 0, 0, nothing, Dict()),
            4 => DFGNode(4, OP_MUL,   32, [1,2], nothing, 0, 0, nothing, Dict()),
            5 => DFGNode(5, OP_ADD,   32, [3,4], nothing, 0, 0, nothing, Dict()),
            6 => DFGNode(6, OP_RET,   32, [5],   nothing, 0, 0, nothing, Dict()),
        )
        g2 = HWGraph("double_mul", nodes2, [1, 2], [6])
        schedule_asap!(g2)
        @test g2.nodes[3].scheduled_cycle == 2   # first MUL
        @test g2.nodes[4].scheduled_cycle == 2   # also starts at 2 (parallel)
        @test g2.latency == 4

        budget = ResourceBudget(:ALU => 1, :MUL => 1)
        schedule_list!(g2, budget)
        # Both MULs compete for 1 multiplier — they must serialize
        cycles = [g2.nodes[3].scheduled_cycle, g2.nodes[4].scheduled_cycle]
        @test minimum(cycles) == 2           # first MUL at cycle 2
        @test maximum(cycles) >= 4           # second MUL serialized
        @test cycles[1] != cycles[2]         # not on same cycle
        @test g2.latency >= 5
    end
end

@testset "HWExplore — Verilog Emission" begin
    nodes = Dict(
        1 => DFGNode(1, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
        2 => DFGNode(2, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict()),
        3 => DFGNode(3, OP_ADD,   32, [1,2], nothing, 0, 0, nothing, Dict()),
        4 => DFGNode(4, OP_RET,   32, [3],   nothing, 0, 0, nothing, Dict()),
    )
    g = HWGraph("adder", nodes, [1, 2], [4])
    schedule_asap!(g)

    @testset "emit_verilog — golden checks" begin
        tmp = mktempdir()
        out = joinpath(tmp, "adder.sv")
        emit_verilog(g, out)
        sv = read(out, String)

        @test occursin("module adder", sv)
        @test occursin("clk_i", sv)
        @test occursin("rst_ni", sv)
        @test occursin("stall_i", sv)
        @test occursin("start_i", sv)
        @test occursin("rs1_i", sv)
        @test occursin("rs2_i", sv)
        @test occursin("rd_o", sv)
        @test occursin("done_o", sv)
        @test occursin("endmodule", sv)
        @test occursin("always_ff", sv)
    end

    @testset "emit_verilog — MUX opcode" begin
        crc_nodes = Dict(
            1 => DFGNode(1, OP_ARG,   32, [],       0,         0, 0, nothing, Dict()),
            2 => DFGNode(2, OP_CONST, 32, [],        0x04C11DB7, 0, 0, nothing, Dict()),
            3 => DFGNode(3, OP_CONST, 32, [],        0,         0, 0, nothing, Dict()),
            4 => DFGNode(4, OP_MUX,   32, [1,2,3],   nothing,   0, 0, nothing, Dict()),
            5 => DFGNode(5, OP_RET,   32, [4],       nothing,   0, 0, nothing, Dict()),
        )
        g2 = HWGraph("mux_test", crc_nodes, [1], [5])
        schedule_asap!(g2)
        tmp = mktempdir()
        out = joinpath(tmp, "mux_test.sv")
        emit_verilog(g2, out)
        sv = read(out, String)
        @test occursin("|", sv)  # reduction OR for condition
    end
end

@testset "HWExplore — Dispatcher" begin
    @testset "emit_dispatcher — generates valid SV" begin
        entries = [
            DatapathEntry("mac_plus_5", 0, 4, false, "mac_plus_5.sv"),
            DatapathEntry("crc_step",   1, 4, false, "crc_step.sv"),
        ]
        tmp = mktempdir()
        out = joinpath(tmp, "hwx_mux.sv")
        emit_dispatcher(entries, out)
        sv = read(out, String)
        @test occursin("module hwx_mux", sv)
        @test occursin("funct3_i", sv)
        @test occursin("start_0", sv)
        @test occursin("start_1", sv)
        @test occursin("mac_plus_5 u_dp_0", sv)
        @test occursin("crc_step u_dp_1", sv)
        @test occursin("endmodule", sv)
    end

    @testset "emit_dispatcher — rejects duplicates" begin
        entries = [
            DatapathEntry("a", 0, 1, false, "a.sv"),
            DatapathEntry("b", 0, 1, false, "b.sv"),
        ]
        @test_throws ErrorException emit_dispatcher(entries, "/dev/null")
    end
end

@testset "HWExplore — PrimitiveLibrary" begin
    @testset "Built-in primitives registered" begin
        @test haskey(PRIMITIVES, :simd_mac)
        @test haskey(PRIMITIVES, :barrett_reduction)
        @test haskey(PRIMITIVES, :montgomery_multiplier)
        @test haskey(PRIMITIVES, :saturating_add)
    end

    @testset "variable_latency flag" begin
        @test PRIMITIVES[:simd_mac].variable_latency == false
        @test PRIMITIVES[:montgomery_multiplier].variable_latency == true
    end

    @testset "register_primitive!" begin
        spec = PrimitiveSpec(:test_p, "test_p", "test_p.sv", 1, false, Dict())
        register_primitive!(spec)
        @test PRIMITIVES[:test_p] == spec
        delete!(PRIMITIVES, :test_p)
    end
end

println("\n=== All HWExplore tests passed! ===")