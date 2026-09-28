#!/usr/bin/env bash
# synth/run_synth.sh
#
# Runs a small, fixed set of HWExplore-generated datapaths through Yosys+ABC
# against the Sky130 liberty file already vendored for the X-HEEP ASIC flow,
# and drops one `stat -liberty` log per design into synth/results/. Nothing
# fancy: this is a quick sanity/comparison pass, not a real ASIC flow (no
# floorplanning, no timing closure, no DRC/LVS).
#
# Usage:
#   synth/run_synth.sh
#
# Requires `yosys` on PATH (with `abc` built in, as in most distro packages
# and the `yosys-dse` conda env used earlier in this project).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

LIB="../hw/ext_xheep/hw/asic/sky130/sky130_fd_sc_lp__ss_150C_1v65.lib"
GEN="../hw/rtl/generated"
OUT="results"
mkdir -p "$OUT"

# name : source file : top module
DESIGNS=(
  "mac_plus_5:${GEN}/mac_plus_5.sv:mac_plus_5"
  "crc_step:${GEN}/crc_step.sv:crc_step"
  "horner_poly:${GEN}/horner_poly.sv:horner_poly"
  "vector_dot4_share4:${GEN}/vector_dot4.sv:vector_dot4"
  "vector_dot4_share2:${GEN}/vector_dot4_shared_2.sv:vector_dot4_shared_2"
  "vector_dot4_share1:${GEN}/vector_dot4_shared_1.sv:vector_dot4_shared_1"
)

echo "design,cells,area_um2" > "$OUT/summary.csv"

for entry in "${DESIGNS[@]}"; do
  IFS=':' read -r name src top <<< "$entry"
  log="$OUT/${name}.log"
  json="$OUT/${name}.json"
  echo "== ${name} (${top} <- ${src}) =="

  sed -e "s#@SRC@#${src}#" -e "s#@TOP@#${top}#" -e "s#@LIB@#${LIB}#" -e "s#@JSON@#${json}#" \
    synth.ys.tmpl > "$OUT/${name}.ys"

  yosys -q -l "$log" "$OUT/${name}.ys"

  cells=$(awk '/ cells$/ {print $1; exit}' "$log")
  area=$(awk -F"'" '/Chip area for module/ {print $0}' "$log" | grep -oE "[0-9]+\.[0-9]+" | head -1)
  echo "  cells=${cells:-?}  area=${area:-?} um^2"
  echo "${name},${cells:-0},${area:-0}" >> "$OUT/summary.csv"
done

echo
echo "Done. Per-design logs and summary.csv in ${OUT}/"
column -s, -t "$OUT/summary.csv"
