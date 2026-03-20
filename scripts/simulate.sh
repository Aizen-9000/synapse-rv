#!/usr/bin/env bash
# =============================================================================
#  Synapse-RV Simulation Script  v2.0
#  Usage: ./scripts/simulate.sh [pe|npu|soc|uart|all]
# =============================================================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD="$ROOT/build"
mkdir -p "$BUILD"

RTL_NPU="$ROOT/rtl/npu/npu_pe.v $ROOT/rtl/npu/npu_weight_buffer.v \
         $ROOT/rtl/npu/npu_activation.v $ROOT/rtl/npu/npu_ctrl.v \
         $ROOT/rtl/npu/npu_systolic_array.v $ROOT/rtl/npu/npu_top.v"

RTL_ALL="$RTL_NPU \
         $ROOT/rtl/memory/boot_rom.v \
         $ROOT/rtl/memory/generic_sram.v \
         $ROOT/rtl/interconnect/axi4_xbar.v \
         $ROOT/rtl/cpu/cpu_stub.v \
        $ROOT/rtl/periph/uart16550.v \
         $ROOT/rtl/power/pmu.v \
         $ROOT/rtl/vector/rvv_unit.v 
         $ROOT/rtl/dma/dma_engine.v 
         $ROOT/rtl/cache/l2_cache.v 
         $ROOT/rtl/ddr/lpddr4_ctrl.v 
         $ROOT/rtl/pcie/pcie_ctrl.v 
         $ROOT/rtl/usb/usb2_ctrl.v 
         $ROOT/rtl/security/aes/src/rtl/aes_sbox.v 
         $ROOT/rtl/security/aes/src/rtl/aes_inv_sbox.v 
         $ROOT/rtl/security/aes/src/rtl/aes_key_mem.v 
         $ROOT/rtl/security/aes/src/rtl/aes_encipher_block.v 
         $ROOT/rtl/security/aes/src/rtl/aes_decipher_block.v 
         $ROOT/rtl/security/aes/src/rtl/aes_core.v 
         $ROOT/rtl/security/aes/src/rtl/aes.v 
         $ROOT/rtl/security/sha256/src/rtl/sha256_k_constants.v 
         $ROOT/rtl/security/sha256/src/rtl/sha256_w_mem.v 
         $ROOT/rtl/security/sha256/src/rtl/sha256_core.v 
         $ROOT/rtl/security/sha256/src/rtl/sha256.v 
         $ROOT/rtl/security/sha3/src/rtl/sha3_core.v 
         $ROOT/rtl/security/sha3/src/rtl/sha3.v 
         $ROOT/rtl/security/sec_top.v \
         $ROOT/rtl/soc/synapse_rv_soc.v"

IVFLAGS="-g2012 -DSIMULATION"

# Auto-generate boot_rom.hex if missing
if [ ! -f "$BUILD/boot_rom.hex" ]; then
    echo "[sim] Generating boot_rom.hex..."
    python3 - <<'PYEOF'
import os
build_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build')
os.makedirs(build_dir, exist_ok=True)
# Minimal RISC-V boot stub: jump to itself (infinite loop at 0xFFFF0000)
# j 0  → auipc x0,0 + jalr x0,0(x0) or just: jal x0,0 = 0x0000006F
insns = [0x0000006F] * 16384
with open(os.path.join(build_dir, 'boot_rom.hex'), 'w') as f:
    for ins in insns:
        f.write(f'{ins:08x}\n')
print(f"[sim] boot_rom.hex written ({len(insns)} words)")
PYEOF
fi

run_pe() {
    echo ""
    echo "===== NPU PE Testbench ====="
    iverilog $IVFLAGS \
        $ROOT/rtl/npu/npu_pe.v \
        $ROOT/sim/npu_pe_tb.v \
        -o "$BUILD/sim_pe"
    cd "$BUILD" && vvp sim_pe
    echo ""
}

run_npu() {
    echo ""
    echo "===== NPU System Testbench ====="
    iverilog $IVFLAGS \
        $RTL_NPU \
        $ROOT/rtl/memory/generic_sram.v \
        $ROOT/sim/npu_system_tb.v \
        -o "$BUILD/sim_npu"
    cd "$BUILD" && vvp sim_npu
    echo ""
}

run_uart() {
    echo ""
    echo "===== UART16550 Standalone Testbench ====="
    iverilog $IVFLAGS \
        $ROOT/rtl/periph/uart16550.v \
        $ROOT/sim/uart_tb.v \
        -o "$BUILD/sim_uart"
    cd "$BUILD" && vvp sim_uart
    echo ""
}

run_soc() {
    echo ""
    echo "===== Full SoC Testbench ====="
    # Copy boot_rom.hex to wherever iverilog will find it (cwd = build)
    cp "$BUILD/boot_rom.hex" "$BUILD/boot_rom.hex" 2>/dev/null || true
    iverilog $IVFLAGS \
        -I"$ROOT/rtl/npu" \
        -I"$ROOT/rtl/memory" \
        -I"$ROOT/rtl/interconnect" \
        -I"$ROOT/rtl/cpu" \
        -I"$ROOT/rtl/power" \
        -I"$ROOT/rtl/security" \
        -I"$ROOT/rtl/periph" \
        -I"$ROOT/rtl/soc" \
        $RTL_ALL \
        $ROOT/sim/soc_tb.v \
        -o "$BUILD/sim_soc"
    cd "$BUILD" && vvp sim_soc
    echo ""
}

TARGET="${1:-all}"
case "$TARGET" in
    pe)   run_pe ;;
    npu)  run_npu ;;
    uart) run_uart ;;
    soc)  run_soc ;;
    all)  run_pe; run_npu; run_uart; run_soc ;;
    *)    echo "Usage: $0 [pe|npu|uart|soc|all]"; exit 1 ;;
esac

echo "[sim] Done. Waveforms in: $BUILD/"
echo "[sim] View with: gtkwave $BUILD/soc_waves.vcd"
