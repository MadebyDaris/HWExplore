using Test
using MacroTools
using HWExplore

# 1. Define test functions at the global file scope
@nexus_accelerate function mac_elemental(a::Int8, b::Int8)
    return a * b
end

@nexus_accelerate function barrett_reduction(x::Int32, y::Int32, q::Int32)
    return (x * y) % q
end

@nexus_accelerate function untyped_add(x, y)
    return x + y
end

# 2. Run the tests inside @testset
@testset "HWExplore Phase 1: Macro Interception Tests" begin

    @testset "ML Workload (Int8 Types)" begin
        res = mac_elemental(Int8(2), Int8(4))
        @test res.name == :mac_elemental
        @test res.args == [:a, :b]
        @test res.types == [:Int8, :Int8]
    end

    @testset "PQC Workload (Int32 Types)" begin
        res = barrett_reduction(Int32(10), Int32(20), Int32(7))
        @test res.name == :barrett_reduction
        @test res.args == [:x, :y, :q]
        @test res.types == [:Int32, :Int32, :Int32]
    end

    @testset "Untyped Fallback" begin
        res = untyped_add(1, 2)
        @test res.types == [:Any, :Any]
    end

end