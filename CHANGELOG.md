# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **IR Translation Layer (`IRTranslator.jl`)**: Support for directly capturing Julia SSA IR and resolving it to the hardware Data-Flow Graph (DFG).
- **Macro Interface**: Added `@synthesize` macro for intuitive user-facing hardware generation.
- **Multi-Cycle Scheduling**: `Scheduler.jl` now supports variable latencies for different hardware operations (e.g., OP_MUL is 2 cycles, OP_MOD is 3 cycles).
- **Resource Constraints**: List scheduling support added via `ResourceAllocator.jl` to serialize operations using the same hardware resource budget.
- **Full-System SystemVerilog Top (`nexus_top.sv`)**: Integrates X-HEEP, the CV-X-IF shell, and custom datapaths.
- **Baremetal Testing**: Cross-compilation scripts for RISC-V and tests running directly on the simulated SRAM.
- **Automated Tests**: Extensive test suite covering DFG builder, SSA extraction, control flow tracking, and Verilog emission.

### Changed
- **Documentation**: Consolidated fragmented notes into three central guides (`Architecture_and_Internals.md`, `Usage_and_Examples.md`, `Baremetal_and_System_Simulation.md`).
- **Project Structure**: Cleaned up the repository layout, moved utilities to `scripts/` and examples to `examples/`. Removed untracked build artifacts and binaries.

### Fixed
- Re-routed the X-HEEP boot sequence in Verilator simulation to bypass the default BootROM (`0x20010000`) and boot directly from the memory subsystem SRAM (`0x00000000`), resolving stall issues with the memory bus protocol.

## [0.1.0] - Initial Proof of Concept
### Added
- Julia-based `HWGraph` definitions and frontend data structures.
- ASAP Scheduler and Verilog pipeline emitter.
- Standalone CV-X-IF shell written in SystemVerilog.
- Verilator C++ testbench infrastructure.
