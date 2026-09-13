# X-HEEP Integration: Current State, Usage, and Roadmap

This is the detailed reference for how HWExplore plugs into X-HEEP today, how to actually build and run that integration and confirm it works, and — because today's wiring is intentionally a thin, honest slice — what's still missing and how to build it. If you only need the RTL-level protocol (CV-X-IF channels, shell FSM, mux wiring), that's in [`Architecture_and_Internals.md`](Architecture_and_Internals.md); this document is about the X-HEEP side specifically: configuring it, building it, simulating it, and eventually putting it on real silicon/FPGA.

## 1. What "integrated" means today

**Update:** as of this writing, the full-system integration described below has been built and run end to end for the first time, reaching `EXIT SUCCESS` with all four stateless `funct3` datapaths (`mac_plus_5`, `crc_step`, `hwx_simd_mac`, `hwx_saturating_add`) executing correctly through the real CV-X-IF issue/commit/result handshake on a Verilated `cv32e40px` + X-HEEP system. Getting there required four separate, non-obvious fixes — three in the X-HEEP submodule/environment, one a stale firmware encoding — documented in full in [`Baremetal_and_System_Simulation.md` §5](Baremetal_and_System_Simulation.md#5-setting-up-from-scratch-every-blocker-and-its-fix). Read that section before touching any of this again; every one of those failure modes looks like a different, unrelated bug from its error message alone.

Be precise about what this does and doesn't prove, because "HWExplore works with X-HEEP" still means a specific, narrower thing than "production-ready":

- `hw/rtl/hwx_top.sv` instantiates X-HEEP's `x_heep_system`, wires its `if_xif` CV-X-IF interface to `cvxif_hwx_shell.sv`, and connects the shell to `hwx_mux.sv`, which dispatches to whichever datapath `funct3` selects. **This path is now verified working end to end**, not just wired.
- That whole stack is driven by a **hand-written, standalone Verilator testbench** (`sw/platforms/xheep/sim/tb_hwx_system.sv` / `.cpp`), built by a **hand-written script** (`sw/platforms/xheep/sim/build_hwx_sim.sh`) that post-processes a FuseSoC-generated `.vc` file. This is not X-HEEP's own `app` / `verilator-run-app` flow — it's a parallel, purpose-built harness that exists because getting CV-X-IF wired up at all was the hard part, and it was simpler to verify standalone than to fight X-HEEP's build system at the same time.
- Firmware is cross-compiled completely outside X-HEEP's SDK, using a minimal hand-written CRT (`sw/platforms/xheep/common/start.S` + `link.ld`) that boots straight into SRAM — X-HEEP's own `sw/` application framework, linker scripts, and driver library are not used.
- There is **no FPGA bring-up**. Everything above is Verilator-only. X-HEEP itself supports real FPGA boards (`pynq-z2`, `nexys-a7-100t`, `genesys2`, `aup-zu3`, `zcu102`, `zcu104` via `make vivado-fpga`), but HWExplore has never been run on one.
- There is **no resource sharing in the emitted RTL**. `ResourceAllocator.jl` can compute a schedule that *time-shares* a resource budget, but the Verilog emitter still instantiates one physical operator per graph node regardless — see [§4](#4-roadmap-b-automated-resource-sharing) for why that's a gap and how to close it.
- The scratchpad's stateful path (Montgomery multiplication) was **not** part of this pass — only the four stateless datapaths were exercised. It's still wired per §3.4's description, just not freshly re-verified here.

If you take nothing else from this section: the current integration now proves the CV-X-IF protocol and dispatch mechanism work correctly end-to-end in simulation, on real (Verilated) X-HEEP RTL, with a real cross-compiled RISC-V binary — not just that the pieces are wired together. It does not yet prove area/timing on real hardware, and it does not yet share hardware resources across datapaths.

## 2. Building and running the current integration, step by step

This expands on [`Baremetal_and_System_Simulation.md`](Baremetal_and_System_Simulation.md)'s quick-start with the *why* at each step, so when something breaks you know which layer to look at.

### 2.1 Configure X-HEEP for CV-X-IF

X-HEEP defaults to `cv32e20`, which has no CV-X-IF port at all — and even the right core needs the interface explicitly turned on. Nothing HWExplore does will work until **both** of these are set in `hw/ext_xheep/configs/general.hjson`:

```hjson
cpu_type: cv32e40px       // cv32e20 has no CV-X-IF port at all

cpu_features: {
    cv_x_if: {}           // without this, CUSTOM_0 instructions decode as illegal —
}                          // see Baremetal_and_System_Simulation.md §5.4
```

The second one is easy to miss — `cpu_type: cv32e40px` alone *looks* sufficient (the core supports CV-X-IF) but the interface itself defaults to disabled at the RTL parameter level, so every custom instruction still traps. If custom instructions (`opcode 0x0B`) raise illegal-instruction exceptions, or the CPU falls into a tight loop back to address 0 shortly after issuing the first one, this is why.

### 2.2 Regenerate X-HEEP's MCU sources

```bash
cd hw/ext_xheep
export PATH="$(pwd)/.venv/bin:$PATH"                    # see Baremetal doc §5.1 if this seems unnecessary
export RISCV_XHEEP="$HOME/.local/riscv-corev"            # wherever your RISC-V toolchain lives — see §5.3
export COMPILER_PREFIX="riscv32-corev-"
make mcu-gen
```

This runs X-HEEP's own code generator against `general.hjson` and regenerates `core_v_mini_mcu_pkg.sv`, `cpu_subsystem.sv` (which is where the `cpu_features.cv_x_if` setting above actually takes effect), the OBI crossbar, and the FuseSoC `.vc` manifest that `build_hwx_sim.sh` consumes in the next step. **Any time you edit `general.hjson` or change `cpu_type`, rerun this** — it's the single most common cause of "I changed the config but nothing happened." The two `export`s above are not optional convenience — without them `mcu-gen` fails outright; see [`Baremetal_and_System_Simulation.md` §5.1–5.3](Baremetal_and_System_Simulation.md#5-setting-up-from-scratch-every-blocker-and-its-fix) for exactly why and what each error looks like.

**After every `make mcu-gen`, reapply the `BOOT_ADDR` patch** — `mcu-gen` regenerates `core_v_mini_mcu.sv` from a template, silently reverting it. See [`Baremetal_and_System_Simulation.md` §3](Baremetal_and_System_Simulation.md#3-how-the-full-system-works) for the patch and [§5.5](Baremetal_and_System_Simulation.md#55-configrtl-patches-dont-survive-make-mcu-gen) for why it doesn't stick, and [§5.6](Baremetal_and_System_Simulation.md#56-build-note-for-x-heep-modifications) for syncing it into the FuseSoC build copy `build_hwx_sim.sh` actually compiles.

### 2.3 Build HWExplore's firmware test programs

```bash
make -C sw/platforms/xheep/tests
```

Builds `smoke_test` (exercises every `funct3` datapath behind the mux), `minimal` (writes straight to the exit address — use this first to prove the memory map and boot path work before debugging CV-X-IF itself), and `test_mac` (single-datapath regression). Needs a `riscv32` bare-metal toolchain on `PATH` or `RISCV_PREFIX=...` — see [`Baremetal_and_System_Simulation.md`](Baremetal_and_System_Simulation.md) if that fails. The CORE-V toolchain installed for §2.2 works here too.

### 2.4 Build the full-system Verilator simulation

```bash
bash sw/platforms/xheep/sim/build_hwx_sim.sh
```

This script: collects X-HEEP's SystemVerilog include directories, filters X-HEEP's FuseSoC `.vc` file down to something Verilator can consume directly (`gen_vc.py` strips the `--top-module`/`--exe` args FuseSoC bakes in, since the script supplies its own), then runs Verilator against that filtered file plus every HWExplore RTL source by hand (`hw/rtl/hwx_top.sv`, `cvxif_hwx_shell.sv`, `hwx_mux.sv`, `hwx_scratchpad.sv`, everything under `hw/rtl/primitives/` and `hw/rtl/generated/` that the mux currently dispatches to). **If you add a new datapath to the manifest (`scripts/build_manifest.jl`), you must also add its `.sv` file to the hardcoded list in `build_hwx_sim.sh`** — this is the most fragile part of the current setup and the first thing worth automating (see [§5](#5-suggested-next-steps-in-priority-order)).

### 2.5 Run it and confirm HWExplore actually works

```bash
./sw/platforms/xheep/sim/obj_dir/Vtb_hwx_system +firmware=sw/platforms/xheep/tests/smoke_test/main.hex
```

Expected output:

```text
[TB] SRAM[0] = 00008137
[TB] SRAM[1] = 05372031
[X-HEEP]: NUM_BYTES =        128KB
[TB] EXIT: code=         1
EXIT SUCCESS
```

What "works" looks like, in order of how much it proves:

1. **It doesn't hang.** Two independent failure modes can each cause an infinite run (`TIMEOUT` after ~250k cycles instead of an exit): the CPU stalling on the BootROM fetch path (missing/reverted `BOOT_ADDR` patch, §2.2), or every custom instruction trapping in a tight refetch loop (missing `cpu_features.cv_x_if`, §2.1). Both look identical from the outside — no output at all until the timeout — so check both config points, not just one.
2. **It exits with the right code.** The testbench watches the `ext_slaves` bus region at `0xF0000000` (`core_data_req_o`/`ext_core_data_req_o` in `hwx_top.sv`, configured in `general.hjson`'s `ext_slaves` block) for a write; `EXIT SUCCESS` means the firmware wrote `1` there, i.e. every `funct3` path it exercised returned the expected value and the CPU reached the end of `main()`. `EXIT FAILURE` (any other nonzero value) means a specific test failed — `smoke_test/main.c`'s `TEST()` macro encodes the failing line number into the exit code (`__LINE__ << 1`) so you can find which check failed without instrumentation.
3. **Per-datapath results are right, not just "done".** `smoke_test/main.c` checks each datapath's result against a known-good value in C before moving to the next one — read it if you need to know exactly what's being exercised and what counts as a pass per datapath, not just overall exit status.
4. **Optionally, look at the waveform.** `build_hwx_sim.sh` builds with `--trace`, dumping `sim.vcd` in the working directory — it gets large fast (multi-GB for a full 250k-cycle timeout run), so delete it once you're done and prefer running from the repo root so it doesn't end up somewhere unexpected. Inspect with `scripts/parse_vcd.py` or GTKWave if a datapath passes end-to-end but you want to confirm handshake timing (`dp_start_o`/`dp_done_i`, `commit_valid`/`commit_kill`) looks the way the shell's FSM description in `Architecture_and_Internals.md` says it should.

If you only change HWExplore-side RTL (not X-HEEP config), you can skip §2.1–2.2 and go straight to rebuilding firmware + the sim.

## 3. Roadmap A: from "works in Verilator" to "fully connected to X-HEEP"

This is the gap between today's standalone harness and a real X-HEEP integration that uses X-HEEP's own tooling end to end. Rough order, each step buildable on the last:

1. **Adopt X-HEEP's own application framework instead of the hand-rolled CRT.** Turn `sw/platforms/xheep/tests/smoke_test` into a real X-HEEP app under `hw/ext_xheep/sw/applications/hwexplore_smoke_test/`, using X-HEEP's linker scripts, startup code, and driver library instead of `sw/platforms/xheep/common/{link.ld,start.S}`. This buys `make app PROJECT=hwexplore_smoke_test` and `make verilator-run-app` for free, and is the single highest-leverage step — it retires the custom CRT and de-risks every future test.
2. **Replace the hand-rolled `build_hwx_sim.sh` with X-HEEP's native `verilator-build` target.** Once HWExplore's RTL is registered as a FuseSoC core (a `.core` file analogous to `hw/ext_xheep/core-v-mini-mcu.core`) that X-HEEP's build includes automatically, `gen_vc.py`'s manual `.vc` filtering goes away entirely — X-HEEP's own FuseSoC run already produces a complete, correct `.vc`. This is the fix for the "every new datapath needs a hardcoded path added to the build script" fragility noted in §2.4.
3. **Decide where `hwx_top.sv`'s logic actually lives long-term.** Today it's an external wrapper that owns the `if_xif` interface instance and instantiates `x_heep_system` itself — effectively a fork of X-HEEP's own top level. The alternative is upstreaming the shell+mux instantiation *inside* `core_v_mini_mcu.sv` behind a config flag (similar to how `cpu_type` already gates CV-X-IF support), so any X-HEEP build can opt into HWExplore without a separate top-level module duplicating X-HEEP's wiring. The wrapper approach is easier short-term (zero upstream changes) but means every `x_heep_system` port change has to be manually mirrored into `hwx_top.sv`/`hwx_top_cv32e20.sv` — worth revisiting once the wrapper has drifted from upstream a few times.
4. **Wire the scratchpad to CV-X-IF's memory channels instead of bypassing them.** `hwx_scratchpad.sv`'s port B is currently only reachable via the mux's stateful command encoding (`CMD_WRITE_ADDR`/`CMD_WRITE_DATA`/`CMD_START`, funct3 0–2) — CV-X-IF's actual Memory and Memory-Result channels are tied off and unused. Algorithms that need real array-indexed state (NTT, anything beyond two 32-bit operands) will eventually want the real memory channel, not a funct3-encoded side channel.
5. **First real FPGA bring-up.** Pick one board X-HEEP already supports (`pynq-z2` is the most commonly used in X-HEEP's own docs) and run `make vivado-fpga FPGA_BOARD=pynq-z2` against a build that includes `hwx_top.sv`. Expect this to surface timing and resource issues Verilator can't — `hwx_mux.sv`'s per-datapath instantiation (see §4) is exactly the kind of thing that looks fine in sim and burns LUTs/DSPs on real hardware. This is also where the README's planned PPA benchmarking harness (Yosys/X-HEEP's synthesis flow → Fmax/area/LUT numbers) actually starts producing real numbers instead of projections.
6. **Multi-instruction shell pipelining.** `cvxif_hwx_shell.sv`'s FSM handles exactly one in-flight instruction (`IDLE → WAIT_COMMIT → WAIT_DATAPATH → SEND_RESULT`) — a second custom instruction can't issue until the first fully completes. CV-X-IF's instruction `id` field exists precisely to support tagging multiple in-flight instructions; using it is what would let HWExplore-accelerated code actually pipeline instead of serializing every custom instruction.

## 4. Roadmap B: automated resource sharing

This is worth its own section because it's easy to believe it already works — `ResourceAllocator.jl` exists, has tests, and the README even mentions it — but it solves only half the problem.

### 4.1 What exists today

`src/HWGen/ResourceAllocator.jl`'s `schedule_list!(graph, budget)` is **resource-constrained scheduling**: given e.g. `ResourceBudget(:MUL => 1)`, it walks the graph in topological order and delays any `OP_MUL` node whose earliest data-ready cycle would require a second multiplier to be active in the same cycle as another. The result is a schedule where, at any given cycle, no more than `budget[:MUL]` multiplications are *in flight*.

### 4.2 The gap

`VerilogEmitter.jl` does not know `schedule_list!` ran. It emits Verilog by walking every node and generating one combinational expression per node — an `OP_MUL` node becomes one `assign n_comb = a * b;`, full stop, regardless of whether the scheduler proved it never overlaps another multiply in time. So today, a graph with five `OP_MUL` nodes and a budget of `:MUL => 1` gets scheduled correctly in time, but still **synthesizes five separate multiplier instances** — `schedule_list!`'s work never reaches the hardware. The "share hardware, not just schedule around it" half of resource-constrained scheduling doesn't exist yet. (README's roadmap item 6 — "let the scheduler share a limited pool of multipliers/adders ... with automatic mux insertion" — is this exact gap.)

### 4.3 What real resource sharing requires

Concretely, turning a time-multiplexed schedule into actual shared hardware means, per resource class with budget `N`:

1. **Group nodes into "slots".** After `schedule_list!`, partition the nodes in each resource class into `N` groups such that no two nodes in the same group overlap in `[scheduled_cycle, finish_cycle]`. (The scheduler's own bookkeeping in `ResourceTracker.usage` already has everything needed to do this grouping — it's a matter of recording *which* unit index each node was assigned to when `_reserve!` runs, not just that *a* unit was free.)
2. **Instantiate one physical operator per group, not per node.** For a `:MUL` group of 3 nodes sharing 1 physical multiplier, emit a single `assign mul_unit_0 = mul_in_a * mul_in_b;` instead of three.
3. **Insert an input mux selecting operands by cycle/state.** `mul_in_a`/`mul_in_b` need a `case` on the current cycle (for a feed-forward pipeline) or current state (for the FSM backend) that routes in whichever node's operands are "active" that cycle — structurally the same kind of state-keyed `case`/mux the FSM backend (`emit_fsm_verilog` in `VerilogEmitter.jl`) already generates for `OP_REG` state, just keyed by resource slot instead of loop state.
4. **Route the shared unit's output back out per-consumer.** Each node that used to have its own dedicated result wire now needs to latch `mul_unit_0`'s output into its own pipeline register at the cycle it's valid, then proceed exactly as before — downstream consumers shouldn't need to know the value came from shared hardware.
5. **Gate this behind a flag, not a replacement.** The one-operator-per-node path is simpler, correct, and fine when area doesn't matter (example datapaths, anything that fits comfortably); sharing should be an opt-in (`emit_verilog(graph, path; share_resources=budget)` or similar) so existing callers and tests are unaffected.

### 4.4 A concrete starting point

The smallest version of this that would prove the concept: a new `src/HWGen/ResourceSharingEmitter.jl` (or a mode inside `VerilogEmitter.jl`) that takes a graph already scheduled by `schedule_list!`, does step 1's grouping as a post-pass over `ResourceTracker`, and handles **just one resource class at a time** (start with `:MUL`, since it's the one most worth sharing — it's the most area-expensive operator class). A good first test: an `HWGraph` with two independent, non-overlapping `OP_MUL` nodes and `budget = ResourceBudget(:MUL => 1)`; assert the emitted SystemVerilog contains exactly one `*` operator (`count(occursin("*", line) for line in lines) == 1`) and that simulating it against both sets of operands at their respective scheduled cycles gives correct results for both.

## 5. Suggested next steps, in priority order

Pulling §3 and §4 together with what's cheapest to de-risk first:

1. **Fix the `build_hwx_sim.sh` fragility** (§3.2) — register HWExplore's RTL as a FuseSoC core so adding a datapath to the manifest doesn't also require hand-editing the build script's file list. Small, mechanical, immediately reduces a real source of "I added a datapath and the sim silently didn't include it" bugs.
2. **Port `smoke_test` to a real X-HEEP app** (§3.1) — proves the "use X-HEEP's own tooling" path works for at least one program before committing to it for everything.
3. **Prototype single-resource-class sharing** (§4.4) — the `:MUL`-only, two-node proof of concept. This is the piece most likely to change the RTL organization (shared-unit modules probably want their own spot under `hw/rtl/generated/` or a new `hw/rtl/shared/`), so doing it early avoids re-organizing twice.
4. **First FPGA bring-up on one board** (§3.5) — once resource sharing exists even partially, this is when it starts being possible to make real, defensible area/Fmax claims instead of simulation-only ones.
5. **Scratchpad → real CV-X-IF memory channel** (§3.4) and **shell pipelining** (§3.6) — both are independent of the above and can happen in parallel whenever there's bandwidth; neither blocks nor is blocked by the FPGA or resource-sharing work.

## See also

- [`Architecture_and_Internals.md`](Architecture_and_Internals.md) — the CV-X-IF protocol, shell FSM, mux/scratchpad/skid-buffer wiring reference, and the `funct3`/`funct7` dispatch scheme this document assumes you already understand.
- [`Usage_and_Examples.md`](Usage_and_Examples.md) — the Julia-side graph → schedule → emit → simulate workflow for a single standalone datapath (no X-HEEP involved).
- [`Baremetal_and_System_Simulation.md`](Baremetal_and_System_Simulation.md) — the quick-start version of §2 above, plus the X-HEEP-side patches (`BOOT_ADDR`, linker script) this integration currently depends on.
