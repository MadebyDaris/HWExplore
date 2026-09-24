# Guide to Using HWExplore

This walks through the whole Julia to RTL to simulation loop, end to end, with real commands and real output. If a term here (scheduling, binding, initiation interval) is unfamiliar, [Guide to High-Level Synthesis (HLS)](@ref) explains it before you need it below.

## The three ways to describe a computation

| Approach | When to use it |
|---|---|
| [`@hwkernel`](@ref) + [`hw_compile`](@ref) | The normal path: write plain Julia, get RTL. Start here. |
| [`extract_and_translate`](@ref) directly | You want the `HWGraph` itself before scheduling/emitting (inspection, custom pipelines). |
| Build an [`HWGraph`](@ref) by hand | Full control over node structure; mostly useful for tests or non-Julia-sourced graphs. |

### The `@hwkernel` path

```julia
using HWExplore

@hwkernel vec=(a=4, b=4) share=(mul=4,) function dot4(a::Int32, b::Int32)
    acc = Int32(0)
    @unroll tree=true for i in 1:4
        acc += a[i] * b[i]
    end
    acc
end
```

`dot4` is still an ordinary Julia function you can use the macros `@unroll` and `@tree_reduce` that are source-to-source rewrites that run before the function is even defined, so what gets compiled to hardware is exactly what runs on the CPU. That means the function is its own golden model:

```julia
@assert dot4(Int32.(1:4)..., Int32.(5:8)...) == 70
```

`vec=(a=4, b=4)` expands the two vector arguments into 8 scalar ports (`a_1..a_4`, `b_1..b_4`, the DFG has no memory/array operations, so a "vector" is a wider port list) and rewrites every constant-index `a[i]` inside the body to the matching scalar. `share=(mul=4,)` is the default resource budget, discussed below.

Now compile it:

```julia
r = hw_compile(dot4; outdir = "hw/rtl/generated")
```

Actual output:
```text
[HWExplore] Synthesized 'dot4' → 18 DFG nodes, 8 inputs, 1 outputs
Emitted: hw/rtl/generated/dot4.sv  (latency = 6 cycle(s), 0 shared unit(s) covering 0 nodes)
```

`r` is `(name, path, graph, latency, share, kind)`. Every keyword to `hw_compile` overrides whatever `@hwkernel` recorded, which is what makes a design-space sweep a plain loop:

```julia
for muls in (4, 2, 1)
    r = hw_compile(dot4; name = "dot4_m$muls", share = (mul = muls,), outdir = "hw/rtl/generated")
    println(muls, " multipliers -> ", r.latency, " cycles")
end
```
```text
4 multipliers -> 6 cycles
2 multipliers -> 8 cycles
1 multipliers -> 12 cycles
```

Fewer multipliers, more cycles, less area  that trade-off *is* resource sharing; see [Resource sharing](@ref guide-resource-sharing) below for what's actually happening in the emitted RTL.

### Direct `extract_and_translate` / `HWGraph`

`@hwkernel` is sugar over this:

```julia
graph, fsm = extract_and_translate(dot4, Tuple{Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32}; name = "dot4")
schedule_asap!(graph)
emit_verilog(graph, "hw/rtl/generated/dot4.sv")
```

`extract_and_translate` walks the function's typed SSA IR (via IRTools) and builds an [`HWGraph`](@ref) of [`DFGNode`](@ref)s. Building one directly (no Julia function at all) is the same struct:

```julia
using .DFG_Builder
graph = HWGraph("my_accel", Dict(
    1 => DFGNode(1, OP_ARG, 32, [], nothing, 0, 0, nothing, Dict()),
    2 => DFGNode(2, OP_ARG, 32, [], nothing, 0, 0, nothing, Dict()),
    3 => DFGNode(3, OP_MUL, 32, [1, 2], nothing, 0, 0, nothing, Dict()),
    4 => DFGNode(4, OP_RET, 32, [3], nothing, 0, 0, nothing, Dict()),
), [1, 2], [4])
```

## What comes out

Every emitted module  hand-written primitive or auto-generated  shares one port contract:

```systemverilog
module <name> (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,
    input  logic        stall_i,
    input  logic [31:0] rs1_i,
    input  logic [31:0] rs2_i,   // up to rs8_i for wider designs
    output logic [31:0] rd_o,
    output logic        done_o
);
```

Pulse `start_i` for one cycle; `done_o` asserts exactly `latency` cycles later, the same cycle `rd_o` becomes valid. This uniformity is what lets a hand-written primitive and an auto-generated datapath sit behind the identical CV-X-IF dispatch slot (see `docs/XHEEP_Integration.md`) without special-casing, and what lets every design point in a sweep drop into the same testbench.

## Testing what you generated

```bash
verilator --cc hw/rtl/generated/my_accel.sv --exe hw/tb_veril/tb_generated.cpp --top-module my_accel
make -C obj_dir -f Vmy_accel.mk Vmy_accel
./obj_dir/Vmy_accel
```

`tb_generated.cpp` assumes the standard 2-operand contract (`rs1_i`/`rs2_i`); for a wider design (more than 2 inputs, from `vec=`), write a small testbench following the same drive/pulse/poll pattern `hw/tb_veril/tb_vector_dot4.cpp` is a worked 8-input example, parameterized at compile time (`-DDUT=<module>`) so one file tests every design-point variant of a kernel. Full walkthrough, including waveform inspection: `docs/Usage_and_Examples.md`.

## [Resource sharing](@id guide-resource-sharing)

```julia
emit_verilog(graph, "out.sv"; share = Dict(OP_MUL => 1))
```

binds every `OP_MUL` node onto at most 1 physical multiplier: nodes are assigned to units by interval coloring (never two nodes that overlap in time on the same unit the resource-constrained scheduler guarantees this is possible within the budget), and the emitted RTL gets one multiplier per unit with an operand mux selecting which node's operands feed it, keyed by a one-hot-in-time `sel_<id>` signal derived from the existing `done_o` shift register. Each node's result is captured in its own hold register. Shareable classes: `ADD SUB MUL MOD SHL SHR AND OR XOR`; comparisons, `MUX`, and primitive nodes are always dedicated.

Real numbers, a 4-element dot product synthesized with Yosys+ABC against the Sky130 standard-cell library already vendored in this repository:

| multipliers | latency (cycles) | area (µm²) |
|---:|---:|---:|
| 4 (no sharing) | 5 | 175 000 |
| 2 | 7 | 108 000 |
| 1 | 11 | 71 000 |

`sharing_report(graph, budget)` gives you the same numbers (latency, unit count, unshared-operator count) without emitting anything  useful inside a sweep before committing to writing files.

## The macros in full

- [`@unroll`](@ref) replicate a constant-bound loop: `full` (default), `factor=n`, or `tree=true` (rewrite an accumulation into a balanced reduction tree, exact for wrapping integers).
- [`@tree_reduce`](@ref)  rebalance any `+ * & | ⊻` chain  a log-depth tree, standalone.
- [`@hwkernel`](@ref)  record `name`, `share`, `tree`, `vec` options next to a function definition.
- [`hw_compile`](@ref)  Julia function → SystemVerilog, reading `@hwkernel`'s recorded options and letting keywords override any of them.

All four are covered with worked examples and design notes (why `vec` exists, what `tree=true` actually rewrites, the known limits of resource sharing) in `Resource_Sharing_and_Macros.md`, kept as a local working draft alongside the DSE research notes rather than in the published documentation set.

## Loops and the FSM backend

A function with a genuine (non-unrolled) loop  one with a loop-carried value the DFG can't express as straight-line dataflow  routes automatically through the FSM backend instead of the feedforward pipeline emitter: `hw_compile` detects `OP_REG` nodes (register-carried state across a back-edge) in the translated graph and calls [`emit_fsm_verilog`](@ref) instead of [`emit_verilog`](@ref), producing a real state machine rather than a flat pipeline. `share=` is ignored for these (resource sharing is feedforward-only today  see the [API Reference](@ref) for `analyse_fsm` and the FSM-specific emitter).

## Wiring a datapath into the dispatcher

To make a datapath reachable from a real RISC-V custom instruction (rather than just standalone-testable), register it in the build manifest:

```julia
DatapathEntry("my_accel", 4, 2, false, "generated/my_accel.sv"),   # funct3 = 4
```

then regenerate the dispatcher:

```bash
julia --project=. scripts/build_manifest.jl
```

`hwx_mux.sv` is rewritten to route `funct3 = 4` to `my_accel`. From here, see `docs/XHEEP_Integration.md` for building and running the full system.
