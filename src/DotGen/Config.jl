# Config.jl: one dot-product engine design point, plus every width derived from it.

export DotConfig, widths, describe, is_int_only

"""
    DotConfig(; a="mxfp4", b="mxfp8", block=32, acc="fp32", window=nothing,
                rounding=:rne, tree=:csa, stages=2, name=nothing)

One design point of the block dot-product engine

    result = round( 2^(Xa-127) * 2^(Xb-127) * Σ_{i<block} a_i * b_i )

Knobs:
- `a`, `b`: element formats (see [`parse_elem`](@ref)); `mx*` names add an E8M0 shared scale input.
- `block`: number of lanes K summed per result.
- `acc`: output format: `fp32`, `bf16`, `fp16` (rounded once), or `int<N>` (saturating; integer × integer only).
- `window`: `nothing` = exact (Kulisch-style) accumulation, no product is ever rounded. An
  integer `W` aligns every product to the largest product exponent of the block and keeps `W`
  magnitude bits per term (truncating the rest), which narrows the shifters and the compressor tree.
- `rounding`: `:rne` (round to nearest, ties to even) or `:rtz` (toward zero) for the single final rounding.
- `tree`: `:csa` (explicit 3:2 carry-save compressor tree + one carry-propagate adder) or `:adder`
  (balanced tree of binary adders), for comparing the two after synthesis.
- `stages`: pipeline registers. 0 = combinational, 1 = output only, 2 = + after the tree,
  3 = + after the per-lane products.
"""
struct DotConfig
    name::String
    a::ElemFormat
    b::ElemFormat
    scale_a::Bool
    scale_b::Bool
    block::Int
    out::OutFormat
    window::Union{Nothing,Int}
    rounding::Symbol
    tree::Symbol
    stages::Int
end

is_intlike(f::ElemFormat) = f isa IntElem || f isa TernaryElem
is_int_only(c::DotConfig) = is_intlike(c.a) && is_intlike(c.b)

function DotConfig(; a="mxfp4", b="mxfp8", block::Integer=32, acc="fp32", window=nothing,
                   rounding=:rne, tree=:csa, stages::Integer=2, name=nothing)
    fa, sa = a isa ElemFormat ? (a, false) : parse_elem(a)
    fb, sb = b isa ElemFormat ? (b, false) : parse_elem(b)
    out = acc isa OutFormat ? acc : parse_out(acc)
    rounding = Symbol(rounding); tree = Symbol(tree)
    block >= 1 || error("block must be >= 1")
    rounding in (:rne, :rtz) || error("rounding must be :rne or :rtz")
    tree in (:csa, :adder) || error("tree must be :csa or :adder")
    0 <= stages <= 3 || error("stages must be 0..3")
    if out isa IntOut
        (is_intlike(fa) && is_intlike(fb) && !sa && !sb) ||
            error("int<N> output needs integer/ternary elements without MX scales; use fp32/bf16/fp16")
        window === nothing || error("window only applies to float outputs")
    end
    if window !== nothing
        is_int_only_pair = is_intlike(fa) && is_intlike(fb)
        is_int_only_pair && error("window has no effect for integer × integer (no exponents to align); omit it")
        window >= sig_bits(fa) + sig_bits(fb) ||
            error("window must be >= $(sig_bits(fa) + sig_bits(fb)) (product significand width)")
    end
    sfx(f, s) = (s && !startswith(string(f), "mx") ? "mx" : "") * string(f)
    nm = name === nothing ?
        "hwx_dot_$(sfx(fa, sa))_$(sfx(fb, sb))_k$(block)_$(out)" *
        (window === nothing ? "" : "_w$(window)") : String(name)
    return DotConfig(nm, fa, fb, sa, sb, block, out, window, rounding, tree, stages)
end

bitlen(x::Integer) = x == 0 ? 1 : ndigits(x, base=2)
clog2(n::Integer) = n <= 1 ? 0 : ndigits(n - 1, base=2)

"Largest |value| of a format on its own integer grid: max over codes of sig << shift."
function max_mag(f::ElemFormat)
    m = big(0)
    for c in all_codes(f)
        d = decode(f, c)
        (d.nan || d.inf) && continue
        m = max(m, big(d.sig) << d.shift)
    end
    return m
end

"""
    widths(cfg) -> NamedTuple

Every bit width the reference model and the RTL agree on:
`Sa, Sb` significands, `Ha, Hb` shift fields, `Sp` product significand,
`Hp` product shift, `Mw` per-term magnitude, `Ws` signed sum, `Wn` normalizer.
"""
function widths(c::DotConfig)
    Sa, Sb = sig_bits(c.a), sig_bits(c.b)
    Ha, Hb = max_shift(c.a), max_shift(c.b)
    Sp = Sa + Sb
    Hp = Ha + Hb
    maxterm = c.window === nothing ? max_mag(c.a) * max_mag(c.b) : big(2)^c.window - 1
    Mw = bitlen(maxterm)
    Ws = bitlen(c.block * maxterm) + 1
    shw(h) = h == 0 ? 1 : bitlen(h)
    mb = c.out isa FPOut ? c.out.mbits : 0
    Wn = max(Ws, mb + 3)
    return (; Sa, Sb, Ha, Hb, Sp, Hp, HaW=shw(Ha), HbW=shw(Hb), HpW=shw(Hp), Mw, Ws, Wn,
              lsb=lsb_exp(c.a) + lsb_exp(c.b))
end

function describe(c::DotConfig)
    w = widths(c)
    io = IOBuffer()
    println(io, "design      $(c.name)")
    println(io, "operation   result = round(", c.scale_a ? "2^(Xa-127)·" : "",
            c.scale_b ? "2^(Xb-127)·" : "", "Σ_{i<$(c.block)} a_i·b_i) → $(c.out)")
    println(io, "elements    a: $(c.a) ($(nbits(c.a))b$(c.scale_a ? " + E8M0 scale" : ""))   ",
            "b: $(c.b) ($(nbits(c.b))b$(c.scale_b ? " + E8M0 scale" : ""))")
    mul = c.a isa TernaryElem || c.b isa TernaryElem ? "select/negate (no multiplier)" :
          is_int_only(c) ? "$(nbits(c.a))×$(nbits(c.b)) signed multiplier" :
          "$(w.Sa)×$(w.Sb) significand multiplier"
    println(io, "per lane    ", mul)
    println(io, "alignment   ", c.window === nothing ?
        "exact (Kulisch): every product on one fixed-point grid, $(w.Mw) magnitude bits" :
        "window: align to block max exponent, keep $(c.window) bits/term (truncate)")
    println(io, "reduction   $(c.block) terms × $(w.Ws)b, ",
            c.tree == :csa ? "3:2 carry-save tree + 1 CPA" : "binary adder tree")
    println(io, "output      ", c.out isa FPOut ?
        "single normalize + round ($(c.rounding)) to $(c.out)" : "saturate to $(c.out)")
    print(io,   "pipeline    $(c.stages) register stage(s), latency $(c.stages) cycle(s), 1 result/cycle")
    return String(take!(io))
end
