# Contributing to HWExplore

Thank you for your interest in contributing to HWExplore! This document provides guidelines and workflows for contributing to the repository.

## Getting Started

Before contributing, ensure you have the following prerequisites installed:
- **Julia 1.9+**
- **Verilator 5.x**
- **RISC-V GCC Toolchain** (`riscv-none-elf-gcc`)
- **Python 3**
- **Make** and a C++ compiler (`g++` or `clang++`)

Ensure that the X-HEEP submodule is fully initialized if you plan to work on system-level integration.

## Development Workflow

A typical developer workflow for adding a new feature or operation looks like this:

1. **Define the Graph/Operation:** Update the graph model in `src/Core/DFG_Builder.jl` and add the operation's latency/translation logic in `src/Frontend/IRTranslator.jl`.
2. **Schedule & Emit:** Ensure the scheduler (`src/HWGen/Scheduler.jl`) correctly schedules the new operations and the emitter (`src/HWGen/VerilogEmitter.jl`) correctly translates them to SystemVerilog.
3. **Simulate (Datapath Level):** Compile the generated Verilog using Verilator and test i`t using a standalone C++ testbench (e.g. `hw/tb_veril/tb_generated.cpp`).
4. **Integration (Optional):** Test the generated datapath with the CV-X-IF shell or a full X-HEEP integration.

For a more detailed explanation of the architecture and workflow, see the guides in the `docs/` folder:
- [Architecture and Internals](docs/Architecture_and_Internals.md)
- [Usage and Examples](docs/Usage_and_Examples.md)
- [Baremetal and System Simulation](docs/Baremetal_and_System_Simulation.md)

## Coding Standards

### Julia Code
- **Tests First:** Always add tests in the `tests/` directory to cover new features, AST/IR translation rules, or edge cases. Run tests locally with `julia --project=. tests/runtests.jl` before submitting a PR.
- **Type Stability:** The IR translator and graph builders should remain type-stable to allow robust synthesis.

### Hardware (SystemVerilog)
- **Modularity:** Generated RTL should be completely independent of the CV-X-IF shell. Keep the handshake generic (`start_i`, `done_o`, `stall_i`, `rs1_i`, `rs2_i`, `rd_o`).
- **Ignore Rules:** Do not commit generated artifacts (e.g., `obj_dir`, `.vcd`, `.log`, `.o`, `.elf`). These are ignored in `.gitignore`. 

## How to Submit Changes

1. **Fork the Repository:** Create your own fork and a branch for your feature (`git checkout -b feature/my-new-feature`).
2. **Commit Often:** Write clear and concise commit messages.
3. **Update Documentation:** If you are adding a new feature or changing how the pipeline is run, please update the relevant documentation in `docs/` and the `CHANGELOG.md`.
4. **Open a Pull Request:** Open a PR against the `main` branch. Provide a clear summary of your changes and why they are necessary.

## Getting Help
If you are stuck, check the existing tests in `tests/test_dfg.jl` or `tests/test_ir_translator.jl` for working examples of the generation pipeline.
