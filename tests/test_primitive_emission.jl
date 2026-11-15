# tests/test_primitive_emission.jl
#
# OP_PRIMITIVE wiring in VerilogEmitter.jl: a DFGNode whose `.primitive`
# references a PrimitiveLibrary.jl entry gets instantiated as a real module
# (not just latency-accounted), with a start-pulse delay that lands its
# result in the exact cycle any consumer expects it.
# Run with: julia --project=. tests/test_primitive_emission.jl

using Test
using HWExplore

make_node(id, op, inputs; const_val=nothing, latency=0, primitive=nothing, params=Dict{Symbol,Any}()) =
    DFGNode(id, op, 32, inputs, const_val, 0, latency, primitive, params)

@testset "HWExplore — OP_PRIMITIVE emission" begin
    @testset "primitive fed directly by args: 1-tick start delay" begin
        nodes = Dict{Int,DFGNode}(
            1 => make_node(1, OP_ARG, Int[]),
            2 => make_node(2, OP_ARG, Int[]),
            3 => make_node(3, OP_PRIMITIVE, [1, 2]; primitive=:saturating_add),
            4 => make_node(4, OP_RET, [3]),
        )
        g = HWGraph("prim_direct", nodes, [1, 2], [4])
        schedule_asap!(g)
        @test g.nodes[3].latency == 2          # pulled from PrimitiveSpec, not OP_LATENCY
        # Args finish at cycle 1 (schedule_asap! always starts a consumer at
        # max_dep_finish + 1), so even a primitive fed directly by args is
        # scheduled at cycle 2 -> a 1-tick start delay, never 0.
        @test g.nodes[3].scheduled_cycle == 2
        @test finish_cycle(g.nodes[3]) == 3
        @test g.latency == 3

        path = tempname() * ".sv"
        emit_verilog(g, path)
        sv = read(path, String)
        @test occursin("hwx_saturating_add", sv)
        @test occursin("logic [0:0] prim3_start_sr;", sv)
        @test occursin(".start_i (prim3_start_sr[0])", sv)
        @test occursin("prim3_start_sr <= start_i;", sv)  # 1-bit: direct assign, no concat shift
        @test occursin("assign rd_o = n3_r3;", sv)         # module output IS the primitive's result
        rm(path)
    end

    @testset "primitive downstream of compute nodes: start pulse delayed to match" begin
        nodes = Dict{Int,DFGNode}(
            1 => make_node(1, OP_ARG, Int[]),
            2 => make_node(2, OP_ARG, Int[]),
            3 => make_node(3, OP_ADD, [1, 2]),
            4 => make_node(4, OP_ADD, [3, 3]),
            5 => make_node(5, OP_PRIMITIVE, [4, 4]; primitive=:simd_mac),
            6 => make_node(6, OP_RET, [5]),
        )
        g = HWGraph("prim_deep", nodes, [1, 2], [6])
        schedule_asap!(g)
        n5 = g.nodes[5]
        @test n5.scheduled_cycle == 4   # after the 2-stage ADD chain
        @test finish_cycle(n5) == 6     # 4 + simd_mac's latency(3) - 1

        path = tempname() * ".sv"
        emit_verilog(g, path)
        sv = read(path, String)
        @test occursin("logic [2:0] prim5_start_sr;", sv)      # delay = scheduled_cycle - 1 = 3
        @test occursin(".start_i (prim5_start_sr[2])", sv)
        @test occursin("prim5_start_sr <= {prim5_start_sr[1:0], start_i};", sv)
        @test occursin(".rd_o    (n5_r6)", sv)                 # reg_wire(id, finish_cycle)
        rm(path)
    end

    @testset "parameter overrides are merged and emitted" begin
        nodes = Dict{Int,DFGNode}(
            1 => make_node(1, OP_ARG, Int[]),
            2 => make_node(2, OP_ARG, Int[]),
            3 => make_node(3, OP_PRIMITIVE, [1, 2]; primitive=:saturating_add,
                           params=Dict{Symbol,Any}(:LANES => 2)),
            4 => make_node(4, OP_RET, [3]),
        )
        g = HWGraph("prim_params", nodes, [1, 2], [4])
        schedule_asap!(g)
        path = tempname() * ".sv"
        emit_verilog(g, path)
        sv = read(path, String)
        @test occursin(".LANES(2)", sv)         # node override wins
        @test occursin(".DATA_WIDTH(8)", sv)    # registered default, untouched
        rm(path)
    end

    @testset "unregistered/placeholder primitives are rejected, not silently emitted" begin
        for prim in (:opaque, :bram_read, :not_a_real_primitive)
            nodes = Dict{Int,DFGNode}(
                1 => make_node(1, OP_ARG, Int[]),
                2 => make_node(2, OP_ARG, Int[]),
                3 => make_node(3, OP_PRIMITIVE, [1, 2]; primitive=prim, latency=1),
                4 => make_node(4, OP_RET, [3]),
            )
            g = HWGraph("prim_bad_$(prim)", nodes, [1, 2], [4])
            schedule_asap!(g)
            @test_throws ErrorException emit_verilog(g, tempname() * ".sv")
        end
    end

    @testset "variable-latency primitives are rejected (no static finish cycle)" begin
        nodes = Dict{Int,DFGNode}(
            1 => make_node(1, OP_ARG, Int[]),
            2 => make_node(2, OP_ARG, Int[]),
            3 => make_node(3, OP_PRIMITIVE, [1, 2]; primitive=:montgomery_multiplier),
            4 => make_node(4, OP_RET, [3]),
        )
        g = HWGraph("prim_variable", nodes, [1, 2], [4])
        schedule_asap!(g)
        @test_throws ErrorException emit_verilog(g, tempname() * ".sv")
    end

    @testset "wrong operand count is rejected" begin
        nodes = Dict{Int,DFGNode}(
            1 => make_node(1, OP_ARG, Int[]),
            3 => make_node(3, OP_PRIMITIVE, [1]; primitive=:saturating_add),
            4 => make_node(4, OP_RET, [3]),
        )
        g = HWGraph("prim_arity", nodes, [1], [4])
        schedule_asap!(g)
        @test_throws ErrorException emit_verilog(g, tempname() * ".sv")
    end
end
