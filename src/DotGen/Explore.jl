# Explore.jl: accuracy measurement on realistic data, and Pareto-front extraction.
#
# Accuracy is the third axis of the design space (next to area and delay): the same
# operation built with a narrower accumulator is smaller, but how much worse are its
# answers? Here "worse" is measured against the exact dot product of the *quantized*
# inputs, so the error isolates what the hardware adds on top of quantization (which is
# identical for every design point of a given format pair).

export quantize_mx, sample_blocks, accuracy, AccuracyStats, pareto_front, dominators

"Largest finite magnitude of an element format and its exponent (emax_elem in the OCP spec)."
function elem_max(f::ElemFormat)
    m = maximum(abs(Float64(elem_value(f, c))) for c in all_codes(f) if (d = decode(f, c); !d.nan && !d.inf))
    return m, floor(Int, log2(m))
end

# Non-negative finite values of a format with one code each (+0 preferred), sorted by value.
function positive_table(f::ElemFormat)
    seen = Dict{Float64,Int}()
    for c in all_codes(f)
        d = decode(f, c)
        (d.nan || d.inf || d.neg) && continue
        v = Float64(elem_value(f, c))
        (!haskey(seen, v) || c < seen[v]) && (seen[v] = c)
    end
    vals = sort!(collect(keys(seen)))
    return vals, [seen[v] for v in vals]
end

"Round a real value to the nearest element code (ties to the even code), saturating at max."
function quantize_elem(x::Float64, vals, codes, f::ElemFormat)
    ax = abs(x)
    i = searchsortedlast(vals, ax)
    c = if i == 0
        codes[1]
    elseif i == length(vals)
        codes[end]                                   # saturate
    else
        lo, hi = vals[i], vals[i+1]
        d1, d2 = ax - lo, hi - ax
        d1 < d2 ? codes[i] : d2 < d1 ? codes[i+1] : (iseven(codes[i]) ? codes[i] : codes[i+1])
    end
    return x < 0 && c != codes[1] ? neg_code(f, c) : c
end

"""
    quantize_mx(x, f) -> (codes, scale_code)

Quantize one block of reals to an MX block as in OCP MX v1.0 §6.3: the shared scale is
`2^(floor(log2(max|x|)) - emax_elem)`, elements are rounded to nearest-even and saturated.
"""
function quantize_mx(x::AbstractVector{<:Real}, f::ElemFormat; table=positive_table(f))
    vals, codes = table
    _, emax = elem_max(f)
    amax = maximum(abs, x)
    amax == 0 && return (fill(codes[1], length(x)), 127)
    X = clamp(floor(Int, log2(amax)) - emax, -127, 127)
    s = 2.0^X
    return ([quantize_elem(Float64(v) / s, vals, codes, f) for v in x], X + 127)
end

"""
    sample_blocks(cfg, n; dist=:outliers, seed=1) -> Vector of (a, b, xa, xb)

Random real-valued blocks, quantized to `cfg`'s formats. `dist`:
- `:gaussian`: activations and weights both N(0, 1)
- `:outliers`: N(0, 1) activations where 2% of entries are ×30 (the outlier channels typical
  of transformer activations), N(0, 1) weights. One outlier sets the block scale, so the small
  products are where a narrow accumulator loses bits.
"""
function sample_blocks(c::DotConfig, n::Int; dist::Symbol=:outliers, seed::Int=1)
    rng = Xoshiro(seed)
    ta, tb = positive_table(c.a), positive_table(c.b)
    K = c.block
    out = Vector{Tuple{Vector{Int},Vector{Int},Int,Int}}(undef, n)
    for t in 1:n
        av = randn(rng, K); bv = randn(rng, K)
        if dist == :outliers
            for i in 1:K
                rand(rng) < 0.02 && (av[i] *= 30)
            end
        end
        a, xa = quantize_mx(av, c.a; table=ta)
        b, xb = quantize_mx(bv, c.b; table=tb)
        out[t] = (a, b, c.scale_a ? xa : 127, c.scale_b ? xb : 127)
    end
    return out
end

struct AccuracyStats
    mean::Float64     # of the normalized error (average case)
    median::Float64
    p99::Float64
    max::Float64
    exact_frac::Float64   # fraction of blocks where the result equals round(exact)
end

"""
    accuracy(cfg, blocks) -> AccuracyStats

Normalized error of `cfg`'s bit-exact output against the exact dot product of the same
quantized inputs: `|hw − exact| / Σ|a_i·b_i|`. Dividing by Σ|a_i·b_i| (not |exact|) keeps the
metric meaningful under cancellation; any correctly rounded FP32 result scores ≤ 2^-24.
"""
function accuracy(c::DotConfig, blocks)
    c.out isa FPOut || error("accuracy() needs a float output format")
    exact_cfg = DotConfig(c.name * "_exact", c.a, c.b, c.scale_a, c.scale_b, c.block, c.out, nothing,
                          c.rounding, c.tree, c.stages)
    errs = Float64[]
    nexact = 0
    for (a, b, xa, xb) in blocks
        sp, S, E = dot_terms(exact_cfg, a, b, xa, xb)
        sp == :none || continue
        exact = BigFloat(S) * BigFloat(2)^E
        mag = sum(abs(Float64(elem_value(c.a, a[i])) * Float64(elem_value(c.b, b[i]))) for i in 1:c.block)
        mag *= (c.scale_a ? 2.0^(xa - 127) : 1.0) * (c.scale_b ? 2.0^(xb - 127) : 1.0)
        mag == 0 && continue
        hw = out_float(c.out, dot_ref(c, a, b, xa, xb))
        nexact += dot_ref(c, a, b, xa, xb) == dot_ref(exact_cfg, a, b, xa, xb)
        push!(errs, Float64(abs(BigFloat(hw) - exact)) / mag)
    end
    sort!(errs)
    q(p) = errs[clamp(ceil(Int, p * length(errs)), 1, length(errs))]
    return AccuracyStats(sum(errs) / length(errs), q(0.5), q(0.99), errs[end], nexact / length(errs))
end

"Output code → Float64 (exact for fp32/bf16/fp16)."
function out_float(o::FPOut, code::Integer)
    v = out_value(o, code)
    return v isa Float64 ? v : Float64(v)
end

"""
    pareto_front(objs) -> Vector{Int}

Row indices of the non-dominated points of `objs` (rows = design points, columns =
objectives, all minimized). Point `j` dominates `i` when it is no worse in every objective
and strictly better in at least one.
"""
function pareto_front(objs::AbstractMatrix)
    n = size(objs, 1)
    return [i for i in 1:n if isempty(dominators(objs, i))]
end

"Indices of the points that dominate point `i`."
dominators(objs::AbstractMatrix, i::Int) =
    [j for j in axes(objs, 1) if j != i && all(objs[j, :] .<= objs[i, :]) && any(objs[j, :] .< objs[i, :])]
