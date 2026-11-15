# Verify.jl: test vectors from the reference model, a self-checking SV testbench, Verilator runner.

export gen_vectors, write_vectors, emit_testbench, verify_dot, VerifyResult

"One stimulus: lane codes for a and b, the two E8M0 scale codes, and the expected output code."
const Vec = NamedTuple{(:a, :b, :xa, :xb, :exp, :kind),Tuple{Vector{Int},Vector{Int},Int,Int,UInt64,Symbol}}

finite_codes(f::ElemFormat) = [c for c in all_codes(f) if (d = decode(f, c); !d.nan && !d.inf)]
special_codes(f::ElemFormat) = [c for c in all_codes(f) if (d = decode(f, c); d.nan || d.inf)]

"Code of -x (exact for every format here; int min maps to itself)."
function neg_code(f::ElemFormat, c::Integer)
    f isa IntElem && return (-c) & ((1 << f.bits) - 1)
    f isa TernaryElem && return c == 1 ? 3 : c == 3 ? 1 : c
    return c ⊻ (1 << (nbits(f) - 1))
end

"""
    gen_vectors(cfg; nrand=5000, exhaustive=true, seed=1) -> Vector

1. **exhaustive products**: every (a, b) code pair, one at a time, rotating through the lanes
   (only when there are at most 2^16 pairs, e.g. FP4×FP4 = 256, FP8×FP8 = 65536);
2. **random blocks** in five flavours: uniform finite codes, sparse (mostly zero), near-total
   cancellation (pairs that cancel plus a small residue, which stresses the normalizer), same-sign
   maximum magnitude (stresses the sum width), and a few with NaN/Inf elements or NaN scales;
   scales mix uniform 0..254 with the extremes that push the result into subnormal/overflow.
"""
function gen_vectors(c::DotConfig; nrand::Int=5000, exhaustive::Bool=true, seed::Int=1)
    rng = Xoshiro(seed)
    K = c.block
    vs = Vec[]
    mk(a, b, xa, xb, kind) = push!(vs, (a=a, b=b, xa=xa, xb=xb, exp=dot_ref(c, a, b, xa, xb), kind=kind))
    za, zb = zeros(Int, K), zeros(Int, K)
    na, nb = length(all_codes(c.a)), length(all_codes(c.b))
    if exhaustive && na * nb <= 1 << 16
        lane = 0
        for ca in all_codes(c.a), cb in all_codes(c.b)
            a = copy(za); b = copy(zb)
            a[lane+1] = ca; b[lane+1] = cb
            mk(a, b, 127, 127, :exhaustive)
            lane = (lane + 1) % K
        end
    end
    fa, fb = finite_codes(c.a), finite_codes(c.b)
    sa, sb = special_codes(c.a), special_codes(c.b)
    edge = [0, 1, 2, 64, 100, 127, 154, 200, 253, 254]
    scale() = rand(rng) < 0.3 ? rand(rng, edge) : rand(rng, 0:254)
    maxa = argmax(x -> abs(Float64(elem_value(c.a, x))), fa)
    maxb = argmax(x -> abs(Float64(elem_value(c.b, x))), fb)
    for t in 1:nrand
        r = rand(rng)
        a = rand(rng, fa, K); b = rand(rng, fb, K)
        kind = :uniform
        if r < 0.15
            kind = :sparse
            for i in 1:K
                rand(rng) < 0.8 && (a[i] = 0)
            end
        elseif r < 0.35 && K >= 2
            kind = :cancel
            for i in 1:2:K-1
                a[i+1] = a[i]; b[i+1] = neg_code(c.b, b[i])
            end
            isodd(K) || (a[K] = rand(rng, fa))   # small residue
        elseif r < 0.42
            kind = :maxmag
            a .= maxa; b .= maxb
            rand(rng) < 0.5 && (b .= neg_code(c.b, maxb))
        elseif r < 0.47 && (!isempty(sa) || !isempty(sb) || c.scale_a || c.scale_b)
            kind = :special
            for _ in 1:rand(rng, 1:2)
                i = rand(rng, 1:K)
                if !isempty(sa) && rand(rng) < 0.5
                    a[i] = rand(rng, sa)
                elseif !isempty(sb)
                    b[i] = rand(rng, sb)
                end
                rand(rng) < 0.2 && (b[i] = 0; a[i] = isempty(sa) ? a[i] : rand(rng, sa))  # Inf × 0
            end
        end
        xa, xb = scale(), scale()
        if kind == :special && (c.scale_a || c.scale_b) && rand(rng) < 0.3
            c.scale_a ? (xa = 255) : (xb = 255)
        end
        mk(a, b, xa, xb, kind)
    end
    return vs
end

hexw(x::Integer, w::Int) = string(x, base=16, pad=cld(w, 4))

function write_vectors(c::DotConfig, vs, dir)
    mkpath(dir)
    WA, WB, WO = nbits(c.a), nbits(c.b), nbits(c.out)
    open(joinpath(dir, "a.hex"), "w") do io
        foreach(v -> println(io, hexw(pack_lanes(v.a, WA), c.block * WA)), vs)
    end
    open(joinpath(dir, "b.hex"), "w") do io
        foreach(v -> println(io, hexw(pack_lanes(v.b, WB), c.block * WB)), vs)
    end
    open(joinpath(dir, "x.hex"), "w") do io
        foreach(v -> println(io, hexw((v.xa << 8) | v.xb, 16)), vs)
    end
    open(joinpath(dir, "r.hex"), "w") do io
        foreach(v -> println(io, hexw(v.exp, WO)), vs)
    end
end

function emit_testbench(c::DotConfig, n::Int, dir::AbstractString)
    K, WA, WB, WO = c.block, nbits(c.a), nbits(c.b), nbits(c.out)
    f(name) = replace(abspath(joinpath(dir, name)), "\\" => "/")
    io = IOBuffer()
    println(io, SV_BANNER)
    println(io, "// Self-checking testbench: drives one vector per cycle, compares every result bit-exactly.")
    println(io, "`timescale 1ns/1ps")
    println(io, "module tb;")
    println(io, "  localparam int N = $n;")
    println(io, "  logic clk = 1'b0, rst_ni = 1'b0, valid_i = 1'b0, valid_o;")
    println(io, "  logic [$(K*WA-1):0] a_i = '0;")
    println(io, "  logic [$(K*WB-1):0] b_i = '0;")
    println(io, "  logic [15:0] x_i = '0;")
    println(io, "  logic [$(WO-1):0] result_o;")
    println(io, "  logic [$(K*WA-1):0] A [N];")
    println(io, "  logic [$(K*WB-1):0] B [N];")
    println(io, "  logic [15:0] X [N];")
    println(io, "  logic [$(WO-1):0] R [N];")
    println(io, "  int got = 0, errors = 0;")
    println(io)
    println(io, "  $(c.name) dut (")
    println(io, "    .clk_i(clk), .rst_ni(rst_ni), .valid_i(valid_i), .a_i(a_i), .b_i(b_i),")
    c.scale_a && println(io, "    .xa_i(x_i[15:8]),")
    c.scale_b && println(io, "    .xb_i(x_i[7:0]),")
    println(io, "    .valid_o(valid_o), .result_o(result_o));")
    println(io)
    println(io, "  always #5 clk = ~clk;")
    println(io)
    println(io, "  initial begin")
    println(io, "    \$readmemh(\"$(f("a.hex"))\", A);")
    println(io, "    \$readmemh(\"$(f("b.hex"))\", B);")
    println(io, "    \$readmemh(\"$(f("x.hex"))\", X);")
    println(io, "    \$readmemh(\"$(f("r.hex"))\", R);")
    println(io, "    repeat (3) @(posedge clk);")
    println(io, "    #1 rst_ni = 1'b1;")
    println(io, "    for (int i = 0; i < N; i++) begin")
    println(io, "      @(posedge clk); #1;")
    println(io, "      valid_i = 1'b1; a_i = A[i]; b_i = B[i]; x_i = X[i];")
    println(io, "    end")
    println(io, "    @(posedge clk); #1 valid_i = 1'b0;")
    println(io, "    repeat ($(c.stages + 4)) @(posedge clk);")
    println(io, "    if (got != N) begin")
    println(io, "      \$display(\"FAIL: received %0d of %0d results\", got, N);")
    println(io, "      errors++;")
    println(io, "    end")
    println(io, "    \$display(\"DOTGEN_RESULT vectors=%0d errors=%0d\", N, errors);")
    println(io, "    \$finish;")
    println(io, "  end")
    println(io)
    println(io, "  always @(negedge clk) if (rst_ni && valid_o) begin")
    println(io, "    if (got < N && result_o !== R[got]) begin")
    println(io, "      errors++;")
    println(io, "      if (errors <= 10)")
    println(io, "        \$display(\"MISMATCH vec %0d: got %h expected %h (x=%h)\", got, result_o, R[got], X[got]);")
    println(io, "    end")
    println(io, "    got++;")
    println(io, "  end")
    println(io, "endmodule")
    path = joinpath(dir, "tb_$(c.name).sv")
    write(path, String(take!(io)))
    return path
end

struct VerifyResult
    vectors::Int
    errors::Int
    by_kind::Dict{Symbol,Int}
    log::String
end
passed(r::VerifyResult) = r.errors == 0 && r.vectors > 0

"""
    verify_dot(cfg; dir, nrand=5000, exhaustive=true, seed=1, verbose=true) -> VerifyResult

Generate the RTL and vectors for `cfg`, build a Verilator simulation and check
every output bit-exactly against [`dot_ref`](@ref).
"""
function verify_dot(c::DotConfig; dir::AbstractString=mktempdir(), nrand::Int=5000,
                    exhaustive::Bool=true, seed::Int=1, verbose::Bool=true)
    Sys.which("verilator") === nothing && error("verilator not found on PATH")
    mkpath(dir)
    rtl = emit_dot(c, dir)
    vs = gen_vectors(c; nrand, exhaustive, seed)
    write_vectors(c, vs, dir)
    tb = emit_testbench(c, length(vs), dir)
    kinds = Dict{Symbol,Int}()
    foreach(v -> kinds[v.kind] = get(kinds, v.kind, 0) + 1, vs)
    verbose && println("[verify] $(length(vs)) vectors (", join(["$k=$n" for (k, n) in sort(collect(kinds))], ", "), ")")
    obj = joinpath(dir, "obj_dir")
    build = `verilator --binary --timing -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style --top-module tb -Mdir $obj $tb $rtl`
    out = IOBuffer()
    ok = success(pipeline(build; stdout=out, stderr=out))
    ok || error("verilator build failed:\n" * String(take!(out)))
    run_out = read(`$(joinpath(obj, "Vtb"))`, String)
    m = match(r"DOTGEN_RESULT vectors=(\d+) errors=(\d+)", run_out)
    m === nothing && error("simulation produced no result line:\n$run_out")
    r = VerifyResult(parse(Int, m[1]), parse(Int, m[2]), kinds, run_out)
    if verbose
        for l in split(run_out, '\n')
            (startswith(l, "MISMATCH") || startswith(l, "FAIL")) && println("  ", l)
        end
        println("[verify] ", passed(r) ? "PASS" : "FAIL", ": $(r.vectors) vectors, $(r.errors) mismatches")
    end
    return r
end
