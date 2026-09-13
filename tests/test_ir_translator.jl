# tests/test_ir_translator.jl
#
# Run with: julia --project=. tests/test_ir_translator.jl

using Test
using HWExplore
using IRTools: IRTools

@testset "HWExplore — Phase 2 & 3: IR Extraction + DFG Translation" begin

    @testset "extract_ir — basic IR extraction" begin
        # Simple arithmetic function using intrinsics
        f_add(a::Int32, b::Int32) = Base.add_int(a, b)
        ir = extract_ir(f_add, Tuple{Int32,Int32})
        @test ir !== nothing
        @test ir isa IRTools.IR
    end

    @testset "translate_ir_to_dfg — pure arithmetic (no control flow)" begin
        # f(a, b) = a * b + 5  (using intrinsics)
        f_mac(a::Int32, b::Int32) = Base.add_int(Base.mul_int(a, b), Int32(5))
        ir = extract_ir(f_mac, Tuple{Int32,Int32})
        graph, fsm = translate_ir_to_dfg(ir, "mul_add_5"; argtypes=Tuple{Int32,Int32})

        # Should have OP_ARG nodes for both inputs
        @test length(graph.graph_inputs) == 2
        # Should have at least 1 output
        @test length(graph.graph_outputs) >= 1
        # Should have at least: 2×ARG + MUL + ADD + CONST + RET
        @test length(graph.nodes) >= 5

        # Check argument nodes have correct type annotation
        for arg_id in graph.graph_inputs
            node = graph.nodes[arg_id]
            @test node.op == OP_ARG
            @test node.bit_width == 32
            @test node.julia_type === Int32
        end

        # Check that we have at least one OP_MUL and one OP_ADD
        opcodes = Set(n.op for n in values(graph.nodes))
        @test OP_MUL ∈ opcodes
        @test OP_ADD ∈ opcodes
        @test OP_RET ∈ opcodes
    end

    @testset "translate_ir_to_dfg — constant handling" begin
        # f(a) = a + 42
        f_const(a::Int32) = Base.add_int(a, Int32(42))
        ir = extract_ir(f_const, Tuple{Int32})
        graph, fsm = translate_ir_to_dfg(ir, "add_42"; argtypes=Tuple{Int32})

        # Should have 1 input argument
        @test length(graph.graph_inputs) == 1

        # Find the OP_CONST node with value 42
        const_nodes = [n for n in values(graph.nodes) if n.op == OP_CONST]
        @test length(const_nodes) >= 1
        @test any(n -> n.const_val == 42, const_nodes)
    end

    @testset "translate_ir_to_dfg — bit-width inference" begin
        # Int64 arguments should give 64-bit nodes
        f_64(a::Int64, b::Int64) = Base.add_int(a, b)
        ir = extract_ir(f_64, Tuple{Int64,Int64})
        graph, _ = translate_ir_to_dfg(ir, "add64"; argtypes=Tuple{Int64,Int64})

        for arg_id in graph.graph_inputs
            @test graph.nodes[arg_id].bit_width == 64
            @test graph.nodes[arg_id].julia_type === Int64
        end
    end

    @testset "extract_and_translate — end-to-end (simple)" begin
        f_e2e(a::Int32, b::Int32) = Base.add_int(a, b)
        graph, fsm = extract_and_translate(f_e2e, Tuple{Int32,Int32})

        @test graph.name == "f_e2e"
        @test length(graph.graph_inputs) == 2
        @test length(graph.graph_outputs) >= 1
        @test graph isa HWGraph
        @test fsm isa FSMGraph
    end

    @testset "extract_and_translate → schedule_asap! → pipeline" begin
        # End-to-end: extract, translate, schedule
        f_sched(a::Int32, b::Int32) = Base.add_int(Base.mul_int(a, b), Int32(5))
        graph, fsm = extract_and_translate(f_sched, Tuple{Int32,Int32}; name="mac5")

        # Schedule the graph
        schedule_asap!(graph)

        # Verify scheduling worked
        @test graph.latency > 0
        for node in values(graph.nodes)
            if node.op ∉ (OP_ARG, OP_CONST, OP_RET)
                @test node.scheduled_cycle > 0
            end
        end
    end

    @testset "extract_and_translate → schedule → emit_verilog" begin
        # Full pipeline: Julia function → Verilog
        f_full(a::Int32, b::Int32) = Base.add_int(Base.mul_int(a, b), Int32(5))
        graph, _ = extract_and_translate(f_full, Tuple{Int32,Int32}; name="mac5_full")
        schedule_asap!(graph)

        tmp = mktempdir()
        out = joinpath(tmp, "mac5_full.sv")
        emit_verilog(graph, out)
        sv = read(out, String)

        @test occursin("module mac5_full", sv)
        @test occursin("clk_i", sv)
        @test occursin("rs1_i", sv)
        @test occursin("rs2_i", sv)
        @test occursin("rd_o", sv)
        @test occursin("done_o", sv)
        @test occursin("endmodule", sv)
    end

    @testset "FSMGraph — basic block tracking" begin
        # A single basic block should produce at least 1 FSM state
        f_fsm(a::Int32, b::Int32) = Base.add_int(a, b)
        _, fsm = extract_and_translate(f_fsm, Tuple{Int32,Int32})
        @test length(fsm.states) >= 1
        @test haskey(fsm.states, 1)  # entry block
    end

    @testset "@synthesize macro — smoke test" begin
        # Ensure the macro works without error
        f_syn(a::Int32, b::Int32) = Base.add_int(a, b)
        graph, fsm = @synthesize f_syn(Int32(1), Int32(2))

        @test graph isa HWGraph
        @test fsm isa FSMGraph
        @test length(graph.graph_inputs) == 2
    end

    @testset "DFGNode backward compatibility — 9-arg constructor" begin
        # Ensure existing code using the 9-arg constructor still works
        n = DFGNode(1, OP_ADD, 32, [2, 3], nothing, 0, 0, nothing, Dict{Symbol,Any}())
        @test n.julia_type === nothing
        @test n.id == 1
        @test n.op == OP_ADD
    end

    @testset "DFGNode — 10-arg constructor with julia_type" begin
        # New constructor with type preservation
        n = DFGNode(1, OP_ARG, 32, Int[], nothing, 0, 0, nothing, Dict{Symbol,Any}(), Int32)
        @test n.julia_type === Int32
        @test n.bit_width == 32
    end
end

println("\n=== Phase 2 & 3 tests passed! ===")
