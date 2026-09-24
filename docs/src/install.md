# Installation

HWExplore has three independent tiers of tooling, needed for different things. **You only need the first one to start describing and generating hardware** — the rest are for simulating it.

| Tier | Needed for | Requirement |
|---|---|---|
| 1. Julia package | Writing a DFG, scheduling, emitting `.sv` | Julia 1.9+ and this package's dependencies |
| 2. Standalone RTL simulation | Testing one generated datapath with Verilator | Verilator, a C++ compiler |
| 3. Full X-HEEP integration | Running generated hardware inside a real RISC-V SoC | The X-HEEP submodule, a RISC-V toolchain, Python (`hjson`, `fusesoc`) |

## Tier 1: the Julia package

Clone the repository (X-HEEP is vendored as a submodule — you need it initialized even if you're only using Tier 1, since the package's tests reference it):

```bash
git clone --recurse-submodules <repository-url>
cd HWExplore
```

Instantiate the project's own environment (this reads `Project.toml` at the repository root, *not* `docs/Project.toml`):

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

That resolves `DataStructures`, `GPUCompiler`, `IRTools`, `LLVM`, and `MacroTools` — the whole Julia-side dependency set. Confirm it loads:

```bash
julia --project=. -e 'using HWExplore; println("HWExplore loaded OK")'
```

A successful run prints each registered primitive (`PrimitiveLibrary] Registered :simd_mac → hwx_simd_mac ...`) followed by `HWExplore loaded OK`. If you're developing HWExplore itself (not just using it), `Pkg.develop(path=".")` from another project's environment points that project at this checkout instead of a registered version.

Run the test suite to confirm the whole toolchain (scheduler, emitter, resource sharing, macros, FSM backend, IR translation) works on your machine:

```bash
julia --project=. tests/runtests.jl
```

## Tier 2: standalone RTL simulation with Verilator

Needed to actually run a generated `.sv` file, not just produce it.

```bash
julia --version      # 1.9+
verilator --version  # 5.x recommended
g++ --version        # or clang++
make --version
```

On Fedora/RHEL: `dnf install verilator gcc-c++ make`. On Debian/Ubuntu: `apt install verilator g++ make`. GTKWave (optional) for waveform inspection: `dnf install gtkwave` / `apt install gtkwave`.

Verify with the existing primitive testbenches:

```bash
cd hw/tb_veril
make test_all
```

This builds and runs every hand-written primitive's Verilator testbench plus the vector-dot-product examples — expect a string of `ALL ... TESTS PASSED` lines. See the [Guide to Using HWExplore](@ref) for how to test something you generate yourself.

## Tier 3: full X-HEEP integration

This is the tier with real setup cost, because it depends on tooling HWExplore doesn't control (X-HEEP's own build system, a RISC-V cross-compiler, FuseSoC). The fast path:

```bash
source scripts/xheep_env.sh
```

This auto-detects a RISC-V toolchain in a handful of common install locations and sets up X-HEEP's own Python virtual environment on `PATH` ahead of any conda environment that might otherwise shadow it. **Run it in every new shell** — like any environment-variable setup, it doesn't persist across terminal sessions on its own.

If it can't find a toolchain, it prints exactly how to install one (the CORE-V OpenHW GCC toolchain that X-HEEP's own CI uses, installable with no root access via a direct download). From there:

```bash
cd hw/ext_xheep
make mcu-gen        # regenerate X-HEEP's MCU sources for the configured CPU
cd ../..
make -C sw/platforms/xheep/tests       # cross-compile the bare-metal firmware
bash sw/platforms/xheep/sim/build_hwx_sim.sh   # build the full-system Verilator simulation
./sw/platforms/xheep/sim/obj_dir/Vtb_hwx_system +firmware=sw/platforms/xheep/tests/smoke_test/main.hex
```

A correct run ends in `EXIT SUCCESS`. **This tier has the most moving parts and the least forgiving failure modes** — most first-time setup problems (a Python environment picked up by X-HEEP's Makefile instead of its own venv, a toolchain silently mis-detected, a CV-X-IF config flag that's easy to miss) are documented, in the order you'll hit them, with the exact error text each one produces, in `docs/Baremetal_and_System_Simulation.md` §5 — read that section before assuming something is broken.

## Building this documentation locally

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Output goes to `docs/build/`; open `docs/build/index.html` in a browser. `docs/make.jl` adds the repository root to `LOAD_PATH` itself, so this works against an uninstalled, uncommitted local checkout — no separate `Pkg.develop` step needed first.
