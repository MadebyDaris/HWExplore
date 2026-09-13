# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **First full-system CV-X-IF pass on X-HEEP.** All four stateless datapaths (`mac_plus_5`, `crc_step`, `hwx_simd_mac`, `hwx_saturating_add`) now execute correctly through the real CV-X-IF issue/commit/result handshake on a Verilated `cv32e40px` + X-HEEP system, reaching `EXIT SUCCESS`. This required four independent fixes, none of which were obvious from their error messages — full detail in `docs/Baremetal_and_System_Simulation.md` §5:
  - `hw/ext_xheep/util/waiver-gen.py`'s Verilator-version regex only matched official release strings (`rev v5.038`), not distro-packaged builds (Fedora's `rev fedora-5.046`) — broadened to match the leading `Verilator X.Y` instead.
  - `make mcu-gen` picks its Python/FuseSoC binaries based on `CONDA_DEFAULT_ENV` rather than checking they actually work — an active `base` conda env (common shell default) made it use a system Python lacking `hjson`/`fusesoc` instead of X-HEEP's own working `.venv`.
  - `make mcu-gen`'s own BootROM build needs a working RISC-V toolchain (`RISCV_XHEEP`/`COMPILER_PREFIX`), separate from the toolchain used for HWExplore's own firmware — installed the CORE-V OpenHW GCC toolchain X-HEEP's own CI uses.
  - **The actual blocker**: `cpu_type: cv32e40px` alone does not enable CV-X-IF — `cv32e40px_xif_wrapper`'s `X_INTERFACE` parameter defaults to `0` unless `general.hjson` also sets `cpu_features.cv_x_if`. Without it, every `CUSTOM_0` instruction decoded as illegal, trapping back to address 0 in a tight loop that looked like a hang, not a decode error.
- Reapplied the `BOOT_ADDR` SRAM-boot patch, which `make mcu-gen` silently reverts on every run (it regenerates `core_v_mini_mcu.sv` from a template) — documented as a standing gotcha, not just fixed once.
- `sw/platforms/xheep/sim/tb_hwx_system.sv`: removed a dead `initial`-block assignment to `exit_valid_o`/`exit_value_o` that conflicted with the module's real (already-correct) exit-detection `always_ff` block once traced through; also fixed a stale fallback firmware path (`sw/custom_c/minimal.hex`, from before the `sw/` reorganization) to `sw/platforms/xheep/tests/minimal/minimal.hex`.
- `sw/platforms/xheep/tests/test_mac/test_mac.c` used a stale `funct3=0` encoding for `mac_plus_5` from before the stateful/stateless `funct3` split existed (0 is now `CMD_WRITE_ADDR`); updated to `funct3=3`, matching `scripts/build_manifest.jl`.

### Added
- **`docs/XHEEP_Integration.md`**: comprehensive reference for how HWExplore actually plugs into X-HEEP today (and what doesn't, yet), a step-by-step build/run/verify walkthrough, and a detailed roadmap for full X-HEEP connection (native app/FPGA flow) and automated resource sharing (what the scheduler already does vs. what the emitter still needs to do). Updated with the full-system pass above and a complete "every blocker and its fix" troubleshooting section.
- **IR Translation Layer (`IRTranslator.jl`)**: Support for directly capturing Julia SSA IR and resolving it to the hardware Data-Flow Graph (DFG).
- **Macro Interface**: Added `@synthesize` macro for intuitive user-facing hardware generation.
- **Multi-Cycle Scheduling**: `Scheduler.jl` now supports variable latencies for different hardware operations (e.g., OP_MUL is 2 cycles, OP_MOD is 3 cycles).
- **Resource Constraints**: List scheduling support added via `ResourceAllocator.jl` to serialize operations using the same hardware resource budget.
- **Full-System SystemVerilog Top (`hwx_top.sv`)**: Integrates X-HEEP, the CV-X-IF shell, and custom datapaths.
- **Baremetal Testing**: Cross-compilation scripts for RISC-V and tests running directly on the simulated SRAM.
- **Automated Tests**: Extensive test suite covering DFG builder, SSA extraction, control flow tracking, and Verilog emission.

### Changed
- **Project renamed from NexusV to HWExplore**: Julia package (`Project.toml` name/UUID, `src/NexusV.jl` → `src/HWExplore.jl`, module `NexusV` → `HWExplore`), all `nexus_*` SystemVerilog module and file names → `hwx_*` (e.g. `nexus_top.sv` → `hwx_top.sv`, `nexus_mux.sv` → `hwx_mux.sv`, `cvxif_nexus_shell.sv` → `cvxif_hwx_shell.sv`), and matching updates across docs, tests, scripts, and testbenches.
- **Documentation reorganized**: trimmed the README to a concise overview and moved the detailed CV-X-IF/mux/scratchpad/skid-buffer wiring reference and the RISC-V ISA `funct3`/`funct7` dispatch explanation into `docs/Architecture_and_Internals.md`; consolidated fragmented notes into the central guides listed above; fixed stale directory references (`src/Compiler/`, `hw/src_hw/`) left over from an earlier restructuring.
- **RTL reorganized**: auto-generated example datapaths (`mac_plus_5.sv`, `crc_step.sv`, `horner_poly.sv`, `f_1.sv`) moved to `hw/rtl/generated/`, separating them from hand-written core infra in `hw/rtl/` and hand-written IP in `hw/rtl/primitives/`. `hwx_mux.sv` stays in `hw/rtl/` alongside the shell/top it dispatches to, even though it's also auto-generated.
- **Bare-metal / X-HEEP software moved to `sw/platforms/xheep/`**: `sw/tests/{common,smoke_test,minimal,test_mac}` → `sw/platforms/xheep/{common,tests/*}`, and the X-HEEP full-system Verilator harness (`build_hwx_sim.sh`, `gen_vc.py`, `tb_hwx_system.{sv,cpp}`) moved out of `hw/tb_veril/` into `sw/platforms/xheep/sim/`, since it's platform integration, not a generic RTL unit test. The `sw/platforms/<name>/` layout leaves room for other integration targets later. `hw/tb_veril/` now holds only generic, paradigm-agnostic per-primitive testbenches.
- **Fixed hardcoded toolchain path**: `sw/platforms/xheep/common/rules.mk` (and the old, now-removed `sw/custom_c/Makefile`) hardcoded the RISC-V toolchain to a machine-specific `/tmp/xpack-riscv-none-elf-gcc-.../` path. It now resolves `riscv-none-elf-gcc`/`objcopy` from `PATH` by default, overridable via `RISCV_PREFIX=/path/to/bin/riscv-none-elf-`, and fails fast with an actionable error if the toolchain isn't found instead of a cryptic build failure.
- **`scripts/test_pipeline.sh`** now runs under `set -euo pipefail` and drives the relocated `sw/platforms/xheep/` paths end to end (SW build → HW unit tests → full-system build → full-system run) as the single entry point for the whole test pipeline.
- **Project Structure**: Cleaned up the repository layout, moved utilities to `scripts/` and examples to `examples/`. Removed untracked build artifacts and binaries.

### Removed
- **`sw/custom_c/`**: dead directory whose Makefile referenced `main.c`/`test_mac.c`/`link.ld`/`start.S` that no longer existed there — fully superseded by `sw/platforms/xheep/tests/`.
- **`hw/rtl/primitives/nexus_mont.sv`**: empty, unreferenced stub file left over from an earlier pass.

### Fixed
- Fixed `examples/run_pipeline.jl` writing generated RTL to `examples/hw/rtl/...` instead of `hw/rtl/...` (a missing `..` in the output path), which meant the script never actually worked.
- Re-routed the X-HEEP boot sequence in Verilator simulation to bypass the default BootROM (`0x20010000`) and boot directly from the memory subsystem SRAM (`0x00000000`), resolving stall issues with the memory bus protocol.

## [0.1.0] - Initial Proof of Concept
### Added
- Julia-based `HWGraph` definitions and frontend data structures.
- ASAP Scheduler and Verilog pipeline emitter.
- Standalone CV-X-IF shell written in SystemVerilog.
- Verilator C++ testbench infrastructure.
