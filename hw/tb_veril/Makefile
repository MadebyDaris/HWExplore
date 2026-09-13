# Makefile for HW Verilator Unit Tests

VERILATOR = verilator

# RTL directories
RTL = ../rtl
PRIMITIVES = ../rtl/primitives

# Includes for X-HEEP integration
XHEEP = ../ext_xheep
INCDIRS = -I$(XHEEP)/hw/core-v-mini-mcu/include \
          -I$(XHEEP)/hw/vendor/lowrisc/opentitan/hw/ip/prim/rtl \
          -I$(XHEEP)/hw/vendor/lowrisc/opentitan/hw/ip/prim_generic/rtl \
          -I$(XHEEP)/hw/vendor/pulp_platform/register_interface/include \
          -I$(XHEEP)/hw/vendor/pulp_platform/register_interface/src \
          -I$(XHEEP)/hw/vendor/pulp_platform/common_cells/include \
          -I$(XHEEP)/hw/vendor/openhwgroup/cve2/rtl \
          -I$(XHEEP)/hw/vendor/openhwgroup/cve2/bhv \
          -I$(XHEEP)/hw/vendor/openhwgroup/cv32e40p/rtl/include \
          -I$(XHEEP)/hw/vendor/openhwgroup/cv32e40px/rtl/include

VFLAGS = --cc --exe --build -Wno-fatal -Wno-DECLFILENAME -Wno-EOFNEWLINE $(INCDIRS) --trace

# ── Individual Unit Tests ──
test_saturating: tb_saturating.cpp $(PRIMITIVES)/hwx_saturating_add.sv
	$(VERILATOR) $(VFLAGS) --top-module hwx_saturating_add $^
	./obj_dir/Vhwx_saturating_add

test_simd_mac: tb_simd_mac.cpp $(PRIMITIVES)/hwx_simd_mac.sv
	$(VERILATOR) $(VFLAGS) --top-module hwx_simd_mac $^
	./obj_dir/Vhwx_simd_mac

test_barrett: tb_barrett.cpp $(PRIMITIVES)/hwx_barrett_reduction.sv
	$(VERILATOR) $(VFLAGS) --top-module hwx_barrett_reduction $^
	./obj_dir/Vhwx_barrett_reduction

test_mont_stateful: tb_mont_stateful.cpp $(PRIMITIVES)/hwx_mont_adapter.sv $(PRIMITIVES)/hwx_mont_multiplier.sv
	$(VERILATOR) $(VFLAGS) --top-module hwx_mont_adapter $^
	./obj_dir/Vhwx_mont_adapter

test_mux_all: tb_mux_all.cpp $(RTL)/hwx_mux.sv $(RTL)/generated/mac_plus_5.sv $(RTL)/generated/crc_step.sv $(PRIMITIVES)/hwx_simd_mac.sv $(PRIMITIVES)/hwx_saturating_add.sv $(PRIMITIVES)/hwx_barrett_reduction.sv $(PRIMITIVES)/hwx_mont_adapter.sv $(PRIMITIVES)/hwx_mont_multiplier.sv
	$(VERILATOR) $(VFLAGS) --top-module hwx_mux $^
	./obj_dir/Vhwx_mux

test_cvxif: tb_cvxif.cpp $(RTL)/cvxif_hwx_shell.sv $(XHEEP)/hw/vendor/openhwgroup/cv32e40x/rtl/include/cv32e40x_pkg.sv
	$(VERILATOR) $(VFLAGS) --top-module cvxif_hwx_shell $^
	./obj_dir/Vcvxif_hwx_shell

test_all: test_saturating test_simd_mac test_barrett test_mont_stateful test_mux_all test_cvxif

clean:
	rm -rf obj_dir *.vcd

.PHONY: test_saturating test_simd_mac test_barrett test_mont_stateful test_mux_all test_cvxif test_all clean
