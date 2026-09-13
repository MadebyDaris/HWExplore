# Baremetal Testing & System Simulation

This guide explains how to cross-compile baremetal C tests and run the full-system X-HEEP simulation incorporating the HWExplore CV-X-IF accelerator.

All of this lives under `sw/platforms/xheep/` — X-HEEP is the only integration target today, but the `sw/platforms/<name>/` layout leaves room to add another target (a different SoC, a different RTOS) later without touching this one.

## 1. Prerequisites

- **RISC-V GCC for HWExplore's own firmware** — any `riscv32` bare-metal toolchain (`riscv-none-elf-gcc`, `riscv32-corev-elf-gcc`, ...) on your `PATH`. If it lives somewhere else, every `make` invocation under `sw/platforms/xheep/` accepts `RISCV_PREFIX=/path/to/bin/riscv32-corev-elf-` (trailing dash) as an override; the build fails fast with a clear message if neither is found. **X-HEEP's own `make mcu-gen` also needs a working RISC-V toolchain** (to build its BootROM image) — see §5.3, this is a separate, easy-to-miss requirement from the one above.
- **Python 3** with `hjson` and `fusesoc` — X-HEEP ships a working `.venv` at `hw/ext_xheep/.venv/` with both already installed; see §5.1 for why you must actually use it.
- **X-HEEP submodule** initialized and `make mcu-gen` run successfully (see §5 if it isn't).

### X-HEEP CV-X-IF Setup
X-HEEP is configured by default with `cpu_type: cv32e20`, which has no CV-X-IF port at all, **and** even with a CV-X-IF-capable core, the eXtension interface itself defaults to disabled. Both of the following are required in `hw/ext_xheep/configs/general.hjson`, or custom instructions (opcode `0x0B`) raise illegal-instruction exceptions:

```hjson
cpu_type: cv32e40px      // cv32e20 has no CV-X-IF port at all

cpu_features: {
    cv_x_if: {}          // without this, cv32e40px_xif_wrapper's X_INTERFACE
}                         // parameter defaults to 0 — see §5.4, this one is easy to miss
                          // since `cpu_type: cv32e40px` alone looks sufficient but isn't.
```

Re-run `make mcu-gen` after changing either.

## 2. Quick Run Instructions

The whole pipeline (SW build → HW unit tests → full-system build → full-system run) is one command from the repo root:

```bash
bash scripts/test_pipeline.sh
```

To run just the full-system simulation step by step:

```bash
# 1. Compile bare-metal test firmware (all sw/platforms/xheep/tests/* programs)
make -C sw/platforms/xheep/tests

# 2. Build full-system simulation
bash sw/platforms/xheep/sim/build_hwx_sim.sh

# 3. Run, pointing it at the firmware hex to load
./sw/platforms/xheep/sim/obj_dir/Vtb_hwx_system +firmware=sw/platforms/xheep/tests/smoke_test/main.hex
# Output: EXIT SUCCESS
```

*(Note: The build script suppresses DPI `force` warnings with `-Wno-SYNCASYNCNET`.)*

## 3. How the Full-System Works

`hwx_top.sv` connects X-HEEP + the shell + the generated datapath together. 

### Working Test Suite Recap
- **Baremetal C cross-compile:** Works for all three programs (`smoke_test`, `minimal`, `test_mac`).
- **Full-system Verilator build:** Builds cleanly against a `cv32e40px` + CV-X-IF-enabled X-HEEP.
- **Full-system simulation:** Boots from SRAM, executes real code, and reaches `EXIT SUCCESS` — confirmed for all three test programs, with `smoke_test` exercising all four stateless `funct3` datapaths (`mac_plus_5`, `crc_step`, `hwx_simd_mac`, `hwx_saturating_add`) through the real CV-X-IF issue/commit/result handshake end to end. This was the project's first full-system CV-X-IF pass — see §5 for exactly what stood between "boots" and "reaches EXIT SUCCESS", since none of it is obvious from the error messages alone.

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
   In `sw/platforms/xheep/sim/tb_hwx_system.sv`:
   ```systemverilog
   u_top.u_x_heep.core_v_mini_mcu_i.memory_subsystem_i.ram0_i.tc_ram_i.sram
   ```
   *(Verilator flattens generate blocks, so `gen_sram[0]` is correctly omitted).*

### Software Hierarchy (`sw/platforms/xheep/`)
```text
sw/platforms/xheep/
├── common/
│   ├── link.ld               # 0x00000000, 32 KB SRAM
│   ├── start.S                # Minimal CRT: set SP, call main
│   └── rules.mk               # Shared cross-compilation rules (toolchain, .elf/.bin/.hex)
├── tests/
│   ├── Makefile                # Builds every test program below
│   ├── minimal/minimal.c       # Just writes to the exit address — always works
│   ├── smoke_test/main.c       # Hits all funct3 datapaths behind the mux (needs X-IF CPU)
│   └── test_mac/test_mac.c     # Single-datapath (mac_plus_5) regression test
└── sim/
    ├── build_hwx_sim.sh        # Verilator build for the full X-HEEP + shell + mux system
    ├── gen_vc.py                # Filters the FuseSoC-generated .vc file for Verilator
    ├── tb_hwx_system.sv         # Full-system testbench top (SRAM load, exit peripheral)
    └── tb_hwx_system.cpp        # Verilator driver for tb_hwx_system
```

## 4. Troubleshooting / Known Issues

### CPU Not Reaching Exit (DPI Bypass Failure)
Initially, bypassing the BootROM via DPI writes to SOC_CTRL failed because:
1. `prim_subreg_arb` uses `wr_en = we | de`, but the `testbench_set_exit_loop` DPI signal was undriven after reset.
2. Verilator doesn't reliably propagate DPI-written values through combinational chains.
3. Hierarchical DPI writes into deeply nested X-HEEP register chains are unreliable in Verilator.

**Solution:** This was fixed by patching the `BOOT_ADDR` directly to SRAM (`0x00000000`) instead of relying on the BootROM bypass register.

## 5. Setting Up From Scratch: Every Blocker and Its Fix

`make mcu-gen` failing with a confusing error the first time you run it is normal, not a sign something is broken — X-HEEP's build auto-detects several things (Python environment, toolchain paths) that fail silently or misleadingly when the auto-detection guesses wrong. This section is the complete list of blockers hit getting a clean checkout to `EXIT SUCCESS`, in the order you'll hit them, because the error at each step rarely points at the actual cause.

### 5.1 `make mcu-gen` fails with `ModuleNotFoundError: No module named 'hjson'`

**Cause:** `hw/ext_xheep/Makefile` picks its Python/FuseSoC binaries based on whether a conda environment is active (`ifndef CONDA_DEFAULT_ENV`). If your shell has *any* conda env active — including the default `base` one most shells auto-activate — the Makefile assumes that environment has `fusesoc`/`hjson` installed and reaches for plain `python`/`fusesoc` on `PATH` instead of X-HEEP's own `.venv`, which actually has them.

**Fix:** Force X-HEEP's own `.venv` onto `PATH` before running any `hw/ext_xheep` `make` target, regardless of conda state:

```bash
export PATH="$(pwd)/hw/ext_xheep/.venv/bin:$PATH"
```

(If you keep a dedicated conda env for this with `fusesoc`/`hjson` installed, that works too — the point is *some* environment with both packages needs to be what `python`/`fusesoc` resolve to.)

### 5.2 `make mcu-gen` fails with `Error: Could not parse Verilator version from the output.`

**Cause:** `hw/ext_xheep/util/waiver-gen.py` parses `verilator --version` with a regex (`rev v(\d+)\.\d+`) that assumes an official Verilator release string (`... rev v5.038`). Distro-packaged Verilator builds report a different suffix — Fedora's, for example, prints `... rev fedora-5.046` (no `v`), which never matches.

**Fix:** already patched in this repo's checkout of the submodule — `waiver-gen.py` now matches the version straight off the leading `Verilator X.Y` instead, which is present in every build's output regardless of packaging. If you ever re-vendor a clean copy of X-HEEP, re-apply this one-line regex fix.

### 5.3 `make mcu-gen` fails building `boot_rom.elf`: `/bin/gccelf-gcc: No such file or directory`

**Cause:** X-HEEP's own `mcu-gen` step compiles a small BootROM image, using a toolchain path built from two variables: `hw/ext_xheep/hw/ip/boot_rom/Makefile` has `GCC ?= $(RISCV_XHEEP)/bin/$(COMPILER_PREFIX)elf-gcc`, and the top-level `Makefile` auto-detects `COMPILER_PREFIX` by globbing `$(RISCV_XHEEP)/bin/*gcc`. If `RISCV_XHEEP` is unset, that glob silently becomes `/bin/*gcc` — which matches your system's own native `gcc` — producing the nonsensical prefix `gcc` and the resulting bogus path `/bin/gccelf-gcc`. This is doubly confusing because it looks like a typo in X-HEEP's own Makefile rather than a missing toolchain.

**Fix:** install a RISC-V bare-metal toolchain and point `RISCV_XHEEP` at its root (the directory containing `bin/`). X-HEEP's own CI uses the CORE-V OpenHW GCC toolchain at prefix `riscv32-corev-elf-`:

```bash
mkdir -p ~/.local/riscv-corev
curl -L "https://buildbot.embecosm.com/job/corev-gcc-ubuntu2204/47/artifact/corev-openhw-gcc-ubuntu2204-20240530.tar.gz" \
  | tar -xz -C ~/.local/riscv-corev --strip-components=1

export RISCV_XHEEP="$HOME/.local/riscv-corev"
export COMPILER_PREFIX="riscv32-corev-"
```

(This is the same tarball X-HEEP's own Docker CI image installs — see `hw/ext_xheep/util/docker/dockerfile`. The Ubuntu-22.04 build runs fine on newer glibc distros too.) With both set, `make mcu-gen` should complete cleanly. This toolchain also works for HWExplore's own firmware — point `RISCV_PREFIX="$RISCV_XHEEP/bin/riscv32-corev-elf-"` at it when building `sw/platforms/xheep/tests/`.

### 5.4 `make mcu-gen` succeeds, sim boots, but every custom instruction traps (tight refetch loop back to address 0)

**Cause:** this is the one that has no error message at all — the build and boot both look fine, but the CPU falls into what looks like an infinite loop restarting from address `0x0` within a few cycles of hitting the *first* custom (`CUSTOM_0`/opcode `0x0B`) instruction. `cpu_type: cv32e40px` alone is not sufficient to enable CV-X-IF: X-HEEP's `cv32e40px_xif_wrapper` has `parameter bit X_INTERFACE = 0` (disabled), and `cpu_subsystem.sv` only sets it to `1` if the config has a *separate* `cpu_features.cv_x_if` key set (see `hw/ext_xheep/util/xheep_gen/load_config.py`, `_configure_cpu`). With `X_INTERFACE=0`, the core's own decoder never routes `CUSTOM_0` to the X-IF ports — it just raises an illegal-instruction exception, which (since `mtvec` defaults to the same address as `BOOT_ADDR`, `0x0`, and nothing has programmed a real trap handler) redirects execution straight back into your own `_start`, which immediately re-executes the same instructions and traps again, forever.

Diagnosing this requires an internal probe, since the external symptom (nothing happening past a certain point) looks identical to a dozen other possible bugs. If you hit an unexplained silent hang/loop like this again, a quick diagnostic is a temporary `$display` on the CPU's raw fetch request, hierarchically:

```systemverilog
if (u_top.u_x_heep.core_v_mini_mcu_i.cpu_subsystem_i.core_instr_req_o.req)
    $display("[DBG] IF addr=%h", u_top.u_x_heep.core_v_mini_mcu_i.cpu_subsystem_i.core_instr_req_o.addr);
```

If the fetched addresses repeat identically instead of advancing, that's a trap loop — check the disassembly (`riscv32-corev-elf-objdump -d`) of whatever address it's looping around for anything unusual there.

**Fix:** add the `cpu_features: { cv_x_if: {} }` block shown in §1 to `general.hjson`, then `make mcu-gen` again.

### 5.5 Config/RTL patches don't survive `make mcu-gen`

**Cause:** `make mcu-gen` regenerates `hw/core-v-mini-mcu/*.sv` from `.tpl` templates every time it runs, which silently reverts any hand-patch to those files — including the `BOOT_ADDR` patch in §3. This is easy to lose track of: you patch `BOOT_ADDR`, everything works, you later change `general.hjson` for an unrelated reason and rerun `mcu-gen`, and the boot hang from §3 comes back with no obvious link to what you just changed.

**Fix:** reapply the `BOOT_ADDR` patch (§3) after every `make mcu-gen`. Config-file changes (`cpu_type`, `cpu_features.cv_x_if`) are safe — they live in `general.hjson`, which `mcu-gen` reads, not generates, so they persist across reruns on their own.

### 5.6 Build Note for X-HEEP modifications
The `sw/platforms/xheep/sim/build_hwx_sim.sh` script uses the FuseSoC-generated `.vc` file which points to COPIED sources in:
```text
hw/ext_xheep/build/openhwgroup.org_systems_core-v-mini-mcu_1.0.5/src/...
```
Any edits to sources in `hw/ext_xheep/hw/` (including reapplying the `BOOT_ADDR` patch per §5.5) must ALSO be copied into the corresponding file under that build directory, or `make mcu-gen` must be rerun (which re-copies everything, but also reverts `BOOT_ADDR` again — see §5.5). The fastest reliable loop after touching `hw/ext_xheep/hw/core-v-mini-mcu/core_v_mini_mcu.sv` specifically:

```bash
cp hw/ext_xheep/hw/core-v-mini-mcu/core_v_mini_mcu.sv \
   hw/ext_xheep/build/openhwgroup.org_systems_core-v-mini-mcu_1.0.5/src/openhwgroup.org_systems_core-v-mini-mcu_1.0.5/hw/core-v-mini-mcu/core_v_mini_mcu.sv
rm -rf sw/platforms/xheep/sim/obj_dir
bash sw/platforms/xheep/sim/build_hwx_sim.sh
```
