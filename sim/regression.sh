#!/usr/bin/env bash
# =============================================================================
#  Synapse-RV — Full Regression Suite
#  Runs all testbenches, collects pass/fail, exits non-zero on any failure.
#  CI/CD entry point — wire this to GitHub Actions / Jenkins.
#  Usage: ./sim/regression.sh
# =============================================================================
set -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"
PASS=0; FAIL=0; ERRORS=()

run_tb() {
    local name="$1"; shift
    local srcs=("$@")
    echo ""
    echo "─────────────────────────────────────────"
    echo "  TB: $name"
    echo "─────────────────────────────────────────"
    if ! iverilog -g2012 -DSIMULATION -I"$ROOT/rtl/npu" \
         "${srcs[@]}" -o "$BUILD/sim_${name}" 2>&1; then
        echo "[FAIL] $name — COMPILE ERROR"
        FAIL=$((FAIL+1)); ERRORS+=("$name: compile failed"); return
    fi
    local out
    out=$(cd "$BUILD" && vvp "sim_${name}" 2>&1)
    echo "$out"
    local p f
    p=$(echo "$out" | grep -c '\[PASS\]' || true)
    f=$(echo "$out" | grep -c '\[FAIL\]' || true)
    PASS=$((PASS+p)); FAIL=$((FAIL+f))
    if [ "$f" -gt 0 ]; then ERRORS+=("$name: $f test(s) failed"); fi
}

# Generate boot ROM hex
python3 - <<'PY'
import os
words = [0x0000006F] * 16384
with open(os.path.join(os.environ.get('BUILD','build'), 'boot_rom.hex'), 'w') as f:
    [f.write(f'{w:08x}\n') for w in words]
PY

RTL_NPU="$ROOT/rtl/npu/npu_pe.v $ROOT/rtl/npu/npu_systolic_array.v \
         $ROOT/rtl/npu/npu_weight_buffer.v $ROOT/rtl/npu/npu_activation.v \
         $ROOT/rtl/npu/npu_ctrl.v $ROOT/rtl/npu/npu_top.v \
         $ROOT/rtl/memory/generic_sram.v"
RTL_SOC="$RTL_NPU $ROOT/rtl/memory/boot_rom.v \
         $ROOT/rtl/interconnect/axi4_xbar.v $ROOT/rtl/cpu/cpu_stub.v \
         $ROOT/rtl/power/pmu.v $ROOT/rtl/security/sec_top.v \
         $ROOT/rtl/periph/uart16550.v $ROOT/rtl/soc/synapse_rv_soc.v"

run_tb npu_pe    $ROOT/rtl/npu/npu_pe.v              $ROOT/sim/npu_pe_tb.v
run_tb npu_sys   $RTL_NPU                             $ROOT/sim/npu_system_tb.v
run_tb uart      $ROOT/rtl/periph/uart16550.v         $ROOT/sim/uart_tb.v
run_tb soc       $RTL_SOC                             $ROOT/sim/soc_tb.v

echo ""
echo "═══════════════════════════════════════════"
echo "  REGRESSION RESULTS"
echo "  Total PASS: $PASS"
echo "  Total FAIL: $FAIL"
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "  Failures:"
    for e in "${ERRORS[@]}"; do echo "    ✗ $e"; done
fi
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
