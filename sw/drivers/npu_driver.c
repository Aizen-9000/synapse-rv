/*
 * Synapse-RV — NPU Driver (baremetal C)
 * Talks to the NPU via memory-mapped CSRs
 *
 * Usage:
 *   npu_load_weights(weights_ptr, num_bytes);
 *   npu_run_inference(tile_count, ACT_RELU, shift=1);
 *   npu_wait_done();
 *   npu_read_output(output_buf, num_bytes);
 */

#include "npu_driver.h"

// ---- NPU CSR base address ----
#define NPU_BASE        0xC0000000UL

// ---- Register offsets ----
#define NPU_CMD         (*(volatile uint32_t*)(NPU_BASE + 0x00))
#define NPU_TILE_CNT    (*(volatile uint32_t*)(NPU_BASE + 0x04))
#define NPU_ACT_CFG     (*(volatile uint32_t*)(NPU_BASE + 0x08))
#define NPU_STATUS      (*(volatile uint32_t*)(NPU_BASE + 0x0C))
#define NPU_WBUF_ADDR   (*(volatile uint32_t*)(NPU_BASE + 0x20))
#define NPU_WBUF_DATA   (*(volatile uint32_t*)(NPU_BASE + 0x24))

// ---- NPU Weight SRAM base ----
#define NPU_WSRAM_BASE  0x00080000UL

// ---- CMD register bits ----
#define NPU_CMD_START   (1 << 0)
#define NPU_CMD_CLEAR   (1 << 1)

// ---- STATUS bits ----
#define NPU_STATUS_BUSY (1 << 0)
#define NPU_STATUS_DONE (1 << 1)

// ---- Activation modes ----
#define NPU_ACT_LINEAR  0
#define NPU_ACT_RELU    1
#define NPU_ACT_RELU6   2

/*
 * npu_reset — clear the NPU and wait for idle
 */
void npu_reset(void) {
    NPU_CMD = NPU_CMD_CLEAR;
    for (volatile int i = 0; i < 100; i++);  // wait ~100 cycles
    NPU_CMD = 0;
}

/*
 * npu_load_weights — DMA weights into the NPU weight SRAM
 * weights : pointer to int8 weight array (must be 8-byte aligned)
 * num_bytes: total bytes (max 256KB = 262144)
 */
int npu_load_weights(const int8_t *weights, uint32_t num_bytes) {
    if (num_bytes > 262144) return -1;   // overflow check

    uint32_t num_words = (num_bytes + 7) / 8;   // round up to 64-bit words
    const uint64_t *src = (const uint64_t*)weights;

    for (uint32_t i = 0; i < num_words; i++) {
        NPU_WBUF_ADDR = i;
        // Write 64 bits = 8 int8 weights (packed)
        // Hardware packs 8 weights per 64-bit word (weight[7:0..63:56])
        NPU_WBUF_DATA = (uint32_t)(src[i] & 0xFFFFFFFF);       // low 32
        NPU_WBUF_ADDR = i;
        NPU_WBUF_DATA = (uint32_t)((src[i] >> 32) & 0xFFFFFFFF); // high 32
    }
    return 0;
}

/*
 * npu_configure_activation — set activation function and requant shift
 * act_mode : NPU_ACT_LINEAR / NPU_ACT_RELU / NPU_ACT_RELU6
 * shift     : right-shift amount for int32→int8 requantization (typically 1–8)
 */
void npu_configure_activation(uint8_t act_mode, uint8_t shift) {
    NPU_ACT_CFG = ((uint32_t)shift << 8) | (act_mode & 0x3);
}

/*
 * npu_run_inference — kick off inference
 * tile_count : number of 8×8 matrix tiles to process
 */
void npu_run_inference(uint16_t tile_count) {
    NPU_TILE_CNT = tile_count;
    NPU_CMD      = NPU_CMD_START;
}

/*
 * npu_wait_done — poll until NPU completes (or timeout)
 * Returns 0 on success, -1 on timeout
 */
int npu_wait_done(uint32_t timeout_cycles) {
    uint32_t t = 0;
    while (!(NPU_STATUS & NPU_STATUS_DONE)) {
        if (++t > timeout_cycles) return -1;
    }
    NPU_CMD = 0;  // clear start bit
    return 0;
}

/*
 * npu_is_busy — non-blocking status check
 */
int npu_is_busy(void) {
    return (NPU_STATUS & NPU_STATUS_BUSY) ? 1 : 0;
}

/*
 * npu_tiles_completed — how many tiles finished
 */
uint16_t npu_tiles_completed(void) {
    return (uint16_t)((NPU_STATUS >> 2) & 0xFFFF);
}

/*
 * npu_read_output — read inference output from NPU output buffer
 * out      : destination int32 array
 * num_words: number of 32-bit words to read
 */
void npu_read_output(int32_t *out, uint32_t num_words) {
    volatile uint32_t *obuf = (volatile uint32_t*)(NPU_BASE + 0x40);
    for (uint32_t i = 0; i < num_words; i++)
        out[i] = (int32_t)obuf[i];
}

/*
 * npu_irq_handler — wire to M-mode external interrupt (mtvec)
 * Call from your trap_handler when mcause == 0x8000000B
 */
volatile uint8_t npu_done_flag = 0;
void npu_irq_handler(void) {
    if (NPU_STATUS & NPU_STATUS_DONE) {
        npu_done_flag = 1;
        NPU_CMD = 0;  // clear start
    }
}

/*
 * npu_wait_done_irq — IRQ-driven wait (lower power than polling)
 * Call after npu_run_inference() when IRQ is enabled in mie
 * Returns 0 on success, -1 on timeout
 */
int npu_wait_done_irq(uint32_t timeout_cycles) {
    uint32_t t = 0;
    npu_done_flag = 0;
    while (!npu_done_flag) {
        __asm__ volatile ("wfi");  // sleep until interrupt
        if (++t > timeout_cycles) return -1;
    }
    return 0;
}
