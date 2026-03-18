# =============================================================================
#  Synapse-RV — Stage-1 Bootloader (RISC-V Assembly)
#  Runs from Boot ROM at 0x0000_0000
#  1. Sets up stack pointer
#  2. Zeros BSS section
#  3. Copies .data from flash to SRAM
#  4. Jumps to C main()
# =============================================================================

.section .text.boot
.globl _start
.option norvc   # disable compressed instructions in boot ROM

_start:
    # Disable all interrupts
    csrw mie, zero
    csrw mip, zero

    # Set up stack pointer (top of SRAM: 0x0007_FFF8)
    lui  sp, 0x8
    addi sp, sp, -8

    # Zero out BSS section
    la   t0, __bss_start
    la   t1, __bss_end
zero_bss:
    beq  t0, t1, bss_done
    sd   zero, 0(t0)
    addi t0, t0, 8
    j    zero_bss
bss_done:

    # Copy .data section from ROM to SRAM
    la   t0, __data_load     # source (ROM)
    la   t1, __data_start    # dest (SRAM)
    la   t2, __data_end
copy_data:
    beq  t1, t2, copy_done
    ld   t3, 0(t0)
    sd   t3, 0(t1)
    addi t0, t0, 8
    addi t1, t1, 8
    j    copy_data
copy_done:

    # Set up trap handler
    la   t0, trap_handler
    csrw mtvec, t0

    # Jump to C runtime
    call main

    # Should never return — halt
halt:
    wfi
    j halt

# Minimal trap handler (for debug — real version would be more complete)
.align 4
trap_handler:
    csrr t0, mcause
    # If it's an interrupt (bit 63 set), return
    bltz t0, trap_return
    # Otherwise: infinite loop (unhandled exception)
    j halt
trap_return:
    mret
