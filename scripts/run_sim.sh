#!/usr/bin/env bash
# Portable single-run XSim driver for a CPU_Lab2-style repository.
# Usage:
#   run_sim.sh [--repo /path/to/CPU_Lab2] <prog> <config> [extra defines...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

find_repo() {
    if [ -n "${CACHE_LAB_REPO:-}" ]; then
        printf '%s\n' "${CACHE_LAB_REPO}"
        return 0
    fi
    local d="$(pwd)"
    while true; do
        if [ -d "${d}/rtl" ] && [ -d "${d}/tb" ] && [ -d "${d}/programs" ]; then
            printf '%s\n' "${d}"
            return 0
        fi
        [ "${d}" = "/" ] && break
        d="$(dirname "${d}")"
    done
    return 1
}

ROOT=""
if [ "${1:-}" = "--repo" ]; then
    ROOT="$2"
    shift 2
fi
if [ -z "${ROOT}" ]; then
    ROOT="$(find_repo)" || {
        echo "Cannot locate CPU_Lab2-style repo. Run from the project root or pass --repo /path/to/CPU_Lab2." >&2
        exit 2
    }
fi
ROOT="$(cd "${ROOT}" && pwd)"

if [ $# -lt 2 ]; then
    echo "Usage: $0 [--repo /path/to/CPU_Lab2] <prog> <config> [extra defines...]" >&2
    exit 2
fi

PROG="$1"
CONFIG="$2"
shift 2 || true
EXTRA_DEFS=("$@")

BUILD="${ROOT}/build/sim/${CONFIG}/${PROG}"
mkdir -p "${BUILD}" "${ROOT}/build"
cd "${BUILD}"

# Source Vivado settings if xvlog isn't on PATH yet.
if ! command -v xvlog >/dev/null 2>&1; then
    if [ -f /home/soleil/tools/Xilinx/Vivado/2022.2/settings64.sh ]; then
        # shellcheck disable=SC1091
        source /home/soleil/tools/Xilinx/Vivado/2022.2/settings64.sh
    elif [ -f /home/soleil/tools/Xilinx/Vivado/2020.1/settings64.sh ]; then
        # shellcheck disable=SC1091
        source /home/soleil/tools/Xilinx/Vivado/2020.1/settings64.sh
    fi
fi

# Assemble program if needed. Use the bundled assembler so the Skill package
# does not depend on a scripts/ directory inside the target repo.
MEM="${ROOT}/build/${PROG}.mem"
if [ ! -f "${MEM}" ] || [ "${ROOT}/programs/${PROG}.S" -nt "${MEM}" ]; then
    python3 "${SCRIPT_DIR}/assemble.py" "${ROOT}/programs/${PROG}.S" -o "${MEM}" -l "${ROOT}/build/${PROG}.lst"
fi

DATA="${ROOT}/programs/${PROG}.dmem"
[ -f "${DATA}" ] || DATA=""
EXPECT="${ROOT}/programs/${PROG}.expect"
[ -f "${EXPECT}" ] || EXPECT=""

case "${PROG}" in
    matmul_*)
        DATA="${ROOT}/programs/matmul.dmem"
        EXPECT="${ROOT}/programs/matmul.expect"
        ;;
esac

DEFINES=()
case "${CONFIG}" in
    nocache)         DEFINES+=("--define" "CONFIG_NOCACHE") ;;
    l1|l1_*)         DEFINES+=("--define" "CONFIG_L1")      ;;
    l2|l2_*)         DEFINES+=("--define" "CONFIG_L2")      ;;
    sweep_*)         DEFINES+=("--define" "CONFIG_L1")      ;;
    *)               DEFINES+=("--define" "CONFIG_L1")      ;;
esac

for d in "${EXTRA_DEFS[@]:-}"; do
    [ -n "$d" ] && DEFINES+=("--define" "$d")
done

RTL_FILES=(
    "${ROOT}/rtl/alu.v"
    "${ROOT}/rtl/regfile.v"
    "${ROOT}/rtl/control_unit.v"
    "${ROOT}/rtl/forward_unit.v"
    "${ROOT}/rtl/hazard_unit.v"
    "${ROOT}/rtl/riscv_core.v"
    "${ROOT}/rtl/perf_counters.v"
    "${ROOT}/rtl/main_memory.v"
    "${ROOT}/rtl/l1_icache.v"
    "${ROOT}/rtl/l1_dcache.v"
    "${ROOT}/rtl/l2_cache.v"
    "${ROOT}/rtl/mem_arbiter.v"
    "${ROOT}/rtl/bypass_port.v"
    "${ROOT}/rtl/riscv_cached_soc.v"
    "${ROOT}/rtl/riscv_nocache_soc.v"
    "${ROOT}/tb/tb_cache_soc.v"
)

xvlog -nolog "${DEFINES[@]}" "${RTL_FILES[@]}" >xvlog.log 2>&1
xelab -nolog -timescale 1ns/1ps tb_cache_soc -s tb_cache_soc.snap >xelab.log 2>&1

case "${PROG}" in
    matmul_*) MAX=800000000 ;;
    array_*)  MAX=10000000  ;;
    *)        MAX=2000000    ;;
esac

PLUSARGS=(
    --testplusarg "MEM=${MEM}"
    --testplusarg "RESULTS=${BUILD}/results.json"
    --testplusarg "MAX_CYCLES=${MAX}"
)
[ -n "${DATA}"   ] && PLUSARGS+=(--testplusarg "DATA=${DATA}")
[ -n "${EXPECT}" ] && PLUSARGS+=(--testplusarg "EXPECT=${EXPECT}")
[ -n "${BASELINE_CYCLES:-}" ] && PLUSARGS+=(--testplusarg "BASELINE_CYCLES=${BASELINE_CYCLES}")
[ -n "${VCD:-}" ] && PLUSARGS+=(--testplusarg "VCD")

xsim -nolog -runall "${PLUSARGS[@]}" tb_cache_soc.snap >xsim.log 2>&1 || true

if [ -n "${VCD:-}" ] && [ -f "trace.vcd" ]; then
    mv trace.vcd "${VCD}"
fi

echo "==== ${CONFIG} ${PROG} ===="
sed -n '/SIM SUMMARY/,/===/p' xsim.log
echo
