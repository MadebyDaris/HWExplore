# tests/test_scheduler_alap.jl
#
# ALAP / mobility / schedule validation (src/HWGen/Scheduler.jl), one testset per
# fixed issue, plus property checks on random graphs.
# Run with: julia --project=. tests/test_scheduler_alap.jl

using Test, Random
using HWExplore

mk(id, op, ins; c=nothing) = DFGNode(id, op, 32, ins, c, 0, 0, nothing, Dict{Symbol,Any}())

# y = a*b + (c+d): MUL (2 cycles) is critical, ADD_cd can wait one cycle.
#   ids: 5 = MUL, 6 = ADD_cd, 7 = ADD_final, 8 = RET
toy() = HWGraph("toy", Dict(1 => mk(1, OP_ARG, Int[]), 2 => mk(2, OP_ARG, Int[]),
    3 => mk(3, OP_ARG, Int[]), 4 => mk(4, OP_ARG, Int[]),
    5 => mk(5, OP_MUL, [1, 2]), 6 => mk(6, OP_ADD, [3, 4]), 7 => mk(7, OP_ADD, [5, 6]),
    8 => mk(8, OP_RET, [7])), [1, 2, 3, 4], [8])

snapshot(g) = (Dict(id => (n.scheduled_cycle, n.latency) for (id, n) in g.nodes), g.latency)

@testset "Scheduler — ALAP, mobility, check_schedule" begin

@testset "I1: OP_RET is a marker, so critical-path slack is exactly 0" begin
    m = mobility(toy())
    @test m[5] == (2, 2)          # MUL: critical
    @test m[6] == (2, 3)          # ADD_cd: slack 1
    @test m[7] == (4, 4)          # ADD_final: critical (was reported as slack -1)
    @test minimum(w[2] - w[1] for w in values(m)) == 0
end

@testset "I2: a compute node with no consumers finishes by L" begin
    g = toy()
    g.nodes[9] = mk(9, OP_MUL, [1, 3])          # dead 2-cycle MUL, consumed by nothing
    @test alap_starts(g, 4)[9] == 3             # starts 3, finishes 4 (= L); was 4 (finishing at 5)
    @test mobility(g)[9] == (2, 3)
end

@testset "I3: an infeasible latency is an error, not a silent clamp" begin
    @test_throws ErrorException mobility(toy(); latency=3)
    @test_throws ErrorException schedule_alap!(toy(); latency=3)
    @test alap_starts(toy(), 3)[5] == 1 && asap_starts(toy())[5] == 2   # visible, not clamped
end

@testset "I4: OP_REG loop back-edges are not dependencies" begin
    # acc = REG(init, acc + x): node 4 feeds REG's inputs[2] (the next iteration)
    g = HWGraph("acc", Dict(1 => mk(1, OP_ARG, Int[]), 2 => mk(2, OP_ARG, Int[]),
        3 => mk(3, OP_REG, [1, 4]), 4 => mk(4, OP_ADD, [3, 2]), 5 => mk(5, OP_RET, [4])), [1, 2], [5])
    @test forward_inputs(g.nodes[3]) == [1]
    m = mobility(g)
    @test m[3] == (2, 2) && m[4] == (3, 3)      # was: ADD forced before REG by the back-edge
    schedule_asap!(g)
    @test check_schedule(g)
end

@testset "I5: pure analysis vs. mutating schedulers" begin
    g = toy(); schedule_asap!(g)
    before = snapshot(g)
    asap_starts(g); alap_starts(g, 6); mobility(g; latency=6)
    @test snapshot(g) == before                  # the pure functions touched nothing
    g = toy(); schedule_alap!(g)                 # works on a never-scheduled graph, no recursion
    @test g.latency == 4 && g.nodes[6].scheduled_cycle == 3
    @test check_schedule(g)
    g = toy(); schedule_alap!(g; latency=6)      # a looser target shifts everything later
    @test [g.nodes[i].scheduled_cycle for i in 5:7] == [4, 5, 6]
    @test g.nodes[8].scheduled_cycle == 6 && g.latency == 6
    @test check_schedule(g)
end

@testset "I6: list priority uses the deadline, not a stale precomputed slack" begin
    # Smallest of 36 random graphs where the old (ALAP - ASAP) priority lost a cycle
    # with one adder: old latency 9, deadline priority 8.
    n = Dict(1 => mk(1, OP_ARG, Int[]), 2 => mk(2, OP_ARG, Int[]),
        3 => mk(3, OP_ADD, [1, 2]), 4 => mk(4, OP_ADD, [3, 3]), 5 => mk(5, OP_ADD, [2, 4]),
        6 => mk(6, OP_ADD, [3, 2]), 7 => mk(7, OP_XOR, [2, 5]), 8 => mk(8, OP_ADD, [5, 3]),
        9 => mk(9, OP_MUL, [3, 6]), 10 => mk(10, OP_ADD, [9, 7]), 11 => mk(11, OP_ADD, [10, 8]),
        12 => mk(12, OP_RET, [11]))
    g = HWGraph("i6", n, [1, 2], [12])
    schedule_asap!(g; resources=Dict(OP_ADD => 1))
    @test g.latency == 8
    @test check_schedule(g)
end

@testset "I7: OP_RET sits on its input's finish after resource-constrained scheduling" begin
    g = toy(); schedule_asap!(g; resources=Dict(OP_ADD => 1))
    @test g.nodes[8].scheduled_cycle == finish_cycle(g.nodes[7])
    @test check_schedule(g)
end

@testset "check_schedule reports violations" begin
    g = toy(); schedule_asap!(g)
    g.nodes[7].scheduled_cycle = 3               # ADD_final before MUL (finishes 3) is done
    err = try check_schedule(g); "" catch e; e.msg end
    @test occursin("node 7", err) && occursin("input 5 finishes at 3", err)
    g = toy(); schedule_asap!(g); g.latency = 9
    @test_throws ErrorException check_schedule(g)
end

@testset "properties on random graphs" begin
    function rgraph(rng)
        nin = rand(rng, 2:5)
        n = Dict{Int,DFGNode}(i => mk(i, OP_ARG, Int[]) for i in 1:nin)
        last = nin
        for k in 1:rand(rng, 3:16)
            last += 1
            n[last] = mk(last, rand(rng, [OP_ADD, OP_SUB, OP_MUL, OP_XOR]), [rand(rng, 1:last-1), rand(rng, 1:last-1)])
        end
        n[last+1] = mk(last + 1, OP_RET, [last])
        HWGraph("r", n, collect(1:nin), [last + 1])
    end
    rng = Xoshiro(2026)
    ok = true
    for _ in 1:300
        g = rgraph(rng)
        m = mobility(g)
        L = HWExplore.schedule_latency(g, asap_starts(g))
        ok &= all(w[1] <= w[2] for w in values(m))                         # every window non-empty
        ok &= isempty(m) || minimum(w[2] - w[1] for w in values(m)) == 0   # a critical path exists
        for k in (0, 1, 3)
            h = deepcopy(g); schedule_alap!(h; latency=L + k)
            ok &= check_schedule(h) && h.latency == L + k
        end
        for b in (Dict(), Dict(OP_ADD => 1), Dict(OP_MUL => 1, OP_ADD => 1))
            h = deepcopy(g); schedule_asap!(h; resources=b)
            ok &= check_schedule(h) && h.latency >= L
        end
        h = deepcopy(g); schedule_asap!(h)                                  # unconstrained == ASAP
        a = asap_starts(g)
        ok &= all(h.nodes[id].scheduled_cycle == a[id] for id in keys(a))
    end
    @test ok
end

end
