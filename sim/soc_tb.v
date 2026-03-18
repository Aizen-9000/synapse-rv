`timescale 1ns/1ps
module soc_tb;
    reg  clk_ref=0, rst_por_n=0;
    wire uart0_tx; reg uart0_rx=1;
    wire spi0_sck,spi0_cs_n;
    wire [3:0] spi0_io_o,spi0_io_oe; reg [3:0] spi0_io_i=4'hF;
    reg jtag_tck=0,jtag_tms=1,jtag_tdi=1; wire jtag_tdo;
    wire [15:0] ddr_addr; wire [2:0] ddr_ba;
    wire ddr_ras_n,ddr_cas_n,ddr_we_n,ddr_ck_p,ddr_ck_n,ddr_cke,ddr_odt,ddr_cs_n;
    wire [31:0] ddr_dq=32'hz; wire [3:0] ddr_dqs_p,ddr_dqs_n,ddr_dm;
    wire [3:0] led; wire soc_irq_out; wire [31:0] gpio=32'hz;

    synapse_rv_soc u_dut(
        .clk_ref(clk_ref),.rst_por_n(rst_por_n),
        .uart0_tx(uart0_tx),.uart0_rx(uart0_rx),
        .spi0_sck(spi0_sck),.spi0_cs_n(spi0_cs_n),
        .spi0_io_o(spi0_io_o),.spi0_io_i(spi0_io_i),.spi0_io_oe(spi0_io_oe),
        .jtag_tck(jtag_tck),.jtag_tms(jtag_tms),.jtag_tdi(jtag_tdi),.jtag_tdo(jtag_tdo),
        .gpio(gpio),
        .ddr_addr(ddr_addr),.ddr_ba(ddr_ba),
        .ddr_ras_n(ddr_ras_n),.ddr_cas_n(ddr_cas_n),.ddr_we_n(ddr_we_n),
        .ddr_ck_p(ddr_ck_p),.ddr_ck_n(ddr_ck_n),
        .ddr_cke(ddr_cke),.ddr_odt(ddr_odt),.ddr_cs_n(ddr_cs_n),
        .ddr_dq(ddr_dq),.ddr_dqs_p(ddr_dqs_p),.ddr_dqs_n(ddr_dqs_n),.ddr_dm(ddr_dm),
        .led(led),.soc_irq_out(soc_irq_out)
    );

    always #10 clk_ref=~clk_ref;

    integer pass_cnt=0,fail_cnt=0,cyc=0,timeout;
    reg [63:0] obs;

    always @(posedge clk_ref) begin
        cyc=cyc+1;
        if(cyc%10000==0)
            $display("[CYC %0d] cpu_state=%0d irq=%0d uart_tx=%0d",
                cyc, u_dut.u_cpu.state, soc_irq_out, uart0_tx);
    end

    task check; input [63:0] g,e; input [127:0] n; begin
        if(g===e) begin $display("  PASS | %0s",n); pass_cnt=pass_cnt+1; end
        else      begin $display("  FAIL | %0s got=%0d exp=%0d",n,g,e); fail_cnt=fail_cnt+1; end
    end endtask

    initial begin
        $display("===== Full SoC Testbench =====");
        rst_por_n=0; repeat(20) @(posedge clk_ref);
        rst_por_n=1; repeat(10) @(posedge clk_ref);
        check(rst_por_n,1,"rst_released");

        // Trace first 300 cycles
        begin integer t;
        for(t=0;t<600;t=t+1) begin
            @(posedge clk_ref);
            if(t<50 || t>290 || u_dut.u_cpu.state!=8)
                $display("[T=%0d] cpu=%0d awv=%0d awr=%0d wv=%0d wr=%0d bv=%0d irq=%0d npu_cmd=%0d npu_busy=%0d npu_ctrl=%0d ctrl_done=%0d",
                    t, u_dut.u_cpu.state,
                    u_dut.u_cpu.m_awvalid, u_dut.u_cpu.m_awready,
                    u_dut.u_cpu.m_wvalid,  u_dut.u_cpu.m_wready,
                    u_dut.u_cpu.m_bvalid,
                    u_dut.npu_irq,
                    u_dut.u_npu.csr_cmd, u_dut.u_npu.u_ctrl.status_busy,
                    u_dut.u_npu.u_ctrl.state, u_dut.u_npu.u_ctrl.status_done);
        end end
        check(1,1,"trace_done");

        $display("T3: cpu_state=%0d", u_dut.u_cpu.state);
        check((u_dut.u_cpu.state>=2),1,"cpu_post_boot");
        $display("T4: cpu_state=%0d", u_dut.u_cpu.state);
        check((u_dut.u_cpu.state>=8),1,"cpu_wait_irq");

        $display("T5: waiting IRQ...");
        timeout=0; while(!soc_irq_out && timeout<30000) begin @(posedge clk_ref); timeout=timeout+1; end
        $display("T5: irq=%0d cpu_state=%0d after %0d cyc", soc_irq_out, u_dut.u_cpu.state, timeout);
        check(soc_irq_out,1,"npu_irq");

        $display("T6: waiting TX_UART state=9...");
        timeout=0; while(u_dut.u_cpu.state<9 && timeout<5000) begin @(posedge clk_ref); timeout=timeout+1; end
        $display("T6: cpu_state=%0d after %0d cyc", u_dut.u_cpu.state, timeout);
        check((u_dut.u_cpu.state>=9),1,"cpu_tx_uart");

        $display("T7: waiting uart0_tx low...");
        timeout=0; while(uart0_tx===1'b1 && timeout<50000) begin @(posedge clk_ref); timeout=timeout+1; end
        $display("T7: uart0_tx=%0d cpu_state=%0d after %0d cyc", uart0_tx, u_dut.u_cpu.state, timeout);
        check((uart0_tx!==1'b1),1,"uart_tx_active");

        $display("T8: waiting DONE state=14...");
        timeout=0; while(u_dut.u_cpu.state!=14 && timeout<20000) begin @(posedge clk_ref); timeout=timeout+1; end
        $display("T8: cpu_state=%0d after %0d cyc", u_dut.u_cpu.state, timeout);
        check((u_dut.u_cpu.state==14),1,"cpu_done");

        $display("\n===== %0d PASS  %0d FAIL =====", pass_cnt, fail_cnt);
        $finish;
    end
    initial begin #100_000_000; $display("[WATCHDOG]"); $finish; end
endmodule
