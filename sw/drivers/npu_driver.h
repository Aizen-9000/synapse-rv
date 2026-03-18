/*
 * Synapse-RV NPU Driver Header
 */
#ifndef NPU_DRIVER_H
#define NPU_DRIVER_H

#include <stdint.h>

#define NPU_ACT_LINEAR  0
#define NPU_ACT_RELU    1
#define NPU_ACT_RELU6   2

void    npu_reset(void);
int     npu_load_weights(const int8_t *weights, uint32_t num_bytes);
void    npu_configure_activation(uint8_t act_mode, uint8_t shift);
void    npu_run_inference(uint16_t tile_count);
int     npu_wait_done(uint32_t timeout_cycles);
int     npu_is_busy(void);
uint16_t npu_tiles_completed(void);

#endif

void     npu_read_output(int32_t *out, uint32_t num_words);
void     npu_irq_handler(void);
int      npu_wait_done_irq(uint32_t timeout_cycles);
extern volatile uint8_t npu_done_flag;
