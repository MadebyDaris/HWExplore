# examples/dot_sweep.jl
#
# Synthesize a set of dot-product engine design points on SG13G2 (Yosys + ABC,
# logic only) and write synth/results/dot_sweep_<pdk>.csv. Every point is first
# checked bit-exactly in Verilator unless VERIFY=0.
#
#   julia -t 8 --project=. examples/dot_sweep.jl [pdk]

include(joinpath(@__DIR__, "..", "src", "DotGen", "DotGen.jl"))
using .DotGen

pdk = isempty(ARGS) ? "sg13g2" : ARGS[1]
verify = get(ENV, "VERIFY", "1") != "0"

points = [
    # label                         config
    ("mxfp4×mxfp4",                 (a="mxfp4", b="mxfp4")),
    ("mxfp4×mxfp8 (E4M3)",          (a="mxfp4", b="mxfp8")),
    ("mxfp4×mxfp8, adder tree",     (a="mxfp4", b="mxfp8", tree=:adder)),
    ("mxfp4×mxfp8, window 16",      (a="mxfp4", b="mxfp8", window=16)),
    ("mxfp6×mxfp6 (E2M3)",          (a="mxfp6e2m3", b="mxfp6e2m3")),
    ("mxfp8×mxfp8 (E4M3)",          (a="mxfp8", b="mxfp8")),
    ("mxfp8×mxfp8, window 16",      (a="mxfp8", b="mxfp8", window=16)),
    ("mxfp8×mxfp8 (E5M2)",          (a="mxfp8e5m2", b="mxfp8e5m2")),
    ("mxint8×mxint8",               (a="mxint8", b="mxint8")),
    ("ternary×mxfp8",               (a="ternary", b="mxfp8")),
    ("int4×int8 → int32",           (a="int4", b="int8", acc="int32")),
    ("int8×int8 → int32",           (a="int8", b="int8", acc="int32")),
    ("ternary×int8 → int32",        (a="ternary", b="int8", acc="int32")),
]

root = mktempdir()
rows = Vector{Any}(undef, length(points))
Threads.@threads for i in eachindex(points)
    label, kw = points[i]
    cfg = DotConfig(; block=32, acc="fp32", stages=2, kw...)
    dir = joinpath(root, cfg.name * "_$i")
    ok = verify ? verify_dot(cfg; dir=joinpath(dir, "v"), nrand=2000, verbose=false).errors == 0 : missing
    s = synth_dot(cfg; pdk, dir=joinpath(dir, "s"))
    w = DotGen.widths(cfg)
    rows[i] = (label, cfg.name, w.Ws, s.area_um2, s.cells, s.flops, s.delay_ps, ok)
    println("done: ", label, "  ", round(s.area_um2), " µm²")
end

out = joinpath(@__DIR__, "..", "synth", "results", "dot_sweep_$(pdk).csv")
open(out, "w") do io
    println(io, "label,module,sum_bits,area_um2,cells,flops,logic_delay_ps,bit_exact")
    for r in rows
        println(io, join([r[1], r[2], r[3], round(r[4], digits=1), r[5], r[6], round(r[7], digits=1), r[8]], ","))
    end
end
println("\n", rpad("design", 28), lpad("sum b", 6), lpad("area µm²", 11), lpad("cells", 8), lpad("ns", 7), "  bit-exact")
for r in rows
    println(rpad(r[1], 28), lpad(r[3], 6), lpad(round(Int, r[4]), 11), lpad(r[5], 8), lpad(round(r[7] / 1000, digits=2), 7), "  ", r[8])
end
println("\nwrote ", normpath(out))
