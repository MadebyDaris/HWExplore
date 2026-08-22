#!/usr/bin/env bash
set -e

echo "=========================================="
echo "      NexusV Testing Pipeline             "
echo "=========================================="

echo "[1/4] Building SW Tests..."
make -C sw/tests clean all
echo "SW Build OK."

echo ""
echo "[2/4] Running HW Unit Tests..."
make -C hw/tb_veril clean test_all
echo "HW Unit Tests OK."

echo ""
echo "[3/4] Building System Simulation (tb_nexus_system)..."
bash hw/tb_veril/build_nexus_sim.sh
echo "System Simulation Build OK."

echo ""
echo "[4/4] Running System Simulation (End-to-End)..."
./hw/tb_veril/obj_dir/Vtb_nexus_system +firmware=sw/tests/smoke_test/main.hex
echo "System Simulation OK."

echo "=========================================="
echo "      All Pipeline Tests Passed!          "
echo "=========================================="
