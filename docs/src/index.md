```@meta
CurrentModule = HWExplore
```

# HWExplore.jl

HWExplore compiles computation of a dataflow graph defined in plain Julia, or extracted straight from a Julia function, into a pipelined SystemVerilog datapath, and wires that datapath behind a RISC-V **custom instruction** dispatched via [CV-X-IF](https://docs.openhwgroup.org/projects/openhw-group-core-v-xif/), tightly coupled into a real microcontroller.

You define your math. HWExplore turns it into either:

- a general dataflow-graph-to-RTL compiler that schedules it, pipelines it, emits it, or
- a curated library of hand-crafted, expert-tuned datapaths (SIMD, modular arithmetic, memory-backed algorithms),

routed through the *same* auto-generated dispatcher, so a hand-written and an auto-generated accelerator look identical to the CPU issuing instructions.

## Where to start

## What it delivers today

This is a snapshot of what's actually implemented and verified, not the long-term vision.

**The compiler core**
- A dataflow-graph IR (`HWGraph` / `DFGNode`) with opcodes covering arithmetic (`ADD`, `SUB`, `MUL`, `MOD`), bitwise (`SHR`, `SHL`, `AND`, `OR`, `XOR`), comparisons, a ternary `MUX`, `ARG`/`CONST`/`RET`, `OP_REG` for loop-carried state, and an `OP_PRIMITIVE` escape hatch for hand-written IP.
- A **multi-cycle-aware ASAP scheduler** that respects real per-opcode latencies (`MUL` takes longer than `ADD`) via topological sort and finish-cycle tracking, plus a **resource-constrained list scheduler** for sharing a limited pool of functional units.
- A **Verilog emitter** (feedforward and FSM/loop backends) turning a scheduled graph into pipelined SystemVerilog with the standardized `clk_i / rst_ni / start_i / rs1_i / rs2_i / rd_o / done_o` contract every datapath shares — including **resource sharing**: `emit_verilog(graph, path; share=Dict(OP_MUL => 1))` binds nodes onto a limited number of physical units with an operand mux, instead of one operator per node.
- **Hardware-description macros** (`@unroll`, `@tree_reduce`, `@hwkernel`, `hw_compile`) for describing and configuring hardware in ordinary Julia — see the [Guide to Using HWExplore](@ref).

**The primitive library**
A registry (`PrimitiveLibrary`) of hand-written SystemVerilog modules with declared latency, including a 4-lane SIMD multiply-accumulate, saturating addition, and Barrett/Montgomery modular-arithmetic primitives — the baseline that auto-generated datapaths are compared against.

**The dispatch layer and CV-X-IF integration**
A build manifest (`scripts/build_manifest.jl`) plus `DispatcherEmitter.jl` generate the `funct3`-based dispatcher (`hwx_mux.sv`); `cvxif_hwx_shell.sv` implements the CV-X-IF issue/commit/result handshake. This whole stack is **verified working end to end**: a real cross-compiled RISC-V binary, running on a Verilated `cv32e40px` CPU inside a full X-HEEP system, issuing custom instructions and getting correct results back — see `docs/XHEEP_Integration.md`.

## Quick install

```julia
using Pkg
Pkg.develop(path="/path/to/HWExplore")   # or Pkg.add, once/if registered
```

See [Installation](@ref) for the full setup, including the non-Julia tools (Verilator, a RISC-V toolchain, X-HEEP) needed for simulation and full-system integration.

In short, HWExplore turns Julia descriptions of custom accelerators into scheduled RTL, generated dispatch logic, and verified system-level integration for X-HEEP.
