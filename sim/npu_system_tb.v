`timescale 1ns/1ps
module npu_system_tb;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg  [11:0] m_awaddr; reg  m_awvalid;
    reg  [31:0] m_wdata;  reg  m_wvalid; reg [3:0] m_wstrb;
    reg         m_bready;
    reg  [11:0] m_araddr; reg  m_arvalid; reg m_rready;
    wire m_awready, m_wready, m_bvalid; wire [1:0] m_bresp;
    wire m_arready, m_rvalid; wire [31:0] m_rdata; wire [1:0] m_rresp;
    wire npu_irq;
    npu_top dut(
        .clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(m_awaddr),.s_axi_awvalid(m_awvalid),.s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata),.s_axi_wstrb(m_wstrb),
        .s_axi_wvalid(m_wvalid),.s_axi_wready(m_wready),
        .s_axi_bresp(m_bresp),.s_axi_bvalid(m_bvalid),.s_axi_bready(m_bready),
        .s_axi_araddr(m_araddr),.s_axi_arvalid(m_arvalid),.s_axi_arready(m_arready),
        .s_axi_rdata(m_rdata),.s_axi_rresp(m_rresp),
        .s_axi_rvalid(m_rvalid),.s_axi_rready(m_rready),
        .m_axi_arid(),.m_axi_araddr(),.m_axi_arlen(),.m_axi_arsize(),.m_axi_arburst(),
        .m_axi_arvalid(),.m_axi_arready(1'b1),
        .m_axi_rid(4'd0),.m_axi_rdata(64'd0),.m_axi_rresp(2'b0),
        .m_axi_rlast(1'b1),.m_axi_rvalid(1'b0),.m_axi_rready(),
        .irq_done(npu_irq));
    task axi_wr;
        input [11:0] addr; input [31:0] data; integer i;
        begin
            @(posedge clk); #1; m_awaddr=addr; m_awvalid=1'b1;
            i=0; while(!m_awready&&i<200)begin @(posedge clk);#1;i=i+1;end
            @(posedge clk); #1; m_awvalid=1'b0;
            @(posedge clk); #1; m_wdata=data; m_wstrb=4'hF; m_wvalid=1'b1;
            i=0; while(!m_wready&&i<200)begin @(posedge clk);#1;i=i+1;end
            @(posedge clk); #1; m_wvalid=1'b0;
            m_bready=1'b1; i=0; while(!m_bvalid&&i<200)begin @(posedge clk);#1;i=i+1;end
            @(posedge clk); #1; m_bready=1'b0;
        end
    endtask
    reg [31:0] rd;
    task axi_rd;
        input [11:0] addr; integer i;
        begin
            @(posedge clk); #1; m_araddr=addr; m_arvalid=1'b1; m_rready=1'b1;
            i=0; while(!m_arready&&i<200)begin @(posedge clk);#1;i=i+1;end
            @(posedge clk); #1; m_arvalid=1'b0;
            i=0; while(!m_rvalid&&i<200)begin @(posedge clk);#1;i=i+1;end
            rd=m_rdata; @(posedge clk); #1; m_rready=1'b0;
        end
    endtask
    integer p=0,f=0,t,j;
    task chk; input [255:0] n; input [31:0] g,e;
        begin if(g===e)begin $display("  PASS | %0s",n);p=p+1;end
        else begin $display("  FAIL | %0s  got=0x%08X  exp=0x%08X",n,g,e);f=f+1;end end
    endtask
    initial begin $dumpfile("npu_system_waves.vcd"); $dumpvars(0,npu_system_tb); end
    initial begin
        m_awvalid=0;m_wvalid=0;m_bready=0;m_arvalid=0;m_rready=0;m_wstrb=4'hF;
        m_awaddr=0;m_wdata=0;m_araddr=0;
        $display("==== NPU System TB v1.2 ====");
        repeat(10)@(posedge clk); rst_n=1; repeat(5)@(posedge clk);
        $display("[TEST 1] CSR write/read");
        axi_wr(12'h004,32'd4); axi_wr(12'h008,32'h00000101);
        axi_rd(12'h004); chk("TILE_CNT",rd,32'd4);
        axi_rd(12'h008); chk("ACT_CFG",rd,32'h00000101);
        $display("[TEST 2] Weight load");
        for(j=0;j<8;j=j+1)begin
            axi_wr(12'h010,j); axi_wr(12'h014,32'h03030303); axi_wr(12'h018,32'h03030303);
        end
        if(dut.u_wbuf.ready)begin $display("  PASS | weights_ready");p=p+1;end
        else begin $display("  FAIL | weights_ready");f=f+1;end
        $display("[TEST 3] Inference");
        axi_wr(12'h004,32'd1); axi_wr(12'h000,32'h1);
        t=0; while(!npu_irq&&t<2000)begin @(posedge clk);t=t+1;end
        if(npu_irq)begin $display("  PASS | IRQ after %0d cycles",t);p=p+1;end
        else begin $display("  FAIL | IRQ timeout ctrl_state=%0d",dut.u_ctrl.state);f=f+1;end
        $display("[TEST 4] STATUS");
        // Read STATUS *before* deasserting start — ctrl clears done when start drops
        repeat(3)@(posedge clk);
        axi_rd(12'h00C); $display("  INFO | STATUS=0x%08X",rd);
        if(rd[1])begin $display("  PASS | done bit set");p=p+1;end
        else begin $display("  FAIL | done bit not set");f=f+1;end
        axi_wr(12'h000,32'h0);
        $display("\n==== %0d PASS  %0d FAIL ====",p,f);
        if(f==0) $display("*** ALL NPU TESTS PASSED ***");
        $finish;
    end
    initial begin #10_000_000; $display("[WATCHDOG]"); $finish; end
endmodule
