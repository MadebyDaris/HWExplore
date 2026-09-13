#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "      HWExplore Testing Pipeline             "
echo "=========================================="

echo "[1/4] Building SW Tests (X-HEEP platform)..."
make -C sw/platforms/xheep/tests clean all
echo "SW Build OK."

echo ""
echo "[2/4] Running HW Unit Tests..."
make -C hw/tb_veril clean test_all
echo "HW Unit Tests OK."

echo ""
echo "[3/4] Building System Simulation (tb_hwx_system)..."
bash sw/platforms/xheep/sim/build_hwx_sim.sh
echo "System Simulation Build OK."

echo ""
echo "[4/4] Running System Simulation (End-to-End)..."
./sw/platforms/xheep/sim/obj_dir/Vtb_hwx_system +firmware=sw/platforms/xheep/tests/smoke_test/main.hex
echo "System Simulation OK."

echo "=========================================="
echo "      All Pipeline Tests Passed!          "
echo "=========================================="
