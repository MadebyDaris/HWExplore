# examples/pareto_mxfp8_dot.jl
#
# Pareto frontier of ONE arithmetic operation:
#
#     MXFP8 (E4M3) × MXFP8 dot product, block K = 32, FP32 result
#
# Design knobs:  alignment window W (bits kept per aligned product, or exact)
#                × reduction tree (3:2 carry-save tree vs adder tree)
# Objectives (all minimized):
#   area   SG13G2 cell area after Yosys+ABC                     (cost)
#   delay  ABC critical-path estimate, logic only               (speed)
#   error  mean |hw − exact| / Σ|a_i b_i| on realistic MX data  (accuracy)
#
#   julia -t 3 examples/pareto_mxfp8_dot.jl          # VERIFY=0 to skip Verilator
#
# Synthesis results are cached in synth/results/pareto_mxfp8_dot_synth.csv, so adding a
# design point only synthesizes that point. Output: synth/results/pareto_mxfp8_dot.csv and,
# if matplotlib is available, synth/results/pareto_mxfp8_dot.png.

include(joinpath(@__DIR__, "..", "src", "DotGen", "DotGen.jl"))
using .DotGen
using Printf

const RESULTS = joinpath(@__DIR__, "..", "synth", "results")
const OP = (a="mxfp8", b="mxfp8", block=32, acc="fp32", stages=2)
const PDK = get(ENV, "PDK", "sg13g2")
const NBLOCKS = parse(Int, get(ENV, "NBLOCKS", "2000"))

windows = [8, 10, 12, 14, 16, 18, 20, 22, 24, 28, nothing]
trees = [:csa, :adder]
wname(W) = W === nothing ? "exact" : string(W)
designs = [DotConfig(; OP..., window=W, tree=t, name="dot_mxfp8_w$(wname(W))_$(t)")
           for t in trees for W in windows]
n = length(designs)

# 1. accuracy: same quantized data for every design point
println("== accuracy on $NBLOCKS quantized blocks per distribution")
data = Dict(d => sample_blocks(designs[1], NBLOCKS; dist=d, seed=42) for d in (:gaussian, :outliers))
acc = Dict{Tuple{Int,Symbol},AccuracyStats}()
lk = ReentrantLock()
Threads.@threads for k in 1:2n
    i, d = (k - 1) % n + 1, k <= n ? :gaussian : :outliers
    s = accuracy(designs[i], data[d])
    lock(() -> acc[(i, d)] = s, lk)
end

# 2. synthesis, cached by module name
cache_path = joinpath(RESULTS, "pareto_mxfp8_dot_synth.csv")
cache = Dict{String,NTuple{3,Float64}}()
if isfile(cache_path)
    for l in readlines(cache_path)[2:end]
        f = split(l, ","); cache[f[1]] = (parse(Float64, f[2]), parse(Float64, f[3]), parse(Float64, f[4]))
    end
end
todo = [i for i in 1:n if !haskey(cache, designs[i].name)]
println("== synthesis: $(n - length(todo)) cached, $(length(todo)) to run on $(Threads.nthreads()) threads")
Threads.@threads for i in todo
    s = synth_dot(designs[i]; pdk=PDK)
    lock(lk) do
        cache[designs[i].name] = (s.area_um2, s.delay_ps, s.cells)
        open(cache_path, "w") do io
            println(io, "module,area_um2,delay_ps,cells")
            for (k, v) in sort(collect(cache))
                println(io, join((k, v...), ","))
            end
        end
    end
    println("  synthesized ", designs[i].name)
end

area = [cache[d.name][1] for d in designs]
delay = [cache[d.name][2] for d in designs]
err = [acc[(i, :outliers)].mean for i in 1:n]
errg = [acc[(i, :gaussian)].mean for i in 1:n]
errmax = [acc[(i, :outliers)].max for i in 1:n]
agree = [acc[(i, :outliers)].exact_frac for i in 1:n]

# 3. Pareto fronts
obj2 = hcat(area, err)              # cost vs accuracy
obj3 = hcat(area, delay, err)       # + speed
front2 = Set(pareto_front(obj2))
front3 = Set(pareto_front(obj3))

label(i) = "W=$(wname(designs[i].window)) $(designs[i].tree)"
println()
@printf("%-14s %10s %8s %12s %12s %9s  %-6s %s\n", "design", "area µm²", "ns", "mean err", "max err", "=exact", "front", "dominated by (area, error)")
for i in sortperm(area)
    doms = dominators(obj2, i)
    @printf("%-14s %10.0f %8.2f %12s %12s %8.1f%%  %-6s %s\n", label(i), area[i], delay[i] / 1000,
            @sprintf("2^%.1f", log2(err[i])), @sprintf("2^%.1f", log2(errmax[i])), 100agree[i],
            (i in front2 ? "2D" : "") * (i in front3 ? "3D" : ""),
            isempty(doms) ? "" : join(label.(doms[sortperm(area[doms])][1:min(2, end)]), ", "))
end

# 4. verify every design on the 2D front bit-exactly
if get(ENV, "VERIFY", "1") != "0"
    println("\n== Verilator check of the 2D-front designs")
    for i in sort(collect(front2), by=j -> area[j])
        r = verify_dot(designs[i]; nrand=1500, exhaustive=false, verbose=false)
        println("  ", rpad(label(i), 14), r.errors == 0 ? "bit-exact ($(r.vectors) vectors)" : "FAIL: $(r.errors) mismatches")
    end
end

# 5. write results
out = joinpath(RESULTS, "pareto_mxfp8_dot.csv")
open(out, "w") do io
    println(io, "module,window,tree,area_um2,delay_ps,mean_err_outliers,mean_err_gaussian,max_err_outliers,agree_exact,front_area_err,front_area_delay_err")
    for i in 1:n
        println(io, join((designs[i].name, wname(designs[i].window), designs[i].tree, area[i], delay[i],
                          err[i], errg[i], errmax[i], agree[i], i in front2, i in front3), ","))
    end
end
println("\nwrote ", normpath(out))
plot = joinpath(@__DIR__, "..", "synth", "plot_pareto.py")
Sys.which("python3") !== nothing && isfile(plot) && run(ignorestatus(`python3 $plot $out`))
