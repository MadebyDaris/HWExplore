#!/usr/bin/env bash
# build_hwx_sim.sh
#
# Stand-alone Verilator build script for tb_hwx_system.
# Compiles hwx_top + cvxif_hwx_shell + mac_plus_5 + the OBI SRAM testbench,
# driving it all via tb_hwx_system.cpp.
#
# Usage: bash sw/platforms/xheep/sim/build_hwx_sim.sh   (from HWExplore root)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
XHEEP="$ROOT/hw/ext_xheep"
RTL="$ROOT/hw/rtl"
TB="$SCRIPT_DIR"
OUT="$SCRIPT_DIR/obj_dir"

echo "=== HWExplore Verilator Build Process ==="
echo "Root: $ROOT"

# 1. Collect all SystemVerilog include directories
INCDIRS=(
    "$XHEEP/hw/core-v-mini-mcu/include"
    "$XHEEP/hw/vendor/lowrisc/opentitan/hw/ip/prim/rtl"
    "$XHEEP/hw/vendor/lowrisc/opentitan/hw/ip/prim_generic/rtl"
    "$XHEEP/hw/vendor/pulp_platform/register_interface/include"
    "$XHEEP/hw/vendor/pulp_platform/register_interface/src"
    "$XHEEP/hw/vendor/pulp_platform/common_cells/include"
    "$XHEEP/hw/vendor/openhwgroup/cve2/rtl"
    "$XHEEP/hw/vendor/openhwgroup/cve2/bhv"
    "$XHEEP/hw/vendor/openhwgroup/cv32e40p/rtl/include"
    "$XHEEP/hw/vendor/openhwgroup/cv32e40px/rtl/include"
)

INCFLAGS=""
for d in "${INCDIRS[@]}"; do
    [ -d "$d" ] && INCFLAGS="$INCFLAGS -I$d"
done

# 2. Extract Verilator arguments from FuseSoC output
VC_IN="$XHEEP/build/openhwgroup.org_systems_core-v-mini-mcu_1.0.5/sim-verilator/openhwgroup.org_systems_core-v-mini-mcu_1.0.5.vc"
VC_OUT="$OUT/filtered.vc"

mkdir -p "$OUT"

if [ ! -f "$VC_IN" ]; then
    echo "[ERROR] FuseSoC .vc file not found at $VC_IN"
    echo "Did you run 'make mcu-gen' successfully?"
    exit 1
fi

python3 "$TB/gen_vc.py" "$VC_IN" "$VC_OUT"

# 3. Run Verilator
echo "--- Running Verilator ---"
verilator \
    --cc \
    --timing \
    --exe "$TB/tb_hwx_system.cpp" \
    --top-module tb_hwx_system \
    --Mdir "$OUT" \
    --trace \
    --assert \
    -Wall \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-PINCONNECTEMPTY \
    -Wno-UNDRIVEN -Wno-LITENDIAN -Wno-IMPLICIT \
    -Wno-IMPORTSTAR -Wno-VARHIDDEN -Wno-EOFNEWLINE \
    -Wno-ASSIGNIN -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -Wno-UNSIGNED -Wno-LATCH -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN \
    --language 1800-2012 \
    -f "$VC_OUT" \
    "$RTL/generated/mac_plus_5.sv" \
    "$RTL/generated/crc_step.sv" \
    "$RTL/primitives/hwx_simd_mac.sv" \
    "$RTL/primitives/hwx_saturating_add.sv" \
    "$RTL/primitives/hwx_barrett_reduction.sv" \
    "$RTL/primitives/hwx_mont_multiplier.sv" \
    "$RTL/primitives/hwx_mont_adapter.sv" \
    "$RTL/hwx_mux.sv" \
    "$RTL/hwx_scratchpad.sv" \
    "$RTL/cvxif_hwx_shell.sv" \
    "$RTL/hwx_top.sv" \
    "$TB/tb_hwx_system.sv" \
    2>&1

echo "--- Compiling generated C++ ---"
make -C "$OUT" -f Vtb_hwx_system.mk Vtb_hwx_system 2>&1

echo "=== Build complete: $OUT/Vtb_hwx_system ==="
