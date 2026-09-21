#!/usr/bin/env bash
# scripts/xheep_env.sh
#
# Sets up the shell environment needed for X-HEEP + HWExplore work:
#   - X-HEEP's own Python venv (hjson, fusesoc) ahead of any conda env on PATH
#   - RISCV_XHEEP / COMPILER_PREFIX, so `make mcu-gen` can build X-HEEP's BootROM
#   - RISCV_PREFIX, so sw/platforms/xheep/tests/ can cross-compile firmware
#
# Usage: source this file, don't execute it — it needs to modify YOUR shell's
# environment, not a subshell's.
#
#   source scripts/xheep_env.sh
#
# Every blocker this works around is documented in detail in
# docs/Baremetal_and_System_Simulation.md §5 — read that if something here
# still doesn't work on your machine.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "[xheep_env] This script must be sourced, not executed:" >&2
    echo "  source scripts/xheep_env.sh" >&2
    exit 1
fi

_XHEEP_ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_XHEEP_ENV_ROOT="$(cd "$_XHEEP_ENV_SCRIPT_DIR/.." && pwd)"

# 1. X-HEEP's own venv (hjson, fusesoc) — ahead of PATH so an active conda
#    env (e.g. the `base` env most shells auto-activate) can't shadow it.
_XHEEP_VENV="$_XHEEP_ENV_ROOT/hw/ext_xheep/.venv/bin"
if [ -d "$_XHEEP_VENV" ]; then
    export PATH="$_XHEEP_VENV:$PATH"
    echo "[xheep_env] PATH += $_XHEEP_VENV"
else
    echo "[xheep_env] WARNING: $_XHEEP_VENV not found — is the X-HEEP submodule initialized?" >&2
fi

# 2. RISC-V toolchain. Checked in order; first match wins. Override by
#    exporting RISCV_XHEEP yourself before sourcing this script.
if [ -z "$RISCV_XHEEP" ]; then
    for _candidate in "$HOME/.local/riscv-corev" "$HOME/riscv-corev" "$HOME/.riscv" /opt/riscv-corev; do
        if [ -x "$_candidate/bin/riscv32-corev-elf-gcc" ] || [ -x "$_candidate/bin/riscv-none-elf-gcc" ]; then
            export RISCV_XHEEP="$_candidate"
            break
        fi
    done
fi

if [ -n "$RISCV_XHEEP" ]; then
    if [ -x "$RISCV_XHEEP/bin/riscv32-corev-elf-gcc" ]; then
        export COMPILER_PREFIX="riscv32-corev-"
        export RISCV_PREFIX="$RISCV_XHEEP/bin/riscv32-corev-elf-"
    elif [ -x "$RISCV_XHEEP/bin/riscv-none-elf-gcc" ]; then
        export COMPILER_PREFIX="riscv-none-"
        export RISCV_PREFIX="$RISCV_XHEEP/bin/riscv-none-elf-"
    fi
    echo "[xheep_env] RISCV_XHEEP=$RISCV_XHEEP"
    echo "[xheep_env] RISCV_PREFIX=$RISCV_PREFIX"
else
    cat >&2 <<'EOF'
[xheep_env] WARNING: no RISC-V toolchain found in ~/.local/riscv-corev, ~/riscv-corev,
~/.riscv, or /opt/riscv-corev, and RISCV_XHEEP isn't already set.

Both `make mcu-gen` (X-HEEP's own BootROM build) and sw/platforms/xheep/tests/
(HWExplore's firmware) need one. Install the CORE-V OpenHW GCC toolchain X-HEEP's
own CI uses:

  mkdir -p ~/.local/riscv-corev
  curl -L "https://buildbot.embecosm.com/job/corev-gcc-ubuntu2204/47/artifact/corev-openhw-gcc-ubuntu2204-20240530.tar.gz" \
    | tar -xz -C ~/.local/riscv-corev --strip-components=1

then re-source this script.
EOF
fi

unset _XHEEP_ENV_SCRIPT_DIR _XHEEP_ENV_ROOT _XHEEP_VENV _candidate
