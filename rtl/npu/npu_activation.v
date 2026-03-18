// =============================================================================
//  Synapse-RV NPU — Activation Unit  v1.0  [VERIFIED]
//  Applies ReLU/ReLU6 then requantizes int32 → int8 via arithmetic right-shift
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module npu_activation #(
    parameter N = 64   // 8×8 array outputs
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              valid_in,
    input  wire [1:0]        act_sel,    // 00=linear 01=ReLU 10=ReLU6
    input  wire [7:0]        shift,      // requant right-shift (1–8 typical)
    input  wire signed [32*N-1:0] accum_flat_in,
    output reg  signed [8*N-1:0]  out_flat,
    output reg               valid_out
);
    integer k;
    reg signed [31:0] val, activated, shifted;
    reg signed [7:0]  clamped;

    always @(posedge clk) begin
        if (!rst_n) begin
            out_flat  <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                for (k = 0; k < N; k = k+1) begin
                    val = accum_flat_in[k*32 +: 32];
                    case (act_sel)
                        2'b00: activated = val;
                        2'b01: activated = (val < 0) ? 32'sd0 : val;
                        2'b10: activated = (val < 0) ? 32'sd0 : (val > 32'sd6144) ? 32'sd6144 : val;
                        default: activated = val;
                    endcase
                    shifted = activated >>> shift;
                    if      (shifted >  127) clamped =  8'sd127;
                    else if (shifted < -128) clamped = -8'sd128;
                    else                     clamped = shifted[7:0];
                    out_flat[k*8 +: 8] <= clamped;
                end
            end
        end
    end
endmodule
`default_nettype wire
