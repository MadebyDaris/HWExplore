# tests/test_dotgen.jl
#
# DotGen: number formats, the bit-exact reference model (checked against an
# independent exact-rational oracle), RTL structure, and, when Verilator is on
# PATH, bit-exact simulation of a few small engines.
# Run with: julia --project=. tests/test_dotgen.jl

using Test, Random
include(joinpath(@__DIR__, "..", "src", "DotGen", "DotGen.jl"))
using .DotGen

const ALL_ELEMS = ["fp4", "fp6e2m3", "fp6e3m2", "fp8e4m3", "fp8e5m2", "int8", "int4", "int2", "ternary", "mxint8"]

@testset "DotGen" begin

@testset "formats: decode agrees with exact values for every code" begin
    for n in ALL_ELEMS
        f, _ = parse_elem(n)
        bad = 0
        for c in all_codes(f)
            d, v = decode(f, c), elem_value(f, c)
            if d.nan
                bad += !(v isa Float64 && isnan(v))
            elseif d.inf
                bad += !(v isa Float64 && isinf(v) && (v < 0) == d.neg)
            else
                bad += (d.neg ? -1 : 1) * d.sig * DotGen.pow2(d.shift + lsb_exp(f)) != v
            end
        end
        @test bad == 0
    end
    fp4 = parse_elem("fp4")[1]
    @test [Float64(elem_value(fp4, c)) for c in 0:7] == [0, 0.5, 1, 1.5, 2, 3, 4, 6]
    @test Float64(elem_value(parse_elem("fp8e4m3")[1], 0x7e)) == 448        # E4M3 max
    @test isnan(elem_value(parse_elem("fp8e4m3")[1], 0x7f))                 # E4M3's only NaN
    @test Float64(elem_value(parse_elem("fp8e5m2")[1], 0x7b)) == 57344      # E5M2 max
    @test Float64(elem_value(parse_elem("mxint8")[1], 0x80)) == -2.0
    @test parse_elem("mxfp4")[2] && !parse_elem("fp4")[2]
    @test_throws ErrorException parse_elem("fp5")
end

@testset "round_fp: subnormals, overflow, ties" begin
    fp32 = parse_out("fp32")
    @test round_fp(1, -149, fp32, :rne) == 0x00000001                 # min subnormal
    @test round_fp(1, -150, fp32, :rne) == 0x00000000                 # exactly half of min → even (0)
    @test round_fp(3, -151, fp32, :rne) == 0x00000001                 # 0.75 ulp → 1
    @test round_fp(3, -150, fp32, :rne) == 0x00000002                 # 1.5 ulp → 2 (even)
    @test round_fp((big(1) << 24) - 1, -150, fp32, :rne) == 0x00800000   # subnormal rounds up to min normal
    @test round_fp(1, 128, fp32, :rne) == 0x7f800000                  # overflow → Inf
    @test round_fp(1, 128, fp32, :rtz) == 0x7f7fffff                  # overflow → max finite
    @test round_fp(-1, 0, fp32, :rne) == 0xbf800000
    @test round_fp((1 << 25) + 3, 0, fp32, :rne) == reinterpret(UInt32, Float32((1 << 25) + 3))
    @test round_fp(0, 0, fp32, :rne) == 0
end

@testset "reference model == oracle: exhaustive single products" begin
    # an FP4×FP4 product has only 256 cases; sweep every pair at several scale pairs
    for (a, b) in [("mxfp4", "mxfp4"), ("mxfp4", "mxfp8"), ("mxfp6e3m2", "mxfp8e5m2"), ("int4", "int8")]
        acc = startswith(a, "int") ? "int32" : "fp32"
        c = DotConfig(; a, b, block=1, acc)
        scales = c.scale_a ? [(127, 127), (0, 0), (254, 254), (1, 100), (255, 127)] : [(127, 127)]
        bad = 0
        for ca in all_codes(c.a), cb in all_codes(c.b), (xa, xb) in scales
            bad += dot_ref(c, [ca], [cb], xa, xb) != dot_oracle(c, [ca], [cb], xa, xb)
        end
        @test bad == 0
    end
end

@testset "reference model == oracle: random blocks" begin
    rng = Xoshiro(7)
    for kw in [(a="mxfp4", b="mxfp8", acc="fp32"), (a="mxfp8e5m2", b="mxfp8", acc="bf16"),
               (a="mxfp6e2m3", b="mxint8", acc="fp16"), (a="ternary", b="mxfp8", acc="fp32"),
               (a="int8", b="int8", acc="int16"), (a="ternary", b="int4", acc="int8")],
        rnd in (:rne, :rtz)
        c = DotConfig(; block=32, rounding=rnd, kw...)
        bad = 0
        for v in DotGen.gen_vectors(c; nrand=300, exhaustive=false, seed=rand(rng, 1:10^6))
            bad += dot_oracle(c, v.a, v.b, v.xa, v.xb) != v.exp
        end
        @test bad == 0
    end
end

@testset "window: wide enough == exact; narrow only truncates" begin
    for (a, b) in [("mxfp4", "mxfp8"), ("mxfp8", "mxfp8e5m2")]
        ex = DotConfig(; a, b, block=16)
        w = DotGen.widths(ex)
        wide = DotConfig(; a, b, block=16, window=w.Sp + w.Hp)
        bad = 0
        for v in DotGen.gen_vectors(ex; nrand=300, exhaustive=false)
            bad += dot_ref(wide, v.a, v.b, v.xa, v.xb) != v.exp
        end
        @test bad == 0
    end
    # all-positive terms: truncating each term can only lose magnitude
    c, cw = DotConfig(a="fp4", b="fp8", block=8), DotConfig(a="fp4", b="fp8", block=8, window=8)
    rng = Xoshiro(3)
    bad = 0
    for _ in 1:500
        a, b = rand(rng, 0:7, 8), rand(rng, 0:0x7e, 8)
        bad += reinterpret(Float32, UInt32(dot_ref(cw, a, b))) > reinterpret(Float32, UInt32(dot_ref(c, a, b)))
    end
    @test bad == 0
end

@testset "config validation and naming" begin
    @test_throws ErrorException DotConfig(a="mxfp4", b="mxfp8", acc="int32")
    @test_throws ErrorException DotConfig(a="int8", b="int8", window=16)
    @test_throws ErrorException DotConfig(a="fp4", b="fp8", window=4)
    @test_throws ErrorException DotConfig(stages=4)
    @test DotConfig(a="mxfp4", b="mxfp8").name == "hwx_dot_mxfp4_mxfp8e4m3_k32_fp32"
    @test DotConfig(a="mxint8", b="mxfp4").name == "hwx_dot_mxint8_mxfp4_k32_fp32"
end

@testset "RTL structure" begin
    sv = emit_dot_string(DotConfig(a="mxfp4", b="mxfp8", block=32))
    @test occursin("module hwx_dot_mxfp4_mxfp8e4m3_k32_fp32 (", sv)
    @test occursin("input  logic [127:0] a_i", sv) && occursin("input  logic [255:0] b_i", sv)
    @test occursin("xa_i", sv) && occursin("xb_i", sv)
    @test count("tree_sum = ", sv) == 1                                # exactly one carry-propagate adder
    @test length(collect(eachmatch(r"assign csa\d+_s ", sv))) == 31   # 33 operands → 31 compressors
    @test occursin("negcnt", sv)                                      # ~x + popcount, no per-lane negate
    # ternary lanes have no multiplier
    t = emit_dot_string(DotConfig(a="ternary", b="int8", acc="int32"))
    @test !occursin(r"\$signed\(a_c\) \*", t) && occursin("no multiplier", t)
    t2 = emit_dot_string(DotConfig(a="ternary", b="mxfp8"))
    lane = t2[findfirst("g_lane", t2).start:findnext("\n  end\n", t2, findfirst("g_lane", t2).start).start]
    @test !occursin(" * ", lane)
    # tree and pipeline options
    @test !occursin("csa0", emit_dot_string(DotConfig(tree=:adder)))
    @test !occursin("always_ff", emit_dot_string(DotConfig(stages=0)))
    @test count("always_ff", emit_dot_string(DotConfig(stages=3))) == 4  # terms, sum, out, valid
end

@testset "exploration: MX quantization, accuracy, Pareto" begin
    fp8 = parse_elem("fp8e4m3")[1]
    codes, X = quantize_mx([448.0, 1.0, -3.0, 0.0], fp8)
    @test X == 127                                     # max 448 → floor(log2)=8 = emax_elem → 2^0
    @test [Float64(elem_value(fp8, c)) for c in codes] == [448, 1, -3, 0]
    codes, X = quantize_mx([1000.0, 0.001], fp8)
    @test X == 128 && Float64(elem_value(fp8, codes[1])) == 448   # 1000/2 = 500 saturates to 448
    # out_value must accept the UInt64 codes dot_ref returns (regression)
    @test out_value(parse_out("fp32"), UInt64(0x3f800000)) == 1
    c = DotConfig(a="mxfp8", b="mxfp8", block=32)
    blocks = sample_blocks(c, 200; dist=:outliers)
    ex = accuracy(c, blocks)
    @test ex.exact_frac == 1 && ex.max <= 2.0^-24       # one FP32 rounding of the exact sum
    narrow = accuracy(DotConfig(a="mxfp8", b="mxfp8", block=32, window=10), blocks)
    @test narrow.mean > ex.mean && narrow.exact_frac < 0.1
    objs = [1 5; 2 3; 3 3; 4 1; 2.5 4]
    @test pareto_front(objs) == [1, 2, 4]
    @test dominators(objs, 3) == [2] && Set(dominators(objs, 5)) == Set([2])
end

if Sys.which("verilator") !== nothing
    @testset "Verilator: bit-exact against the reference model" begin
        for kw in [(a="mxfp4", b="mxfp4", block=4, stages=0),
                   (a="mxfp4", b="mxfp8e5m2", block=8, acc="bf16", stages=3, window=12),
                   (a="ternary", b="int8", block=16, acc="int16", stages=1)]
            r = verify_dot(DotConfig(; kw...); nrand=500, verbose=false)
            @test r.errors == 0
            @test r.vectors >= 500
        end
    end
else
    @info "verilator not on PATH; skipping simulation tests"
end

end
