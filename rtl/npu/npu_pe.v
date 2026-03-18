// =============================================================================
//  Synapse-RV NPU — Processing Element (PE)  v1.0  [VERIFIED - ALL TESTS PASS]
//  The atom of the systolic array. One int8 MAC per clock cycle.
//  accum += in_a * in_b  (int8 × int8 → int32 accumulator)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module npu_pe (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        clear,
    input  wire signed [7:0]  in_a,       // activation input
    input  wire signed [7:0]  in_b,       // weight input
    output reg  signed [7:0]  in_a_out,   // pass right to next PE
    output reg  signed [7:0]  in_b_out,   // pass down to next PE
    output reg  signed [31:0] accum,
    output reg                accum_valid
);
    wire signed [15:0] product = in_a * in_b;

    always @(posedge clk) begin
        if (!rst_n) begin
            accum       <= 32'sd0;
            accum_valid <= 1'b0;
            in_a_out    <= 8'sd0;
            in_b_out    <= 8'sd0;
        end else begin
            in_a_out <= in_a;
            in_b_out <= in_b;
            if (clear) begin
                accum       <= 32'sd0;
                accum_valid <= 1'b0;
            end else if (enable) begin
                accum       <= accum + {{16{product[15]}}, product};
                accum_valid <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
