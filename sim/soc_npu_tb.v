`timescale 1ns/1ps
module soc_npu_tb;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    wire uart0_tx; reg uart0_rx=1;
    wire spi0_sck,spi0_cs_n;
    wire [3:0] spi0_io_o,spi0_io_oe; reg [3:0] spi0_io_i=4'hF;
    reg jtag_tck=0,jtag_tms=1,jtag_tdi=1; wire jtag_tdo;
    wire [15:0] ddr_addr; wire [2:0] ddr_ba;
    wire ddr_ras_n,ddr_cas_n,ddr_we_n,ddr_ck_p,ddr_ck_n,ddr_cke,ddr_odt,ddr_cs_n;
    wire [3:0] ddr_dm,led; wire soc_irq_out;
    wire [31:0] gpio=32'hz;

    synapse_rv_soc u_dut(
        .clk_ref(clk),.rst_por_n(rst_n),
        .uart0_tx(uart0_tx),.uart0_rx(uart0_rx),
        .spi0_sck(spi0_sck),.spi0_cs_n(spi0_cs_n),
        .spi0_io_o(spi0_io_o),.spi0_io_i(spi0_io_i),.spi0_io_oe(spi0_io_oe),
        .jtag_tck(jtag_tck),.jtag_tms(jtag_tms),.jtag_tdi(jtag_tdi),.jtag_tdo(jtag_tdo),
        .gpio(gpio),
        .ddr_addr(ddr_addr),.ddr_ba(ddr_ba),.ddr_ras_n(ddr_ras_n),
        .ddr_cas_n(ddr_cas_n),.ddr_we_n(ddr_we_n),.ddr_ck_p(ddr_ck_p),
        .ddr_ck_n(ddr_ck_n),.ddr_cke(ddr_cke),.ddr_odt(ddr_odt),.ddr_cs_n(ddr_cs_n),
        .ddr_dm(ddr_dm),.led(led),.soc_irq_out(soc_irq_out));

    integer cyc; initial cyc=0;
    always @(posedge clk) begin
        cyc=cyc+1;
        // Print every cycle where CPU is doing NPU writes (state 2-7)
        if (u_dut.u_cpu.dbg_state >= 2 && u_dut.u_cpu.dbg_state <= 11)
            $display("CY%0d st=%0d awv=%b awd=%b wv=%b wr=%b bv=%b aw_pend=%b xs_awv2=%b xs_wv2=%b xs_wr2=%b",
                cyc,
                u_dut.u_cpu.dbg_state,
                u_dut.u_cpu.m_awvalid,
                u_dut.u_cpu.m_awready,
                u_dut.u_cpu.m_wvalid,
                u_dut.u_cpu.m_wready,
                u_dut.u_cpu.m_bvalid,
                u_dut.u_npu.aw_pend,
                u_dut.u_xbar.s_awvalid[2],
                u_dut.u_xbar.s_wvalid[2],
                u_dut.u_xbar.s_wready[2]);
        if (cyc==800) $finish;
    end
    initial begin rst_n=0; repeat(5)@(posedge clk); rst_n=1; end
    initial begin #200000; $finish; end
endmodule
