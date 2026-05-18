`timescale 1ns/1ps
`default_nettype none

module user_project_wrapper #(parameter BITS = 32)(
`ifdef USE_POWER_PINS
    inout vdda1, inout vdda2, inout vssa1, inout vssa2,
    inout vccd1, inout vccd2, inout vssd1, inout vssd2,
`endif
    input  wire        wb_clk_i, wb_rst_i,
    input  wire        wbs_stb_i, wbs_cyc_i, wbs_we_i,
    input  wire [3:0]  wbs_sel_i,
    input  wire [31:0] wbs_dat_i, wbs_adr_i,
    output wire        wbs_ack_o,
    output wire [31:0] wbs_dat_o,
    input  wire [127:0] la_data_in,
    output wire [127:0] la_data_out,
    input  wire [127:0] la_oenb,
    input  wire [37:0]  io_in,
    output wire [37:0]  io_out,
    output wire [37:0]  io_oeb,
    output wire [2:0]   irq
);
    wire clk = wb_clk_i;
    wire rst_n = ~wb_rst_i;

    wire uart0_tx, spi0_sck, spi0_cs_n, jtag_tdo, soc_irq_out;
    wire [3:0] spi0_io_o, spi0_io_oe, led;
    wire [15:0] ddr_addr; wire [2:0] ddr_ba;
    wire ddr_ras_n, ddr_cas_n, ddr_we_n, ddr_ck_p, ddr_ck_n;
    wire ddr_cke, ddr_odt, ddr_cs_n;
    wire [31:0] ddr_dq; wire [3:0] ddr_dqs_p, ddr_dqs_n, ddr_dm;

    synapse_rv_soc u_soc (
        .clk_ref(clk), .rst_por_n(rst_n),
        .uart0_tx(uart0_tx), .uart0_rx(io_in[0]),
        .spi0_sck(spi0_sck), .spi0_cs_n(spi0_cs_n),
        .spi0_io_o(spi0_io_o), .spi0_io_i(io_in[11:8]), .spi0_io_oe(spi0_io_oe),
        .jtag_tck(io_in[16]), .jtag_tms(io_in[17]),
        .jtag_tdi(io_in[18]), .jtag_tdo(jtag_tdo),
        .gpio(la_data_out[31:0]),
        .ddr_addr(ddr_addr), .ddr_ba(ddr_ba),
        .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n),
        .ddr_ck_p(ddr_ck_p), .ddr_ck_n(ddr_ck_n),
        .ddr_cke(ddr_cke), .ddr_odt(ddr_odt), .ddr_cs_n(ddr_cs_n),
        .ddr_dq(ddr_dq), .ddr_dqs_p(ddr_dqs_p), .ddr_dqs_n(ddr_dqs_n),
        .ddr_dm(ddr_dm), .led(led), .soc_irq_out(soc_irq_out)
    );

    assign io_out  = {13'b0, soc_irq_out, led, jtag_tdo, 3'b0,
                      spi0_io_oe, 4'b0, spi0_io_o, spi0_cs_n, spi0_sck, uart0_tx, 1'b0};
    assign io_oeb  = {13'b1, 1'b0, 4'b0, 1'b0, 3'b1, 4'b0, 4'b1111,
                      4'b0, 1'b0, 1'b0, 1'b0, 1'b1};
    assign wbs_ack_o = 1'b0;
    assign wbs_dat_o = 32'h0;
    assign la_data_out = 128'h0;
    assign irq = {2'b0, soc_irq_out};
endmodule
`default_nettype wire
