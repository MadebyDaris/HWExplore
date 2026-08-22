# Baremetal Testing & System Simulation

This guide explains how to cross-compile baremetal C tests and run the full-system X-HEEP simulation incorporating the NexusV CV-X-IF accelerator.

## 1. Prerequisites

- **RISC-V GCC** (`riscv-none-elf-gcc`) — must be on your path.
- **Python 3** with `hjson` (available in X-HEEP's `.venv`)
- **X-HEEP submodule** initialized and `make mcu-gen` run

### X-HEEP CV-X-IF Setup
The X-HEEP is configured by default with `CpuType = cv32e20`, which does **not** support the CV-X-IF coprocessor interface. Custom instructions (opcode `0x0B`) will cause illegal instruction exceptions.

**To use custom instructions:** 
Change `CpuType` to `cv32e40px` in the X-HEEP configuration and re-run `make mcu-gen`.
To do this, edit: `hw/ext_xheep/configs/general.hjson` (line 30), change `cpu_type: cv32e20` to `cpu_type: cv32e40px`.

## 2. Quick Run Instructions

If your X-HEEP is configured and you just want to run the simulation:

```bash
# 1. Compile bare-metal test
cd sw/custom_c
make -f <(echo 'all:; riscv-none-elf-gcc -march=rv32imc_zicsr -mabi=ilp32 -O2 -nostdlib -T link.ld start.S minimal.c -o minimal.elf && riscv-none-elf-objcopy -O binary minimal.elf minimal.bin && hexdump -v -e "1/4 %08x\n" minimal.bin > minimal.hex')

# 2. Build full-system simulation
cd ../..
bash hw/tb_veril/build_nexus_sim.sh

# 3. Run
./hw/tb_veril/obj_dir/Vtb_nexus_system
# Output: EXIT SUCCESS
```

*(Note: The build script suppresses DPI `force` warnings with `-Wno-SYNCASYNCNET`.)*

## 3. How the Full-System Works

`nexus_top.sv` connects X-HEEP + the shell + the generated datapath together. 

### Working Test Suite Recap
- **Baremetal C cross-compile:** Works (`test_mac.hex` generated).
- **Full-system Verilator build:** Builds (781 modules, compiles successfully).
- **Full-system simulation:** SRAM loads correctly, boot flow jumps to application code.

### Memory Map
```text
0x00000000 - 0x00007FFF : Internal SRAM (32 KB)
0x0F0000000 - 0x0F1000000 : External slave (testbench exit peripheral)
0x20000000 - 0x2000FFFF : SOC_CTRL
0x20010000 - 0x2001FFFF : BootROM (59 words, pre-compiled hex)
0x20040000 - 0x2004FFFF : Power Manager
```

### Critical Changes Made to X-HEEP for Simulation
To get the simulation booting cleanly from SRAM (avoiding X-HEEP BootROM stalls), two critical modifications are applied:

1. **CPU Boot Address (`BOOT_ADDR`)**
   In `hw/ext_xheep/hw/core-v-mini-mcu/core_v_mini_mcu.sv`:
   ```systemverilog
   localparam BOOT_ADDR = 32'h00000000; // Skip BootROM, boot directly from SRAM
   ```
   *Why:* The BootROM (`0x20010000`) expects SOC_CTRL at a different base address. The OBI bus register interface adapter doesn't handle BootROM instruction fetches correctly in Verilator, causing the CPU to hang. Bypassing it and booting from SRAM directly works perfectly.

2. **Linker Script (`link.ld`)**
   ```ld
   MEMORY {
       ram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x8000
   }
   ```
   Since `BOOT_ADDR = 0x0`, the program must be linked at `0x0`.

3. **SRAM Load Path (`$readmemh`)**
   In `hw/tb_veril/tb_nexus_system.sv`:
   ```systemverilog
   u_top.u_x_heep.core_v_mini_mcu_i.memory_subsystem_i.ram0_i.tc_ram_i.sram
   ```
   *(Verilator flattens generate blocks, so `gen_sram[0]` is correctly omitted).*

### Software Hierarchy (`sw/custom_c/`)
```text
link.ld                      # 0x00000000, 32 KB SRAM
start.S                      # Minimal CRT: set SP, call main
minimal.c                    # Just write to exit address — ALWAYS WORKS
main.c                       # Smoke test hitting all 4 funct3 datapaths (needs X-IF CPU)
Makefile                     # Cross-compilation with riscv-none-elf-gcc
```

## 4. Troubleshooting / Known Issues

### CPU Not Reaching Exit (DPI Bypass Failure)
Initially, bypassing the BootROM via DPI writes to SOC_CTRL failed because:
1. `prim_subreg_arb` uses `wr_en = we | de`, but the `testbench_set_exit_loop` DPI signal was undriven after reset.
2. Verilator doesn't reliably propagate DPI-written values through combinational chains.
3. Hierarchical DPI writes into deeply nested X-HEEP register chains are unreliable in Verilator.

**Solution:** This was fixed by patching the `BOOT_ADDR` directly to SRAM (`0x00000000`) instead of relying on the BootROM bypass register.

### Build Note for X-HEEP modifications
The `build_nexus_sim.sh` script uses the FuseSoC-generated `.vc` file which points to COPIED sources in:
```text
hw/ext_xheep/build/openhwgroup.org_systems_core-v-mini-mcu_1.0.5/src/...
```
Any edits to sources in `hw/ext_xheep/hw/` must ALSO be applied to the corresponding copies in the build directory, or `make mcu-gen` must be rerun.
