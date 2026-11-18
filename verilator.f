// Verilator file list for editor linting (nvim-lint passes this with -F, so
// paths are relative to this file). Only what single-file lint needs to resolve
// imports and instances; not a build file list.

// Waivers. In single-file lint, MULTITOP (the files below are extra tops) and
// MODDUP (when the open file is also listed below) are artifacts, not bugs.
-Wno-MULTITOP
-Wno-MODDUP
hw/lint/verilator_waivers.vlt

// Module search paths (a module is found when its file is named <module>.sv)
-y hw/rtl
-y hw/rtl/primitives
-y hw/rtl/generated

// X-HEEP / CV32E40X packages and interfaces (order matters: deps first)
hw/ext_xheep/hw/core-v-mini-mcu/include/addr_map_rule_pkg.sv
hw/ext_xheep/hw/core-v-mini-mcu/include/power_manager_pkg.sv
hw/ext_xheep/hw/core-v-mini-mcu/include/core_v_mini_mcu_pkg.sv
hw/ext_xheep/hw/core-v-mini-mcu/include/xheep_obi_pkg.sv
hw/ext_xheep/hw/vendor/openhwgroup/cv32e40x/rtl/include/cv32e40x_pkg.sv
hw/ext_xheep/hw/vendor/openhwgroup/cv32e40x/rtl/if_xif.sv

// Modules whose filename differs from the module name (-y can't find these)
hw/rtl/primitives/hwx_mont_multiplier.sv
hw/rtl/skid_buffer.sv
