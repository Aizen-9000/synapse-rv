#ifndef INFERENCE_H
#define INFERENCE_H
#include <stdint.h>

int synapse_matmul(
    const int8_t  *A, uint32_t M, uint32_t K,
    const int8_t  *B,             uint32_t N,
          int32_t *C,
    uint8_t act_mode, uint8_t shift
);

int synapse_conv2d(
    const int8_t *input,   uint32_t H, uint32_t W, uint32_t C_in,
    const int8_t *weights, uint32_t C_out, uint32_t kH, uint32_t kW,
          int8_t *output,
    uint32_t stride, uint32_t pad,
    uint8_t act_mode, uint8_t shift
);

#endif

int  synapse_attention_qk(
    const int8_t  *Q, uint32_t seq_len, uint32_t d_k,
    const int8_t  *K,
          int32_t *out,
    uint8_t scale_shift
);
void synapse_softmax(
    const int32_t *in_scores, uint8_t *out_probs,
    uint32_t rows, uint32_t cols
);
