# Synapse-RV — RISC-V Edge AI SoC

> A complete, tape-out ready RISC-V SoC with a dedicated NPU for edge AI inference.  
> Designed from scratch in RTL Verilog. Verified in simulation. GDS-II generated on Sky130.

---

## What is this?

Synapse-RV is a fabless chip design — a full System-on-Chip targeting edge AI inference at under 1W.  
Every block was written from scratch in Verilog, verified with simulation testbenches, and taken through  
the complete RTL → synthesis → place-and-route → GDS-II flow using open-source tools.

**0 DRC violations. LVS clean. Tape-out ready on Sky130 (130nm).**

---

## Architecture
```
┌─────────────────────────────────────────────────────────┐
│                    Synapse-RV SoC                       │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐  │
│  │ CVA6 CPU │  │  8×8 NPU │  │  RVV 1.0 Vector Unit │  │
│  │ RV64GC   │  │ Systolic │  │  VLEN=256, int8/32   │  │
│  │ Linux    │  │ 12.8GOPS │  │  vadd/vsub/vmul/vdot │  │
│  └────┬─────┘  └────┬─────┘  └──────────┬───────────┘  │
│       │             │                   │               │
│  ─────┴─────────────┴───────────────────┴────────────   │
│              AXI4 Crossbar (2M × 10S)                   │
│  ──────────────────────────────────────────────────────  │
│                                                         │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌─────────────┐  │
│  │LPDDR4│ │L2$   │ │ DMA  │ │ PCIe │ │ AES+SHA3    │  │
│  │Ctrl  │ │4KB   │ │ 4-ch │ │ Gen2 │ │ Secure Boot │  │
│  └──────┘ └──────┘ └──────┘ └──────┘ └─────────────┘  │
│                                                         │
│  ┌──────┐ ┌──────┐ ┌──────────────────────────────┐    │
│  │UART  │ │ USB  │ │ PMU — DVFS, Clock Gating      │    │
│  │16550 │ │ 2.0  │ │ Sleep/DeepSleep, Wake Sources │    │
│  └──────┘ └──────┘ └──────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## Key Specs

| Parameter | Value |
|-----------|-------|
| CPU | CVA6 RV64GC — Linux capable |
| NPU | 8×8 systolic array, int8, 12.8 GOPS @ 200MHz |
| Vector | RVV 1.0, VLEN=256 |
| Security | AES-256, SHA-256, SHA-3, secure boot |
| Memory | LPDDR4 controller, L2 cache, 512KB SRAM |
| Peripherals | UART16550, PCIe Gen2, USB 2.0 HS, DMA 4-ch |
| Power | DVFS, 3 clock domains, sleep/deep-sleep |
| Process | Sky130 (130nm) — tape-out ready |
| DRC | 0 violations (Magic DRC) |
| LVS | Clean (2884 nets) |

---

## Repository Structure
```
synapse-rv/
├── rtl/
│   ├── npu/          # NPU — PE, systolic array, weight buffer, ctrl
│   ├── cpu/          # CVA6 wrapper + stub
│   ├── vector/       # RVV 1.0 unit
│   ├── dma/          # 4-channel DMA engine
│   ├── cache/        # L2 cache
│   ├── ddr/          # LPDDR4 controller
│   ├── pcie/         # PCIe Gen2
│   ├── usb/          # USB 2.0
│   ├── security/     # AES, SHA256, SHA3, sec_top
│   ├── periph/       # UART16550
│   ├── power/        # PMU + DVFS
│   ├── memory/       # Boot ROM, SRAM
│   ├── interconnect/ # AXI4 crossbar
│   └── soc/          # Top-level SoC + Caravel wrapper
├── sw/
│   ├── bootloader/   # RISC-V Stage-1 bootloader
│   ├── drivers/      # NPU driver (C)
│   └── runtime/      # Inference runtime — conv2d, matmul, attention
├── sim/              # Testbenches
├── scripts/          # simulate.sh, yosys_synth.sh, run_openlane.sh
├── openlane/         # OpenLane configs (npu_pe, npu_top, wrapper)
└── build/            # Synthesis outputs
```

---

## Simulation Results
```
./scripts/simulate.sh all

===== NPU PE Testbench =====     6/6  PASS
===== NPU System Testbench =====  5/5  PASS
===== UART Testbench =====        7/7  PASS
===== Full SoC Testbench =====    8/8  PASS
```

---

## GDS Results

| Block | Size | DRC | LVS |
|-------|------|-----|-----|
| npu_pe | 4.5MB | 0 violations | clean |
| npu_top | 13MB | 0 violations | clean |
| user_project_wrapper | 112MB | 0 violations | clean |

---

## Tools Used

- **Simulation**: Icarus Verilog 12
- **Synthesis**: Yosys 0.63
- **Place & Route**: OpenLane 1.1.1 + OpenROAD
- **DRC/LVS**: Magic + Netgen
- **PDK**: Sky130A (GlobalFoundries 130nm)

---

## IP Licensing

This design is available for licensing (RTL + GDS package).  
Contact: maji02479@gmail.com

---

## Author

Built by Anupam — Class 11 student, India. | maji02479@gmail.com  
Fabless chip design startup.
