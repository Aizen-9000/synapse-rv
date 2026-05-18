#!/usr/bin/env bash
# =============================================================================
#  Synapse-RV — Yosys Standalone Synthesis (without OpenLane)
#  Produces: netlist, area report, statistics
#  Usage: ./scripts/yosys_synth.sh [npu_pe|npu_top|soc]
#  Install: sudo apt install yosys  (or brew install yosys on macOS)
# =============================================================================
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-npu_pe}"
BUILD="$ROOT/build/syn"
mkdir -p "$BUILD"

case "$TARGET" in
  npu_pe)
    TOP="npu_pe"
    SRCS="$ROOT/rtl/npu/npu_pe.v"
    ;;
  npu_top)
    TOP="npu_top"
    SRCS="$ROOT/rtl/npu/npu_pe.v $ROOT/rtl/npu/npu_systolic_array.v \
          $ROOT/rtl/npu/npu_weight_buffer.v $ROOT/rtl/npu/npu_activation.v \
          $ROOT/rtl/npu/npu_ctrl.v $ROOT/rtl/npu/npu_top.v \
          $ROOT/rtl/memory/generic_sram.v"
    ;;
  soc)
    TOP="synapse_rv_soc"
    SRCS="$ROOT/rtl/npu/npu_pe.v $ROOT/rtl/npu/npu_systolic_array.v \
          $ROOT/rtl/npu/npu_weight_buffer.v $ROOT/rtl/npu/npu_activation.v \
          $ROOT/rtl/npu/npu_ctrl.v $ROOT/rtl/npu/npu_top.v \
          $ROOT/rtl/memory/boot_rom.v $ROOT/rtl/memory/generic_sram.v \
          $ROOT/rtl/interconnect/axi4_xbar.v $ROOT/rtl/cpu/cpu_stub.v \
          $ROOT/rtl/power/pmu.v $ROOT/rtl/security/sec_top.v \
          $ROOT/rtl/periph/uart16550.v $ROOT/rtl/soc/synapse_rv_soc.v"
    ;;
  *) echo "Usage: $0 [npu_pe|npu_top|soc]"; exit 1 ;;
esac

SCRIPT_FILE="$BUILD/${TARGET}_synth.ys"

cat > "$SCRIPT_FILE" << YS
# Yosys synthesis script — $TARGET
# Read RTL
$(for f in $SRCS; do echo "read_verilog -sv $f"; done)

# Synthesize
synth -top $TOP -flatten
# Technology map to generic gates (swap 'synth' for 'synth_xilinx' for FPGA)
# For Sky130: use synth_sky130 if openlane stdlib is loaded
abc -g aig
# Clean up
clean
# Reports
stat -tech cmos
check
tee -o $BUILD/${TARGET}_area.rpt stat
# Write netlist
write_verilog -noattr $BUILD/${TARGET}_netlist.v
write_json    $BUILD/${TARGET}_netlist.json
YS

echo "======================================================"
echo "  Running Yosys synthesis: $TARGET"
echo "======================================================"
yosys -l "$BUILD/${TARGET}_synth.log" "$SCRIPT_FILE"
echo ""
echo "Outputs:"
echo "  Netlist : $BUILD/${TARGET}_netlist.v"
echo "  Area    : $BUILD/${TARGET}_area.rpt"
echo "  Log     : $BUILD/${TARGET}_synth.log"
