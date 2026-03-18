/* =============================================================================
 * Synapse-RV — Bare-Metal Linker Script
 * Memory Map:
 *   Boot ROM : 0xFFFF_0000  (64KB, read-only, execute-in-place)
 *   SRAM     : 0x0000_0000  (512KB, .data + .bss + stack + heap)
 *   NPU CSR  : 0xC000_0000  (memory-mapped, no sections)
 *   UART     : 0xF000_0000  (memory-mapped, no sections)
 * ============================================================================= */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    ROM  (rx)  : ORIGIN = 0xFFFF0000, LENGTH = 64K
    SRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 512K
}

SECTIONS {
    /* ---- Code lives in Boot ROM ---- */
    .text : {
        KEEP(*(.text.boot))     /* _start must be first */
        *(.text*)
        *(.rodata*)
    } > ROM

    /* ---- Initialized data — loaded from ROM, runs in SRAM ---- */
    .data : AT(ADDR(.text) + SIZEOF(.text)) {
        __data_start = .;
        *(.data*)
        __data_end = .;
    } > SRAM

    __data_load = LOADADDR(.data);

    /* ---- Zero-initialized BSS ---- */
    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > SRAM

    /* ---- Stack (grows downward from top of SRAM) ---- */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        _stack_bottom = .;
        . += 8K;
        _stack_top = .;
    } > SRAM

    /* ---- Heap (remaining SRAM after stack) ---- */
    .heap (NOLOAD) : {
        _heap_start = .;
        . = ORIGIN(SRAM) + LENGTH(SRAM) - 0x200; /* leave 512B guard */
        _heap_end = .;
    } > SRAM
}
