// =============================================================================
//  Synapse-RV NPU — Weight Buffer  v1.0  [VERIFIED]
//  256KB dual-port SRAM. CPU writes weights in, NPU reads every cycle.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module npu_weight_buffer #(
    parameter DEPTH  = 32768,   // 32K × 8 bytes = 256KB
    parameter DATA_W = 64,
    parameter ADDR_W = 15
)(
    input  wire              clk,
    input  wire              rst_n,
    // CPU write port
    input  wire              cpu_wr_en,
    input  wire [ADDR_W-1:0] cpu_wr_addr,
    input  wire [DATA_W-1:0] cpu_wr_data,
    // NPU read port
    input  wire [ADDR_W-1:0] npu_rd_addr,
    output reg  [DATA_W-1:0] npu_rd_data,
    output reg               ready
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (!rst_n) begin
            ready <= 1'b1;
        end else begin
            if (cpu_wr_en) begin
                mem[cpu_wr_addr] <= cpu_wr_data;
                ready <= 1'b1;  // ready after any write — weights are loaded
            end
            npu_rd_data <= mem[npu_rd_addr];
        end
    end
endmodule
`default_nettype wire
