"""
tests/test_dfg.jl

End-to-end test: build a DFG, schedule it, emit SystemVerilog, verify output.

Graph: mac_plus_5  =>  (rs1 * rs2) + 5
  node 1: OP_ARG  (rs1)          -> cycle 1, latency 0
  node 2: OP_ARG  (rs2)          -> cycle 1, latency 0
  node 3: OP_CONST 5             -> cycle 1, latency 0
  node 4: OP_MUL  (1 * 2)        -> cycle 2, latency 2, finishes cycle 3
  node 5: OP_ADD  (4 + 3)        -> cycle 4, latency 1, finishes cycle 4
  node 6: OP_RET  (5)            -> cycle 4, latency 0
Expected latency: 4 (MUL takes 2 cycles)
"""

using HWExplore

# Build — latency 0 means "use OP_LATENCY default"
node_1 = DFGNode(1, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict())
node_2 = DFGNode(2, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict())
node_3 = DFGNode(3, OP_CONST, 32, [],    5,       0, 0, nothing, Dict())
node_4 = DFGNode(4, OP_MUL,   32, [1,2], nothing, 0, 0, nothing, Dict())
node_5 = DFGNode(5, OP_ADD,   32, [4,3], nothing, 0, 0, nothing, Dict())
node_6 = DFGNode(6, OP_RET,   32, [5],   nothing, 0, 0, nothing, Dict())

graph = HWGraph(
  "mac_plus_5",
  Dict(1 => node_1, 2 => node_2, 3 => node_3, 4 => node_4, 5 => node_5, 6 => node_6),
  [1, 2],
  [6]
)

# Schedule
schedule_asap!(graph)

println("Scheduled cycles:")
for id in sort(collect(keys(graph.nodes)))
  n = graph.nodes[id]
  println("  node $(n.id) ($(n.op)) -> start cycle $(n.scheduled_cycle), latency $(n.latency), finish cycle $(finish_cycle(n))")
end

@assert graph.nodes[1].scheduled_cycle == 1 "OP_ARG must be cycle 1"
@assert graph.nodes[3].scheduled_cycle == 1 "OP_CONST must be cycle 1"
@assert graph.nodes[4].scheduled_cycle == 2 "MUL must start at cycle 2"
@assert graph.nodes[4].latency == 2 "MUL latency must be 2"
@assert finish_cycle(graph.nodes[4]) == 3 "MUL must finish at cycle 3"
@assert graph.nodes[5].scheduled_cycle == 4 "ADD must start at cycle 4 (waits for MUL to finish)"
@assert graph.latency == 4 "Total latency must be 4 (2-cycle MUL + 1-cycle ADD)"
println("Scheduling: PASS  (latency=$(graph.latency))")

# Emit SystemVerilog
out_sv = joinpath(@__DIR__, "..", "hw", "rtl", "generated", "mac_plus_5.sv")
emit_verilog(graph, out_sv)

sv_text = read(out_sv, String)
@assert occursin("module mac_plus_5", sv_text) "Missing module declaration"
@assert occursin("start_i", sv_text) "Missing start_i"
@assert occursin("done_o", sv_text) "Missing done_o"
@assert occursin("rs1_i", sv_text) "Missing rs1_i"
@assert occursin("rs2_i", sv_text) "Missing rs2_i"
@assert occursin("rd_o", sv_text) "Missing rd_o"
@assert occursin("always_ff", sv_text) "Missing pipeline registers"
@assert occursin("endmodule", sv_text) "Missing endmodule"
@assert occursin("n4_r2", sv_text) "Missing n4_r2 pipeline register"
@assert occursin("n4_r3", sv_text) "Missing n4_r3 pipeline register (multi-cycle MUL)"
println("Emit: PASS  (written to $out_sv)")