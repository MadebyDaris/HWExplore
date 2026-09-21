# examples/vector_dot4.jl
#
# A "bit complex" worked example: a 4-element vector dot product,
#   dot4(a, b) = a0*b0 + a1*b1 + a2*b2 + a3*b3
# written as plain Julia, compiled straight to a pipelined SystemVerilog
# datapath. Unlike mac_plus_5 (examples/run_pipeline.jl), this exercises the
# ASAP scheduler's instruction-level-parallelism handling for real: four
# independent multiplies can start in the same cycle, then a balanced
# add-reduction tree schedules across the cycles after.
#
# See docs/Usage_and_Examples.md for the full walkthrough and generated
# output, and for why this example is 8 scalar inputs rather than two
# CV-X-IF register operands (a real limitation worth understanding, not
# a bug).

using HWExplore

function dot4(a0::Int32, a1::Int32, a2::Int32, a3::Int32,
              b0::Int32, b1::Int32, b2::Int32, b3::Int32)
    p0 = a0 * b0
    p1 = a1 * b1
    p2 = a2 * b2
    p3 = a3 * b3
    (p0 + p1) + (p2 + p3)
end

println("Synthesizing dot4 to DFG...")
graph, fsm = extract_and_translate(
    dot4, Tuple{Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32}; name="vector_dot4")

println("Scheduling ASAP...")
schedule_asap!(graph)

for id in sort(collect(keys(graph.nodes)))
    node = graph.nodes[id]
    node.op in (OP_ARG, OP_CONST, OP_RET) && continue
    println("  node $id ($(node.op)) -> start cycle $(node.scheduled_cycle), finish cycle $(finish_cycle(node))")
end

filepath = joinpath(@__DIR__, "..", "hw", "rtl", "generated", "vector_dot4.sv")
println("Emitting Verilog to $filepath...")
emit_verilog(graph, filepath)

println("Done! Total latency: $(graph.latency) cycle(s)")
