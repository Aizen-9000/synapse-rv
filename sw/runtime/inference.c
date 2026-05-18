/*
 * Synapse-RV — High-level Inference Runtime
 * Sits on top of npu_driver.c
 * Provides a simple API for running int8 neural network layers:
 *
 *   synapse_conv2d(...)
 *   synapse_matmul(...)
 *   synapse_attention_qk(...)   // transformer Q·K^T
 */

#include "inference.h"
#include "npu_driver.h"

/*
 * synapse_matmul — C = A × B (int8, tiled through NPU)
 *
 * A : M×K int8 matrix (activations)
 * B : K×N int8 matrix (weights — must be pre-loaded)
 * C : M×N int32 output
 * M, K, N : dimensions (N must be multiple of 8 for NPU alignment)
 */
int synapse_matmul(
    const int8_t  *A, uint32_t M, uint32_t K,
    const int8_t  *B,             uint32_t N,
          int32_t *C,
    uint8_t act_mode, uint8_t shift
) {
    if (N % 8 != 0 || K % 8 != 0) return -1;  // must be tile-aligned

    uint16_t tiles = (M * K) / 64;   // each tile = one 8×8 MAC pass

    // Load weights
    if (npu_load_weights(B, K * N) != 0) return -2;

    // Configure activation
    npu_configure_activation(act_mode, shift);

    // Run
    npu_run_inference(tiles);

    // Wait with 10M cycle timeout
    if (npu_wait_done(10000000) != 0) return -3;

    return 0;
}

/*
 * synapse_conv2d — 2D convolution (im2col → matmul)
 *
 * This transforms the conv problem into a matrix multiply,
 * then dispatches to the NPU via synapse_matmul.
 *
 * input     : (H, W, C_in) int8 feature map
 * weights   : (C_out, kH, kW, C_in) int8 filter bank
 * output    : (H_out, W_out, C_out) int8 result
 */
int synapse_conv2d(
    const int8_t *input,   uint32_t H,   uint32_t W,   uint32_t C_in,
    const int8_t *weights, uint32_t C_out, uint32_t kH, uint32_t kW,
          int8_t *output,
    uint32_t stride, uint32_t pad,
    uint8_t act_mode, uint8_t shift
) {
    uint32_t H_out = (H + 2*pad - kH) / stride + 1;
    uint32_t W_out = (W + 2*pad - kW) / stride + 1;
    uint32_t K = kH * kW * C_in;   // im2col column height

    // im2col buffer (stack-allocated for small layers; heap for large)
    // For production: use a pre-allocated scratchpad in SRAM
    static int8_t im2col_buf[64 * 64];  // scratchpad

    uint32_t out_pixels = H_out * W_out;
    if (out_pixels * K > sizeof(im2col_buf)) return -1;

    // im2col transform: unroll spatial patches into rows
    uint32_t col = 0;
    for (uint32_t oh = 0; oh < H_out; oh++) {
        for (uint32_t ow = 0; ow < W_out; ow++) {
            for (uint32_t kh = 0; kh < kH; kh++) {
                for (uint32_t kw = 0; kw < kW; kw++) {
                    int32_t ih = (int32_t)(oh * stride + kh) - (int32_t)pad;
                    int32_t iw = (int32_t)(ow * stride + kw) - (int32_t)pad;
                    for (uint32_t ci = 0; ci < C_in; ci++) {
                        int8_t val = 0;
                        if (ih >= 0 && ih < (int32_t)H && iw >= 0 && iw < (int32_t)W)
                            val = input[(ih * W + iw) * C_in + ci];
                        im2col_buf[col++] = val;
                    }
                }
            }
        }
    }

    // Dispatch to NPU matmul: (out_pixels × K) × (K × C_out)
    static int32_t matmul_out[64 * 64];
    int ret = synapse_matmul(
        im2col_buf, out_pixels, K,
        weights,                C_out,
        matmul_out, act_mode, shift
    );
    if (ret != 0) return ret;

    // Copy int32 output → int8 (requant already done by NPU activation unit)
    for (uint32_t i = 0; i < out_pixels * C_out; i++)
        output[i] = (int8_t)(matmul_out[i] & 0xFF);

    return 0;
}

/*
 * synapse_attention_qk — Q·K^T scaled dot-product attention
 *
 * Q : (seq_len, d_k) int8 query matrix
 * K : (seq_len, d_k) int8 key matrix
 * out: (seq_len, seq_len) int32 attention scores (pre-softmax)
 * scale_shift: right-shift to approximate 1/sqrt(d_k)
 *
 * Used in transformer self-attention layers.
 * Softmax must be applied in software after this call.
 */
int synapse_attention_qk(
    const int8_t  *Q, uint32_t seq_len, uint32_t d_k,
    const int8_t  *K,
          int32_t *out,
    uint8_t scale_shift
) {
    if (d_k % 8 != 0 || seq_len % 8 != 0) return -1;

    // Load K as weights (K^T is handled by NPU weight layout)
    if (npu_load_weights(K, seq_len * d_k) != 0) return -2;

    // Linear activation (no clamp — softmax handles it)
    npu_configure_activation(NPU_ACT_LINEAR, scale_shift);

    // tiles = (seq_len * d_k) / 64
    uint16_t tiles = (seq_len * d_k) / 64;
    npu_run_inference(tiles);

    if (npu_wait_done(10000000) != 0) return -3;

    // Read seq_len x seq_len scores
    npu_read_output(out, seq_len * seq_len);
    return 0;
}

/*
 * synapse_softmax — row-wise softmax on int32 attention scores
 * Outputs fixed-point int8 probabilities (scaled to [-128,127])
 * in_scores  : (rows x cols) int32
 * out_probs  : (rows x cols) int8
 */
void synapse_softmax(
    const int32_t *in_scores, uint8_t *out_probs,
    uint32_t rows, uint32_t cols
) {
    for (uint32_t r = 0; r < rows; r++) {
        const int32_t *row = in_scores + r * cols;
        // Find max for numerical stability
        int32_t max_val = row[0];
        for (uint32_t c = 1; c < cols; c++)
            if (row[c] > max_val) max_val = row[c];
        // Approximate exp via bit-shift (2^x approximation)
        uint32_t sum = 0;
        static uint32_t exp_buf[256];
        for (uint32_t c = 0; c < cols; c++) {
            int32_t shifted = (row[c] - max_val) >> 3;
            exp_buf[c] = (shifted >= 0) ? (1u << shifted) :
                         (1u >> (-shifted));
            if (exp_buf[c] == 0) exp_buf[c] = 1;
            sum += exp_buf[c];
        }
        // Normalize to int8
        for (uint32_t c = 0; c < cols; c++)
            out_probs[r * cols + c] = (uint8_t)((exp_buf[c] * 255) / sum);
    }
}
