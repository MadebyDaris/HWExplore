# examples/resource_sharing_sweep.jl
#
# Resource sharing in one call: the same 4-element dot product, emitted with
# 4, 2 and 1 physical multipliers. Nothing about the Julia source changes —
# only the `share=` budget passed to emit_verilog. This is the smallest
# possible design-space sweep: one knob, three points, area-vs-latency.
#
#   julia --project=. examples/resource_sharing_sweep.jl
#
# Emits hw/rtl/generated/vector_dot4_shared_{4,2,1}.sv; test each one with
#   make -C hw/tb_veril test_vector_dot4_shared

using HWExplore

function dot4(a0::Int32, a1::Int32, a2::Int32, a3::Int32,
              b0::Int32, b1::Int32, b2::Int32, b3::Int32)
    p0 = a0 * b0
    p1 = a1 * b1
    p2 = a2 * b2
    p3 = a3 * b3
    (p0 + p1) + (p2 + p3)
end

const ARGS = Tuple{Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32}
outdir = joinpath(@__DIR__, "..", "hw", "rtl", "generated")

println("\n multipliers | latency (cycles) | shared units")
println(" ------------+------------------+-------------")
for muls in (4, 2, 1)
    graph, _ = extract_and_translate(dot4, ARGS; name = "vector_dot4_shared_$muls")
    emit_verilog(graph, joinpath(outdir, "vector_dot4_shared_$muls.sv"); share = Dict(OP_MUL => muls))
    r = sharing_report(graph, Dict(OP_MUL => muls))
    println(" $(lpad(muls, 11)) | $(lpad(r.latency, 16)) | $(r.units)")
end
