# Guide to High-Level Synthesis (HLS)

High-level synthesis is the general idea of compiling a program written in a software language (C, C++, or here, Julia) into a hardware description (RTL, Verilog/VHDL). HWExplore is a small, opinionated HLS tool for one specific target RISC-V custom-instruction coprocessors I decided to do this for XHEEP and thinking about expanding to other MCU's as well. This page explains the standard HLS vocabulary and maps each term directly onto the piece of HWExplore that implements it.

## The pipeline every HLS tool has

```@raw html
<pre>
source program  →  intermediate representation  →  scheduling  →  binding  →  RTL
</pre>
```

| Stage | What it does | In HWExplore |
|---|---|---|
| Front end | Parse the source and lower it to an IR | [`extract_and_translate`](@ref) walks a Julia function's typed SSA IR (via IRTools) |
| IR | A graph of operations and their data dependencies | [`HWGraph`](@ref) / [`DFGNode`](@ref) — a dataflow graph (DFG) |
| Scheduling | Assign every operation a clock cycle | `schedule_asap!` / `schedule_list!` |
| Binding | Assign operations to physical functional units | [`bind_units`](@ref) ([resource sharing](@ref hls-binding)) |
| Back end | Emit RTL implementing the scheduled, bound design | [`emit_verilog`](@ref) / [`emit_fsm_verilog`](@ref) |

If you already know HLS, that table is the whole orientation you need — the rest of this page works through each stage in more depth, and where HWExplore is narrower than a general HLS tool.

## Dataflow graph (DFG)

The IR is a directed acyclic graph (mostly see [Loops](@ref hls-loops) below) of operation nodes: `ADD`, `MUL`, comparisons, a ternary `MUX`, and so on, plus `ARG`/`CONST` sources and a `RET` sink. Each node's `inputs` list the node IDs producing its operands. This is the same shape as the SSA form most compilers already use internally, `extract_and_translate` builds it directly from Julia's own SSA IR, one DFG node per SSA instruction.

Two operations are said to be **independent** if neither is a (transitive) input of the other,nothing stops them running in the same clock cycle. A 4-element dot product's four multiplies (`a[i]*b[i]` for `i=1..4`) are mutually independent; the reduction adds that sum them are not (each depends on multiplies finishing first).

## Scheduling

Scheduling assigns each node a clock cycle. HWExplore's scheduler is **multi-cycle-aware**: it knows a multiply takes 2 cycles and an add takes 1 (`OP_LATENCY`), and a node can't start until every input's *result* is actually available, not just "one cycle after the input started", but after the input's full latency. This is done via topological sort plus finish-cycle tracking (`schedule_asap!`).

**ASAP** (as-soon-as-possible) scheduling the default, puts every node in the earliest cycle its dependencies allow, hence the name as soon as possible. This is exactly what gives the 4-element dot product's four multiplies the same start cycle: nothing depends on them being staggered, so ASAP doesn't stagger them. ALAP (as-late-as-possible) scheduling is the opposite, putting every node in the latest cycle it can be without delaying the final result. HWExplore doesn't implement ALAP yet, but it would be a simple variant of `schedule_asap!` that walks the graph backward instead of forward. These two work together to give a range of valid cycles for each node, which is the input to the next stage, binding.

**Resource-constrained list scheduling** (`schedule_list!`, used automatically when `emit_verilog(...; share=...)` is given a budget of `OP`'s). No more than `budget[op]` operations of class `op` may be used in any cycle. If four multiplies all want cycle 2 but the budget is 1, three of them get pushed later, this is what makes resource sharing possible at all; see [Binding](@ref hls-binding) next.

**Initiation interval (II)** is the number of cycles between when consecutive invocations of the same hardware can start. HWExplore's datapaths have II = latency: a new `start_i` pulse is only meaningful after the previous `done_o` (single-instruction-in-flight). Pipelining a datapath to accept a new operation before the last one finishes (II < latency) is a HLS technique HWExplore does not yet implement.

## [Binding (in other words resource sharing)](@id hls-binding)

Scheduling says *when*; binding says *on which physical unit*. Without binding, a naive backend instantiates one operator per operation, four multiplies in the DFG means four multiplier circuits in the RTL.

**Resource sharing** trades area for latency by binding several *non-overlapping-in-time* operations onto one physical unit, with a multiplexer selecting which operation's operands feed it each cycle:

```julia
emit_verilog(graph, "out.sv"; share = Dict(OP_MUL => 1))
```

Concretely, [`bind_units`](@ref) does interval-graph coloring over each node's `[scheduled_cycle, finish_cycle]`. The emitter then generates one operator per *unit* (not per node), controlled operand mux and a per-node result-hold register. WE can for isntance with the 4-element dot product, reducing the multipliers needed at the cost of latency. See the [Guide to Using HWExplore](@ref) for the full table and the emitted RTL shape.

This is the one part of the classic HLS pipeline HWExplore didn't have until recently — see `DSE_Implementation_Plan.md`'s Phase 0 (kept as a local working note) for the design history.

## [Loops](@id hls-loops)

A DFG are acyclic. As a result to solve this problem, HWExplore provides two main approaches:

- **Unrolling** ([`@unroll`](@ref)): replicate the loop body once per iteration at the *source* level, before any DFG is built at all. A 4-iteration loop unrolled fully becomes 4 independent copies of the body in a straight line.
- **The FSM backend** ([`emit_fsm_verilog`](@ref)): for a genuine loop with loop-carried state (an accumulator that depends on its own previous value across iterations `OP_REG` nodes in the graph, detected by `analyse_fsm`'s back-edge analysis), HWExplore emits a real state machine instead: one state per basic block, with cross-state liveness analysis deciding which values need registers at state boundaries. This is a different, heavier code path than the feedforward pipeline emitter.

`hw_compile` picks between the two automatically based on whether the translated graph has `OP_REG` nodes, so from the user's side the choice is really "did I unroll this loop or not," made where the loop is written.

## Binding to an instruction, not a bus

Most HLS tutorials assume the generated RTL becomes a memory-mapped accelerator block, reached over a bus, with data moved in and out by DMA. HWExplore generates something narrower and more tightly integrated: a **custom RISC-V instruction**. The generated datapath plugs into a dispatcher (`hwx_mux.sv`) behind the coprocessor shell, and the CPU issues it like any other instruction a bunch of operands from the register file, the result goes back into the register file, and the CPU pipeline stalls waiting for `done_o`. There's no separate memory-mapped control/status register interface to design. This changes what the interesting design-space knobs are: not buffer sizing and bandwidth, but per-instruction latency and how many functional units a datapath shares, more in [Guide to Using HWExplore](@ref) for using it.

## Where HWExplore is intentionally narrower than general HLS

- **No memory operations in the DFG.** No loads, no stores, no arrays. A "vector" argument (`vec=(a=4,)` in [`@hwkernel`](@ref)) is a fixed-size bundle of scalar ports, not a memory access every index must resolve to a compile-time constant (typically from unrolling a loop over it).
- **No floating point.** Everything is fixed-width integer arithmetic. The reduction-tree rewrite ([`@tree_reduce`](@ref)) specifically relies on integer `+`/`*`/`&`/`|`/`⊻` being associative and commutative, which is not true for IEEE754 floats.
- **Two-operand instruction limit.** A single custom instruction only ever carries two register operands (`rs1`, `rs2`); a datapath with more inputs (from `vec=`) is fully valid, pipelined RTL can accept more than two operands, but the CPU can't issue it in one instruction. HWExplore doesn't yet support multi-instruction datapaths, so the user must either reduce to two operands or unroll to a single instruction.

- **Aimed specifically at the class of small, latency-critical kernels that make sense to offload as a single instruction rather than a whole accelerator block.**
