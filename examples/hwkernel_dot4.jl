# examples/hwkernel_dot4.jl
#
# The whole HWExplore experience in one file: a 4-element vector dot product
# described with the hardware macros, compiled to SystemVerilog at three
# different multiplier budgets, and checked against the same Julia function
# running on the CPU.
#
#   julia --project=. examples/hwkernel_dot4.jl
#
# Emits hw/rtl/generated/dot4_m{4,2,1}.sv. Testbench: `make -C hw/tb_veril
# test_hwkernel_dot4` runs all three against tb_vector_dot4.cpp.

using HWExplore

# `vec=(a=4,b=4)`  a and b are 4-element vector ports (scalar ports a_1..a_4, b_1..b_4)
# `share=(mul=4,)`  default budget: up to 4 multipliers (no sharing needed)
# `@unroll tree=true`  unroll fully AND rebalance the accumulation into a tree
@hwkernel vec=(a=4, b=4) share=(mul=4,) function dot4(a::Int32, b::Int32)
    acc = Int32(0)
    @unroll tree=true for i in 1:4
        acc += a[i] * b[i]
    end
    acc
end

# The function is still ordinary Julia — same code is the golden model:
@assert dot4(Int32.(1:4)..., Int32.(5:8)...) == 70

outdir = joinpath(@__DIR__, "..", "hw", "rtl", "generated")
println("\n multipliers | latency (cycles) | module")
println(" ------------+------------------+--------------")
for muls in (4, 2, 1)
    r = hw_compile(dot4; name = "dot4_m$muls", share = (mul = muls,), outdir = outdir)
    println(" $(lpad(muls, 11)) | $(lpad(r.latency, 16)) | $(r.name)")
end
