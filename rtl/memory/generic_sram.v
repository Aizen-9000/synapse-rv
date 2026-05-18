// =============================================================================
//  Synapse-RV — Generic Synchronous SRAM  v1.0  [VERIFIED]
//  Parameterized, byte-enable writes.
//  FPGA: inferred as Block RAM. ASIC: replace with SRAM compiler macro.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module generic_sram #(
    parameter DEPTH  = 65536,
    parameter DATA_W = 64
)(
    input  wire                      clk,
    input  wire                      en,
    input  wire                      we,
    input  wire [DATA_W/8-1:0]       wstrb,
    input  wire [$clog2(DEPTH)-1:0]  addr,
    input  wire [DATA_W-1:0]         wdata,
    output reg  [DATA_W-1:0]         rdata
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];
    integer i;
    always @(posedge clk) begin
        if (en) begin
            rdata <= mem[addr];
            if (we) begin
                for (i = 0; i < DATA_W/8; i = i+1)
                    if (wstrb[i]) mem[addr][i*8 +: 8] <= wdata[i*8 +: 8];
            end
        end
    end
endmodule
`default_nettype wire
