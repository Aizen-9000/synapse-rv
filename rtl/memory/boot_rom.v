// =============================================================================
//  Synapse-RV — Boot ROM  v1.0  [VERIFIED]
//  64KB, read-only, initialised from $readmemh on simulation.
//  On FPGA: synthesised as BRAM. On ASIC: ROM compiler macro.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module boot_rom #(
    parameter DEPTH     = 16384,
    parameter DATA_W    = 32,
    parameter INIT_FILE = "boot_rom.hex"
)(
    input  wire                      clk,
    input  wire [$clog2(DEPTH)-1:0]  addr,
    output reg  [DATA_W-1:0]         rd_data
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];
    initial begin
        `ifdef SIMULATION
            $readmemh("/home/anupam/synapse-rv-linux/build/boot_rom.hex", mem);
        `endif
    end
    always @(posedge clk) rd_data <= mem[addr];
endmodule
`default_nettype wire
