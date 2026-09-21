# tests/test_hwmacros.jl
#
# @unroll, @tree_reduce, @hwkernel, hw_compile (src/Core/HWMacros.jl).
# Run with: julia --project=. tests/test_hwmacros.jl

using Test
using HWExplore

# Reference loops (CPU semantics) for the unrolled versions to match
function ref_loop(a::Int32, b::Int32, n)
    acc = Int32(0)
    for i in Int32(1):Int32(n)
        acc += a * i + b
    end
    acc
end

function full_unrolled(a::Int32, b::Int32)
    acc = Int32(0)
    @unroll for i in 1:6
        acc += a * i + b
    end
    acc
end
function factor_unrolled(a::Int32, b::Int32)        # 7 iterations, factor 3: 2 passes + remainder 1
    acc = Int32(0)
    @unroll factor=3 for i in 1:7
        acc += a * i + b
    end
    acc
end
function stepped(a::Int32)
    acc = Int32(0)
    @unroll for i in 2:2:8
        acc += a * i
    end
    acc
end

@hwkernel vec=(a=4, b=4) share=(mul=2,) function tdot(a::Int32, b::Int32)
    acc = Int32(0)
    @unroll tree=true for i in 1:4
        acc += a[i] * b[i]
    end
    acc
end

@hwkernel name="named_mac" function mac3(a::Int32, b::Int32, c::Int32)
    a * b + c
end

@testset "HWExplore — hardware macros" begin
    @testset "@unroll: same numeric result as the plain loop" begin
        for (a, b) in ((3, 7), (-4, 9), (100, -1))
            a, b = Int32(a), Int32(b)
            @test full_unrolled(a, b) == ref_loop(a, b, 6)
            @test factor_unrolled(a, b) == ref_loop(a, b, 7)
            @test stepped(a) == a * (2 + 4 + 6 + 8)
        end
    end

    @testset "@unroll: expansion shape" begin
        ex = @macroexpand @unroll for i in 1:3
            acc += x * i
        end
        @test !occursin("for ", string(ex))                       # loop is gone
        @test count(==('*'), string(ex)) == 3                     # three copies of the body
        ex2 = @macroexpand @unroll factor=2 for i in 1:5
            acc += x * i
        end
        @test occursin("while", string(ex2))                      # counted loop remains
        @test_throws Exception (@macroexpand @unroll for i in 1:n
            acc += i
        end)
        @test_throws Exception (@macroexpand @unroll for i in 1:3
            i == 2 && continue
        end)
    end

    @testset "@tree_reduce rebalances chains" begin
        @test string(@macroexpand @tree_reduce a + b + c + d) == "(a + b) + (c + d)"
        @test string(@macroexpand @tree_reduce ((a + b) + c) + d) == "(a + b) + (c + d)"
        @test string(@macroexpand @tree_reduce a * b * c) == "(a * b) * c"
        @test string(@macroexpand @tree_reduce a - b) == "a - b"            # not associative: untouched
        f(a, b, c, d, e) = @tree_reduce a + b + c + d + e
        @test f(1, 2, 3, 4, 5) == 15
    end

    @testset "@hwkernel: vec ports, options, golden model" begin
        cfg = hw_kernel_config(tdot)
        @test cfg !== nothing && cfg.share == Dict(OP_MUL => 2)
        @test cfg.argtypes == Tuple{Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32}
        @test length(methods(tdot)) == 1 && first(methods(tdot)).nargs == 9   # f + 8 scalar ports
        @test tdot(Int32.(1:4)..., Int32.(5:8)...) == 70
        @test hw_kernel_config(mac3).name == "named_mac"
        @test_throws Exception @macroexpand @hwkernel bogus=1 function bad(a::Int32) a end
    end

    @testset "hw_compile: recorded options, overrides, and emitted RTL" begin
        dir = mktempdir()
        r = hw_compile(tdot; outdir = dir)                                     # recorded: mul=2
        @test r.kind == :pipeline && r.share == Dict(OP_MUL => 2) && isfile(r.path)
        sv = read(r.path, String)
        @test occursin("module tdot", sv) && occursin("input  logic [31:0] rs8_i", sv)
        @test count(l -> occursin(r"assign .* = .* \* .*;", l), split(sv, '\n')) == 2

        r1 = hw_compile(tdot; outdir = dir, name = "tdot_m1", share = (mul = 1,))   # override
        @test r1.share == Dict(OP_MUL => 1) && r1.latency > r.latency

        r0 = hw_compile(tdot; outdir = dir, name = "tdot_plain", share = nothing)   # no sharing
        @test !occursin("resource-shared", read(r0.path, String)) && r0.latency <= r.latency

        rm3 = hw_compile(mac3; outdir = dir)                                   # name= from @hwkernel
        @test rm3.name == "named_mac" && isfile(joinpath(dir, "named_mac.sv"))

        # unannotated function without argtypes must fail loudly
        plain(a::Int32, b::Int32) = a + b
        @test_throws ErrorException hw_compile(plain; outdir = dir)
        @test isfile(hw_compile(plain; argtypes = Tuple{Int32,Int32}, outdir = dir).path)
    end
end
println("\n=== Hardware macro tests passed! ===")
