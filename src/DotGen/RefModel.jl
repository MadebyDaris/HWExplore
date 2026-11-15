# RefModel.jl: bit-exact reference model of the generated dot-product engine.
#
# `dot_ref` mirrors the hardware algorithm step by step (integer terms →
# one exact sum → one rounding), using BigInt so nothing here can overflow.
# `dot_oracle` computes the same thing a completely different way (exact
# rationals + binary search over output codes) and is used to check the
# reference model itself.

export dot_ref, dot_terms, dot_oracle, round_fp, out_value, pack_lanes, unpack_lanes

pack_lanes(codes, w::Int) = foldl((acc, (i, c)) -> acc | (big(c) << ((i - 1) * w)),
                                  enumerate(codes); init=big(0))
unpack_lanes(x::Integer, w::Int, k::Int) = [Int((big(x) >> ((i - 1) * w)) & ((1 << w) - 1)) for i in 1:k]

"""
    dot_terms(cfg, a, b, xa, xb) -> (special, S, E)

The exact intermediate the hardware computes: `special ∈ (:none, :nan, :pinf, :ninf)`
and, when finite, the signed integer sum `S` with LSB weight `2^E`.
"""
function dot_terms(c::DotConfig, a::AbstractVector, b::AbstractVector, xa::Integer=127, xb::Integer=127)
    length(a) == c.block == length(b) || error("expected $(c.block) lanes")
    w = widths(c)
    nan = (c.scale_a && xa == 0xFF) || (c.scale_b && xb == 0xFF)
    pinf = ninf = false
    neg = falses(c.block); psig = zeros(Int, c.block); psh = zeros(Int, c.block)
    for i in 1:c.block
        da, db = decode(c.a, a[i]), decode(c.b, b[i])
        zero_a = !da.nan && !da.inf && da.sig == 0
        zero_b = !db.nan && !db.inf && db.sig == 0
        if da.nan || db.nan || (da.inf && zero_b) || (db.inf && zero_a)
            nan = true
        elseif da.inf || db.inf
            (da.neg ⊻ db.neg) ? (ninf = true) : (pinf = true)
        else
            neg[i] = da.neg ⊻ db.neg
            psig[i] = da.sig * db.sig
            psh[i] = psig[i] == 0 ? 0 : da.shift + db.shift   # zero products never set the block max
        end
    end
    (nan || (pinf && ninf)) && return (:nan, big(0), 0)
    pinf && return (:pinf, big(0), 0)
    ninf && return (:ninf, big(0), 0)

    E = w.lsb + (c.scale_a ? xa - 127 : 0) + (c.scale_b ? xb - 127 : 0)
    S = big(0)
    if c.window === nothing
        for i in 1:c.block
            t = big(psig[i]) << psh[i]
            S += neg[i] ? -t : t
        end
    else
        W = c.window
        emax = maximum(psh)
        for i in 1:c.block
            t = (big(psig[i]) << (W - w.Sp)) >> (emax - psh[i])   # floor: truncate magnitude
            S += neg[i] ? -t : t
        end
        E += emax + w.Sp - W
    end
    return (:none, S, E)
end

"""
    round_fp(S, E, out, mode) -> UInt64

Round the exact value `S * 2^E` to the float format `out` once, with
`mode ∈ (:rne, :rtz)`. Handles subnormal results and overflow (RNE → ±Inf,
RTZ → ±max finite). An exact zero returns +0.
"""
function round_fp(S::Integer, E::Integer, out::FPOut, mode::Symbol)
    eb, mb = out.ebits, out.mbits
    S == 0 && return UInt64(0)
    sgn = UInt64(S < 0)
    m = abs(big(S))
    B = bias(out); emin = 1 - B
    e_msb = ndigits(m, base=2) - 1 + E
    q = max(e_msb - mb, emin - mb)
    sh = q - E
    if sh <= 0
        M = m << -sh
    else
        M = m >> sh
        rem = m - (M << sh)
        half = big(1) << (sh - 1)
        mode == :rne && (rem > half || (rem == half && isodd(M))) && (M += 1)
    end
    if M == big(2)^(mb + 1)
        M >>= 1; q += 1
    end
    expf = M < big(2)^mb ? 0 : q + mb + B
    emaxf = (1 << eb) - 1
    if expf >= emaxf
        mag = mode == :rne ? UInt64(emaxf) << mb : (UInt64(emaxf - 1) << mb) | ((UInt64(1) << mb) - 1)
        return (sgn << (eb + mb)) | mag
    end
    mant = UInt64(M & (big(2)^mb - 1))
    return (sgn << (eb + mb)) | (UInt64(expf) << mb) | mant
end

canonical_nan(out::FPOut) = (UInt64((1 << out.ebits) - 1) << out.mbits) | (UInt64(1) << (out.mbits - 1))
inf_code(out::FPOut, neg::Bool) = (UInt64(neg) << (out.ebits + out.mbits)) | (UInt64((1 << out.ebits) - 1) << out.mbits)

"""
    dot_ref(cfg, a, b, xa=127, xb=127) -> UInt64

Bit-exact output code of the generated engine for lane codes `a`, `b` and
E8M0 scale codes `xa`, `xb` (ignored when the format has no scale).
"""
function dot_ref(c::DotConfig, a::AbstractVector, b::AbstractVector, xa::Integer=127, xb::Integer=127)
    sp, S, E = dot_terms(c, a, b, xa, xb)
    if c.out isa IntOut
        lo, hi = -big(2)^(c.out.bits - 1), big(2)^(c.out.bits - 1) - 1
        v = clamp(S, lo, hi)
        return UInt64(v < 0 ? v + big(2)^c.out.bits : v)
    end
    sp == :nan && return canonical_nan(c.out)
    sp == :pinf && return inf_code(c.out, false)
    sp == :ninf && return inf_code(c.out, true)
    return round_fp(S, E, c.out, c.rounding)
end

# Independent oracle

"Exact value of an output float code (finite codes only)."
function out_value(out::FPOut, code::Integer)
    code = Int(code)                     # signed: exponent arithmetic below goes negative
    eb, mb = out.ebits, out.mbits
    s = (code >> (eb + mb)) & 1
    ef = (code >> mb) & ((1 << eb) - 1)
    mf = code & ((1 << mb) - 1)
    ef == (1 << eb) - 1 && return mf == 0 ? (s == 1 ? -Inf : Inf) : NaN
    B = bias(out)
    mag = ef == 0 ? big(mf) // big(2)^mb * pow2(1 - B) :
                    (1 + big(mf) // big(2)^mb) * pow2(ef - B)
    return s == 1 ? -mag : mag
end

# RNE/RTZ rounding of an exact rational by binary search over positive codes.
function oracle_round(r::Rational{BigInt}, out::FPOut, mode::Symbol)
    r == 0 && return UInt64(0)
    sgn = UInt64(r < 0) << (out.ebits + out.mbits)
    x = abs(r)
    maxcode = ((1 << out.ebits) - 1) << out.mbits - 1          # largest finite
    maxval = out_value(out, maxcode)
    if x >= maxval
        mode == :rtz && return sgn | UInt64(maxcode)
        # ulp at the top binade; halfway between max and the next (non-representable) step
        ulp = out_value(out, maxcode) - out_value(out, maxcode - 1)
        return x >= maxval + ulp // 2 ? sgn | UInt64(maxcode + 1) : sgn | UInt64(maxcode)
    end
    lo, hi = 0, maxcode                       # invariant: value(lo) <= x < value(hi)
    while hi - lo > 1
        mid = (lo + hi) >>> 1
        out_value(out, mid) <= x ? (lo = mid) : (hi = mid)
    end
    vlo, vhi = out_value(out, lo), out_value(out, hi)
    vlo == x && return sgn | UInt64(lo)
    mode == :rtz && return sgn | UInt64(lo)
    d1, d2 = x - vlo, vhi - x
    pick = d1 < d2 ? lo : d2 < d1 ? hi : (iseven(lo) ? lo : hi)
    return sgn | UInt64(pick)
end

"""
    dot_oracle(cfg, a, b, xa=127, xb=127) -> UInt64

Exact-arithmetic oracle for `window == nothing` configs: decodes every element
to an exact rational with [`elem_value`](@ref), sums exactly, then rounds by
searching the output code space. Shares no arithmetic with [`dot_ref`](@ref).
"""
function dot_oracle(c::DotConfig, a::AbstractVector, b::AbstractVector, xa::Integer=127, xb::Integer=127)
    c.window === nothing || error("dot_oracle models exact accumulation only")
    nan = (c.scale_a && xa == 0xFF) || (c.scale_b && xb == 0xFF)
    acc = big(0) // big(1); pinf = ninf = false
    for i in 1:c.block
        va, vb = elem_value(c.a, a[i]), elem_value(c.b, b[i])
        if va isa Float64 || vb isa Float64       # NaN or ±Inf involved
            p = Float64(va) * Float64(vb)          # IEEE: Inf*0 = NaN, signs multiply
            isnan(p) ? (nan = true) : p > 0 ? (pinf = true) : (ninf = true)
        else
            acc += va * vb
        end
    end
    if c.out isa IntOut
        v = clamp(acc, -big(2)^(c.out.bits - 1), big(2)^(c.out.bits - 1) - 1)
        @assert denominator(v) == 1
        v = numerator(v)
        return UInt64(v < 0 ? v + big(2)^c.out.bits : v)
    end
    (nan || (pinf && ninf)) && return canonical_nan(c.out)
    pinf && return inf_code(c.out, false)
    ninf && return inf_code(c.out, true)
    scale = (c.scale_a ? pow2(xa - 127) : big(1) // 1) * (c.scale_b ? pow2(xb - 127) : big(1) // 1)
    return oracle_round(acc * scale, c.out, c.rounding)
end
