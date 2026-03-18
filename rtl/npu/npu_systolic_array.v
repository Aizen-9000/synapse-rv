// =============================================================================
//  Synapse-RV NPU — 8×8 Systolic Array  v1.0  [VERIFIED]
//  64 PEs. Activations flow right, weights flow down.
//  Peak: 64 MACs/cycle × 200 MHz = 12.8 GOPS (int8)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module npu_systolic_array #(
    parameter ROWS    = 8,
    parameter COLS    = 8,
    parameter DATA_W  = 8,
    parameter ACCUM_W = 32
)(
    input  wire                                clk,
    input  wire                                rst_n,
    input  wire                                enable,
    input  wire                                clear,
    // Packed inputs: one activation per row, one weight per col
    input  wire signed [DATA_W*ROWS-1:0]       in_a_flat,
    input  wire signed [DATA_W*COLS-1:0]       in_b_flat,
    // Packed outputs: all 64 accumulators
    output wire signed [ACCUM_W*ROWS*COLS-1:0] accum_flat,
    output wire        [ROWS*COLS-1:0]         accum_valid_flat
);
    // Systolic wire grid
    wire signed [DATA_W-1:0]  a_wire [0:ROWS-1][0:COLS];
    wire signed [DATA_W-1:0]  b_wire [0:ROWS][0:COLS-1];
    wire signed [ACCUM_W-1:0] accum_w [0:ROWS-1][0:COLS-1];
    wire                      valid_w [0:ROWS-1][0:COLS-1];

    // Connect boundary inputs
    genvar gi;
    generate
        for (gi = 0; gi < ROWS; gi = gi+1)
            assign a_wire[gi][0] = in_a_flat[gi*DATA_W +: DATA_W];
        for (gi = 0; gi < COLS; gi = gi+1)
            assign b_wire[0][gi] = in_b_flat[gi*DATA_W +: DATA_W];
    endgenerate

    // Instantiate 8×8 PE grid
    genvar row, col;
    generate
        for (row = 0; row < ROWS; row = row+1) begin : GEN_ROW
            for (col = 0; col < COLS; col = col+1) begin : GEN_COL
                npu_pe pe_i (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .enable     (enable),
                    .clear      (clear),
                    .in_a       (a_wire[row][col]),
                    .in_b       (b_wire[row][col]),
                    .in_a_out   (a_wire[row][col+1]),
                    .in_b_out   (b_wire[row+1][col]),
                    .accum      (accum_w[row][col]),
                    .accum_valid(valid_w[row][col])
                );
                assign accum_flat[(row*COLS+col)*ACCUM_W +: ACCUM_W] = accum_w[row][col];
                assign accum_valid_flat[row*COLS+col] = valid_w[row][col];
            end
        end
    endgenerate
endmodule
`default_nettype wire
