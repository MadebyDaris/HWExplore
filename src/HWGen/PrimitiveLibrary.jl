# PrimitiveLibrary.jl
# Included directly into HWExplore module - no submodule wrapper.

export PrimitiveSpec, PRIMITIVES, register_primitive!

# Metadata for one hardware primitive in the registry.
#
# - name:             Symbol key, e.g. :simd_mac
# - module_name:      Verilog top-level module, e.g. "hwx_simd_mac"
# - file_path:        relative to hw/rtl/, e.g. "primitives/hwx_simd_mac.sv"
# - latency:          pipeline depth in cycles (nominal)
# - variable_latency: true if actual latency is data-dependent (e.g. iterative FSM)
# - params:           default parameter overrides, e.g. Dict(:LANES => 4, :DATA_WIDTH => 8)
struct PrimitiveSpec
    name::Symbol
    module_name::String
    file_path::String
    latency::Int
    variable_latency::Bool
    params::Dict{Symbol,Any}
end

const PRIMITIVES = Dict{Symbol,PrimitiveSpec}()

function register_primitive!(spec::PrimitiveSpec)
    PRIMITIVES[spec.name] = spec
    tag = spec.variable_latency ? "[VARIABLE]" : ""
    println("[PrimitiveLibrary] Registered :$(spec.name) → $(spec.module_name) (latency=$(spec.latency)) $tag")
end

# Built-in primitives

register_primitive!(PrimitiveSpec(
    :simd_mac,
    "hwx_simd_mac",
    "primitives/hwx_simd_mac.sv",
    3, false,
    Dict(:LANES => 4, :DATA_WIDTH => 8)
))

register_primitive!(PrimitiveSpec(
    :barrett_reduction,
    "hwx_barrett_reduction",
    "primitives/hwx_barrett_reduction.sv",
    3, false,
    Dict(:WORD_WIDTH => 32, :MODULUS => 12289, :K => 349496)
))

register_primitive!(PrimitiveSpec(
    :montgomery_multiplier,
    "hwx_mont_adapter",
    "primitives/hwx_mont_adapter.sv",
    3, true,   # variable_latency: iterative FSM takes dozens of cycles
    Dict(:WORD_WIDTH => 32, :NUM_WORDS => 4, :R => 1024, :N => 997, :N_INV_MOD_N => 493)
))

register_primitive!(PrimitiveSpec(
    :saturating_add,
    "hwx_saturating_add",
    "primitives/hwx_saturating_add.sv",
    2, false,
    Dict(:LANES => 4, :DATA_WIDTH => 8)
))