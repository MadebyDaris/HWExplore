# Formats.jl: element, scale and output number formats for the dot-product generator.
#
# Every element format decodes to the same small integer form:
#
#     value = (-1)^neg * sig * 2^(shift + lsb_exp(f))
#
# where `sig` is an unsigned significand (implicit bit included), `shift` is a
# small unsigned exponent offset (0 for integers), and `lsb_exp(f)` is a
# per-format constant. A product of two elements is then
#
#     (-1)^(na⊻nb) * (sig_a*sig_b) * 2^(shift_a+shift_b) * 2^(lsb_a+lsb_b)
#
# so every product of a block lives on one fixed-point grid with LSB weight
# 2^(lsb_a+lsb_b). That is what lets the engine align all products once, sum
# them in one compressor tree and normalize once.

export ElemFormat, FPElem, IntElem, TernaryElem, OutFormat, FPOut, IntOut
export Decoded, decode, nbits, sig_bits, max_shift, lsb_exp, elem_value, all_codes
export parse_elem, parse_out, FORMAT_NAMES

abstract type ElemFormat end

"""
    FPElem(name, ebits, mbits, bias, specials)

Minifloat element. `specials` is one of
- `:none`: every encoding is finite (OCP FP4 E2M1, FP6 E2M3/E3M2)
- `:e4m3`: only `S.1111.111` is NaN, no infinities (OCP FP8 E4M3)
- `:ieee`: max exponent field encodes Inf (mantissa 0) / NaN (OCP FP8 E5M2)
"""
struct FPElem <: ElemFormat
    name::String
    ebits::Int
    mbits::Int
    bias::Int
    specials::Symbol
end

"""
    IntElem(name, bits, frac)

Two's-complement integer element with an implicit scale of `2^-frac`
(`frac = 6` for OCP MXINT8, `0` for plain integers). The most negative code is
kept as-is (e.g. MXINT8 0x80 = -2.0), not mapped to the symmetric range.
"""
struct IntElem <: ElemFormat
    name::String
    bits::Int
    frac::Int
end

"""
    TernaryElem()

2-bit ternary weight: `00` = 0, `01` = +1, `11` = -1, `10` = 0 (reserved).
Products with a ternary operand are a select/negate, never a multiplier.
"""
struct TernaryElem <: ElemFormat end

Base.show(io::IO, f::FPElem) = print(io, f.name)
Base.show(io::IO, f::IntElem) = print(io, f.name)
Base.show(io::IO, ::TernaryElem) = print(io, "ternary")

"Decoded element: the integer form plus special-value flags."
struct Decoded
    nan::Bool
    inf::Bool
    neg::Bool
    sig::Int
    shift::Int
end

nbits(f::FPElem) = 1 + f.ebits + f.mbits
nbits(f::IntElem) = f.bits
nbits(::TernaryElem) = 2

"Width of the unsigned significand (implicit bit included)."
sig_bits(f::FPElem) = f.mbits + 1
sig_bits(f::IntElem) = f.bits          # |-2^(b-1)| = 2^(b-1) needs b bits
sig_bits(::TernaryElem) = 1

"Largest `shift` any finite encoding can produce."
function max_shift(f::FPElem)
    emax_field = (1 << f.ebits) - 1
    f.specials == :ieee && (emax_field -= 1)  # all-ones exponent is Inf/NaN only
    return emax_field - 1                      # subnormal and e=1 share shift 0
end
max_shift(::IntElem) = 0
max_shift(::TernaryElem) = 0

"Exponent of the significand LSB at `shift == 0`."
lsb_exp(f::FPElem) = 1 - f.bias - f.mbits
lsb_exp(f::IntElem) = -f.frac
lsb_exp(::TernaryElem) = 0

"Exact 2^e as a Rational{BigInt} (negative e allowed)."
pow2(e::Integer) = e >= 0 ? big(2)^e // big(1) : big(1) // big(2)^(-e)

has_specials(f::ElemFormat) = f isa FPElem && f.specials != :none

all_codes(f::ElemFormat) = 0:(1<<nbits(f))-1

function decode(f::FPElem, code::Integer)
    m = f.mbits; e = f.ebits
    s = (code >> (e + m)) & 1 == 1
    ef = (code >> m) & ((1 << e) - 1)
    mf = code & ((1 << m) - 1)
    allones_e = ef == (1 << e) - 1
    if f.specials == :ieee && allones_e
        return mf == 0 ? Decoded(false, true, s, 0, 0) : Decoded(true, false, s, 0, 0)
    elseif f.specials == :e4m3 && allones_e && mf == (1 << m) - 1
        return Decoded(true, false, s, 0, 0)
    end
    sig = ef == 0 ? mf : (mf | (1 << m))
    shift = ef == 0 ? 0 : ef - 1
    return Decoded(false, false, s, sig, shift)
end

function decode(f::IntElem, code::Integer)
    v = code & ((1 << f.bits) - 1)
    v >= 1 << (f.bits - 1) && (v -= 1 << f.bits)
    return Decoded(false, false, v < 0, abs(v), 0)
end

function decode(::TernaryElem, code::Integer)
    c = code & 3
    c == 0b01 && return Decoded(false, false, false, 1, 0)
    c == 0b11 && return Decoded(false, false, true, 1, 0)
    return Decoded(false, false, false, 0, 0)
end

"""
    elem_value(f, code) -> Rational{BigInt} | ±Inf | NaN

Exact value of an element encoding, written independently of the integer form
above so the tests can cross-check `decode`.
"""
function elem_value(f::FPElem, code::Integer)
    m = f.mbits; e = f.ebits
    s = (code >> (e + m)) & 1
    ef = (code >> m) & ((1 << e) - 1)
    mf = code & ((1 << m) - 1)
    if f.specials == :ieee && ef == (1 << e) - 1
        return mf == 0 ? (s == 1 ? -Inf : Inf) : NaN
    elseif f.specials == :e4m3 && ef == (1 << e) - 1 && mf == (1 << m) - 1
        return NaN
    end
    mag = ef == 0 ? big(mf) // big(2)^m * pow2(1 - f.bias) :
                    (1 + big(mf) // big(2)^m) * pow2(ef - f.bias)
    return s == 1 ? -mag : mag
end
function elem_value(f::IntElem, code::Integer)
    v = code & ((1 << f.bits) - 1)
    v >= 1 << (f.bits - 1) && (v -= 1 << f.bits)
    return big(v) // big(2)^f.frac
end
elem_value(::TernaryElem, code::Integer) = Dict(0 => 0, 1 => 1, 2 => 0, 3 => -1)[code&3] // big(1)

# Output formats

abstract type OutFormat end

"IEEE-style binary float output: FP32 (8,23), BF16 (8,7), FP16 (5,10)."
struct FPOut <: OutFormat
    name::String
    ebits::Int
    mbits::Int
end
"Saturating two's-complement integer output (integer × integer configs only)."
struct IntOut <: OutFormat
    name::String
    bits::Int
end
Base.show(io::IO, f::OutFormat) = print(io, f.name)
nbits(f::FPOut) = 1 + f.ebits + f.mbits
nbits(f::IntOut) = f.bits
bias(f::FPOut) = (1 << (f.ebits - 1)) - 1

# Name parsing

const ELEM_TABLE = Dict{String,ElemFormat}(
    "fp4"     => FPElem("fp4", 2, 1, 1, :none),        # E2M1
    "fp4e2m1" => FPElem("fp4", 2, 1, 1, :none),
    "fp6e2m3" => FPElem("fp6e2m3", 2, 3, 1, :none),
    "fp6e3m2" => FPElem("fp6e3m2", 3, 2, 3, :none),
    "fp6"     => FPElem("fp6e2m3", 2, 3, 1, :none),
    "fp8e4m3" => FPElem("fp8e4m3", 4, 3, 7, :e4m3),
    "fp8e5m2" => FPElem("fp8e5m2", 5, 2, 15, :ieee),
    "fp8"     => FPElem("fp8e4m3", 4, 3, 7, :e4m3),
    "int8"    => IntElem("int8", 8, 0),
    "int4"    => IntElem("int4", 4, 0),
    "int2"    => IntElem("int2", 2, 0),
    "ternary" => TernaryElem(),
)

const FORMAT_NAMES = sort!(vcat(collect(keys(ELEM_TABLE)),
    ["mx" * k for k in keys(ELEM_TABLE) if startswith(k, "fp")], ["mxint8"]))

"""
    parse_elem(name) -> (format, has_scale::Bool)

`mx`-prefixed names carry an E8M0 shared block scale (OCP MX v1.0):
`mxfp4`, `mxfp6e2m3`, `mxfp6e3m2`, `mxfp8` (= E4M3), `mxfp8e5m2`, `mxint8`.
Bare names (`fp4`, `int4`, `ternary`, ...) have no scale.
"""
function parse_elem(name::AbstractString)
    n = lowercase(name)
    n == "mxint8" && return (IntElem("mxint8", 8, 6), true)
    if startswith(n, "mx")
        base = n[3:end]
        haskey(ELEM_TABLE, base) && ELEM_TABLE[base] isa FPElem && return (ELEM_TABLE[base], true)
    elseif haskey(ELEM_TABLE, n)
        return (ELEM_TABLE[n], false)
    end
    error("unknown element format '$name'; known: $(join(FORMAT_NAMES, ", "))")
end

function parse_out(name::AbstractString)
    n = lowercase(name)
    n == "fp32" && return FPOut("fp32", 8, 23)
    n == "bf16" && return FPOut("bf16", 8, 7)
    n == "fp16" && return FPOut("fp16", 5, 10)
    m = match(r"^int(\d+)$", n)
    m !== nothing && return IntOut(n, parse(Int, m[1]))
    error("unknown accumulator/output format '$name'; known: fp32, bf16, fp16, int<N>")
end
