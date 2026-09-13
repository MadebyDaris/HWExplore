# scripts/build_manifest.jl
# Build manifest → generate hwx_mux.sv.
# Run: julia --project=. scripts/build_manifest.jl
#
# funct3 encoding:
#   0 → CMD_WRITE_ADDR   (stateful: latch rs1 as address)
#   1 → CMD_WRITE_DATA   (stateful: latch rs1 as write data, pulse we)
#   2 → CMD_START        (stateful: trigger compute)
#   3 → mac_plus_5       (stateless: (rs1*rs2)+5)
#   4 → crc_step         (stateless)
#   5 → hwx_simd_mac   (stateless)
#   6 → hwx_saturating_add (stateless)
#   7 → hwx_barrett_reduction (stateless)

using HWExplore

# Stateful datapath (funct3 0-2)
stateful = StatefulEntry("hwx_mont_adapter", 3, "primitives/hwx_mont_adapter.sv")

# Stateless datapaths (funct3 3-7)
stateless = DatapathEntry[
    DatapathEntry("mac_plus_5",              3, 4, false, "generated/mac_plus_5.sv"),
    DatapathEntry("crc_step",                4, 4, false, "generated/crc_step.sv"),
    DatapathEntry("hwx_simd_mac",          5, 3, false, "primitives/hwx_simd_mac.sv"),
    DatapathEntry("hwx_saturating_add",    6, 2, false, "primitives/hwx_saturating_add.sv"),
    DatapathEntry("hwx_barrett_reduction", 7, 3, false, "primitives/hwx_barrett_reduction.sv"),
]

out_sv = joinpath(@__DIR__, "..", "hw", "rtl", "hwx_mux.sv")
emit_dispatcher(stateful, stateless, out_sv)
println("Done — 1 stateful + $(length(stateless)) stateless datapaths in mux")