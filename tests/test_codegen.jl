using HWExplore

println("=========================================")
println("=== 1. Simple Arithmetic (MAC)      ===")
println("=========================================")
function ex_mac(a::Int32, b::Int32, c::Int32)
    t1 = a * b
    t2 = t1 + c
    
    return t2
end
mod_mac = get_llvm_module(ex_mac, Int32, Int32, Int32)
println(string(mod_mac))

println("\n=========================================")
println("=== 2. Branching (If-Else)          ===")
println("=========================================")
function ex_branch(a::Int32, b::Int32)
    if a > b
        return a - b
    else
        return b - a
    end
end
mod_branch = get_llvm_module(ex_branch, Int32, Int32)
println(string(mod_branch))

println("\n=========================================")
println("=== 3. Simple For Loop (Summation)  ===")
println("=========================================")
function ex_loop(n::Int32)
    sum = Int32(0)
    for i in 1:n
        sum += i
    end
    return sum
end
mod_loop = get_llvm_module(ex_loop, Int32, )
println(string(mod_loop))

println("\n=========================================")
println("=== 4. Array Access (Dot Product)   ===")
println("=========================================")
# Using NTuple instead of Vector because Vector can cause dynamic allocation issues in GPUCompiler without careful handling
function ex_tuple(a::NTuple{4, Int32}, b::NTuple{4, Int32})
    sum = Int32(0)
    for i in 1:4
        @inbounds sum += a[i] * b[i]
    end
    return sum
end
mod_tuple = get_llvm_module(ex_tuple, NTuple{4, Int32}, NTuple{4, Int32})
println(string(mod_tuple))

println("\n=========================================")
println("=== 5. HWExplore Unrolled Loop         ===")
println("=========================================")
function ex_unroll(a::Int32, b::Int32, c::Int32)
    result = Int32(0)
    HWExplore.@nexus_unroll factor=4 for i in 1:16
        result += a * b + c
    end
    return result
end
mod_unroll = get_llvm_module(ex_unroll, Int32, Int32, Int32)
HWExplore.apply_unroll_pass(mod_unroll; factor = 4)
println(string(mod_unroll))