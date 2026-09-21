# tests/test_resource_sharing.jl
#
# Resource sharing (src/HWGen/ResourceSharing.jl): binding, emitted structure,
# and that the plain emitter is untouched when `share` is not given.
# Run with: julia --project=. tests/test_resource_sharing.jl

using Test
using HWExplore

function dot4(a0::Int32, a1::Int32, a2::Int32, a3::Int32,
              b0::Int32, b1::Int32, b2::Int32, b3::Int32)
    ((a0 * b0) + (a1 * b1)) + ((a2 * b2) + (a3 * b3))
end
const DOT4_ARGS = Tuple{Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32}

count_muls(sv) = count(l -> occursin(r"assign .* = .* \* .*;", l), split(sv, '\n'))

@testset "HWExplore — Resource sharing" begin
    @testset "bind_units: greedy interval coloring respects the budget" begin
        for budget in 1:4
            g, _ = extract_and_translate(dot4, DOT4_ARGS; name = "d$budget")
            schedule_asap!(g; resources = Dict(OP_MUL => budget))
            units = bind_units(g, Dict(OP_MUL => budget))
            @test length(units) <= budget
            @test sort(vcat((u.nodes for u in units)...)) ==
                  sort([id for (id, n) in g.nodes if n.op == OP_MUL])
            # nodes on one unit never overlap in time
            for u in units
                spans = sort([(g.nodes[i].scheduled_cycle, finish_cycle(g.nodes[i])) for i in u.nodes])
                @test all(spans[k][2] < spans[k+1][1] for k in 1:length(spans)-1)
            end
        end
    end

    @testset "bind_units errors on a schedule that exceeds the budget" begin
        g, _ = extract_and_translate(dot4, DOT4_ARGS; name = "too_many")
        schedule_asap!(g)                                   # unconstrained: 4 concurrent muls
        @test_throws ErrorException bind_units(g, Dict(OP_MUL => 1))
    end

    @testset "unsupported / invalid budgets are rejected" begin
        g, _ = extract_and_translate(dot4, DOT4_ARGS; name = "bad")
        @test_throws ErrorException emit_verilog(g, tempname() * ".sv"; share = Dict(OP_MUX => 1))
        @test_throws ErrorException emit_verilog(g, tempname() * ".sv"; share = Dict(OP_MUL => 0))
    end

    @testset "fewer multipliers => fewer operators, longer latency" begin
        lat, muls = Int[], Int[]
        for budget in (4, 2, 1)
            g, _ = extract_and_translate(dot4, DOT4_ARGS; name = "dot_m$budget")
            out = tempname() * ".sv"
            emit_verilog(g, out; share = Dict(OP_MUL => budget))
            sv = read(out, String)
            push!(muls, count_muls(sv))
            push!(lat, g.latency)
            @test occursin("module dot_m$budget", sv)
        end
        @test muls == [4, 2, 1]                # exactly the budgeted number of `*` operators
        @test issorted(lat) && lat[1] < lat[end]
    end

    @testset "shared unit structure: one-hot selects, operand mux, result holds" begin
        g, _ = extract_and_translate(dot4, DOT4_ARGS; name = "dot_m1")
        out = tempname() * ".sv"
        emit_verilog(g, out; share = Dict(OP_MUL => 1))
        sv = read(out, String)
        @test occursin("mul0_a = sel_", sv) && occursin("mul0_b = sel_", sv)
        @test occursin("assign mul0_y = mul0_a * mul0_b;", sv)
        @test occursin("assign sel_", sv) && occursin("start_i", sv) && occursin("done_shift[", sv)
        @test occursin("_hold <=", sv)
        @test occursin("_q <= rs", sv)          # inputs read after cycle 2 are latched
        @test occursin("Initiation interval", sv)
    end

    @testset "no `share` => plain emitter output is unchanged" begin
        g, _ = extract_and_translate(dot4, DOT4_ARGS; name = "dot_plain")
        schedule_asap!(g)
        out = tempname() * ".sv"
        emit_verilog(g, out)
        sv = read(out, String)
        @test !occursin("resource-shared", sv) && !occursin("_hold", sv)
        @test count_muls(sv) == 4
    end

    @testset "sharing_report" begin
        g, _ = extract_and_translate(dot4, DOT4_ARGS; name = "rep")
        r = sharing_report(g, Dict(OP_MUL => 2))
        @test r.operators_unshared == 4 && r.units == 2 && r.latency > 5
    end
end
println("\n=== Resource sharing tests passed! ===")
