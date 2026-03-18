/*
 * Synapse-RV — Bare-metal main entry point
 * Called by bootloader after BSS zero + data copy
 */
#include "npu_driver.h"
#include "inference.h"

/* Test weights and input — 8x8 int8 identity-like pattern */
static const int8_t test_weights[64] = {
    1,0,0,0,0,0,0,0,  0,1,0,0,0,0,0,0,
    0,0,1,0,0,0,0,0,  0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0,  0,0,0,0,0,1,0,0,
    0,0,0,0,0,0,1,0,  0,0,0,0,0,0,0,1
};

static const int8_t test_input[64] = {
    1,2,3,4,5,6,7,8,  1,2,3,4,5,6,7,8,
    1,2,3,4,5,6,7,8,  1,2,3,4,5,6,7,8,
    1,2,3,4,5,6,7,8,  1,2,3,4,5,6,7,8,
    1,2,3,4,5,6,7,8,  1,2,3,4,5,6,7,8
};

static int32_t output[64];

int main(void) {
    /* Reset NPU */
    npu_reset();

    /* Run 8x8 matmul through NPU */
    synapse_matmul(
        test_input,  8, 8,
        test_weights,    8,
        output,
        NPU_ACT_RELU, 1
    );

    /* Halt — results readable via JTAG/debug */
    while (1) {
        __asm__ volatile ("wfi");
    }
    return 0;
}
