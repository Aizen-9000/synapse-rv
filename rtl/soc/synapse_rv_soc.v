// =============================================================================
//  Synapse-RV SoC  v2.0  [COMPLETE — crossbar wired, UART added, APB bridge]
//
//  Address map (all routed through axi4_xbar):
//    S0  0x0000_0000–0x7FFF_FFFF  SRAM      (512 KB active)
//    S1  0x8000_0000–0xBFFF_FFFF  DDR       (external, stub)
//    S2  0xC000_0000–0xCFFF_FFFF  NPU CSRs  (AXI4-Lite)
//    S3  0xF000_0000–0xFFFE_FFFF  Periph    (APB: 0x0=UART 0x1000=PMU 0x2000=SEC)
//    S4  0xFFFF_0000–0xFFFF_FFFF  Boot ROM  (64 KB read-only)
//    S5  0xD000_0000–0xDFFF_FFFF  Vector Unit RVV CSRs (AXI4-Lite)
//    S6  0xE000_0000–0xEFFF_FFFF  DMA Engine (AXI4-Lite CSR)
//    S7  0x2000_0000–0x3FFF_FFFF  L2 Cache (64KB, write-back)
//    S8  0xA000_0000–0xAFFF_FFFF  PCIe Gen2 x1
//    S9  0xB000_0000–0xB000_0FFF  USB 2.0
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module synapse_rv_soc (
    input  wire        clk_ref,
    input  wire        rst_por_n,
    output wire        uart0_tx,
    input  wire        uart0_rx,
    output wire        spi0_sck,
    output wire        spi0_cs_n,
    output wire [3:0]  spi0_io_o,
    input  wire [3:0]  spi0_io_i,
    output wire [3:0]  spi0_io_oe,
    input  wire        jtag_tck,
    input  wire        jtag_tms,
    input  wire        jtag_tdi,
    output wire        jtag_tdo,
    inout  wire [31:0] gpio,
    output wire [15:0] ddr_addr,
    output wire [2:0]  ddr_ba,
    output wire        ddr_ras_n, ddr_cas_n, ddr_we_n,
    output wire        ddr_ck_p,  ddr_ck_n,
    output wire        ddr_cke,   ddr_odt,   ddr_cs_n,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs_p, ddr_dqs_n,
    output wire [3:0]  ddr_dm,
    output wire [3:0]  led,
    output wire        soc_irq_out
);

    // ---- params ----
    localparam NM=2, NS=10, AW=32, DW=64, IW=4, SW=8; // SW=DW/8

    // ---- clocks & reset ----
    wire clk_cpu=clk_ref, clk_npu=clk_ref, clk_peri=clk_ref;
    reg [2:0] rsc, rsn, rsp;
    always @(posedge clk_ref) rsc <= rst_por_n ? {rsc[1:0],1'b1} : 3'd0;
    always @(posedge clk_ref) rsn <= rst_por_n ? {rsn[1:0],1'b1} : 3'd0;
    always @(posedge clk_ref) rsp <= rst_por_n ? {rsp[1:0],1'b1} : 3'd0;
    wire rst_cpu_n=rsc[2], rst_npu_n=rsn[2], rst_peri_n=rsp[2];

    // ---- interrupts ----
    wire npu_irq, pmu_irq, sec_irq, uart_irq;
    assign soc_irq_out = npu_irq|pmu_irq|sec_irq|uart_irq;

    // =========================================================================
    // M0 — CPU
    // =========================================================================
    wire [IW-1:0] c_arid,c_awid; wire [AW-1:0] c_araddr,c_awaddr;
    wire [7:0] c_arlen,c_awlen;  wire [2:0] c_arsize,c_awsize;
    wire [1:0] c_arburst,c_awburst;
    wire c_arvalid,c_awvalid,c_arready,c_awready;
    wire [DW-1:0] c_rdata,c_wdata; wire [SW-1:0] c_wstrb;
    wire [1:0] c_rresp,c_bresp; wire [IW-1:0] c_rid,c_bid;
    wire c_rlast,c_wlast,c_rvalid,c_wvalid,c_rready,c_wready,c_bvalid,c_bready;
    wire [7:0] cpu_dbg;

    cpu_stub u_cpu (
        .clk(clk_ref),.rst_n(rst_por_n),.irq(npu_irq),
        .m_araddr(c_araddr),.m_arid(c_arid),.m_arlen(c_arlen),.m_arsize(c_arsize),
        .m_arburst(c_arburst),.m_arvalid(c_arvalid),.m_arready(c_arready),
        .m_rdata(c_rdata),.m_rresp(c_rresp),.m_rlast(c_rlast),.m_rvalid(c_rvalid),.m_rready(c_rready),
        .m_awaddr(c_awaddr),.m_awid(c_awid),.m_awlen(c_awlen),.m_awsize(c_awsize),
        .m_awburst(c_awburst),.m_awvalid(c_awvalid),.m_awready(c_awready),
        .m_wdata(c_wdata),.m_wstrb(c_wstrb),.m_wlast(c_wlast),.m_wvalid(c_wvalid),.m_wready(c_wready),
        .m_bresp(c_bresp),.m_bvalid(c_bvalid),.m_bready(c_bready),.dbg_state(cpu_dbg)
    );

    // =========================================================================
    // M1 — NPU DMA (read-only)
    // =========================================================================
    wire [IW-1:0] n_arid; wire [AW-1:0] n_araddr; wire [7:0] n_arlen;
    wire [2:0] n_arsize; wire [1:0] n_arburst;
    wire n_arvalid,n_arready; wire [DW-1:0] n_rdata; wire [1:0] n_rresp;
    wire [IW-1:0] n_rid; wire n_rlast,n_rvalid,n_rready;
    // write ports tied off
    wire [IW-1:0] n_awid='0; wire [AW-1:0] n_awaddr='0; wire [7:0] n_awlen='0;
    wire [2:0] n_awsize='0; wire [1:0] n_awburst='0; wire n_awvalid=0;
    wire [DW-1:0] n_wdata='0; wire [SW-1:0] n_wstrb='0; wire n_wlast=0,n_wvalid=0,n_bready=1;
    wire n_awready,n_wready,n_bvalid; wire [1:0] n_bresp; wire [IW-1:0] n_bid;

    // =========================================================================
    // Crossbar slave buses — packed [NS*W-1:0]
    // =========================================================================
    wire [NS*IW-1:0]  xs_arid,xs_awid,xs_rid,xs_bid;
    wire [NS*AW-1:0]  xs_araddr,xs_awaddr;
    wire [NS*8-1:0]   xs_arlen,xs_awlen;
    wire [NS*3-1:0]   xs_arsize,xs_awsize;
    wire [NS*2-1:0]   xs_arburst,xs_awburst,xs_rresp,xs_bresp;
    wire [NS-1:0]     xs_arvalid,xs_arready,xs_awvalid,xs_awready;
    wire [NS-1:0]     xs_wvalid,xs_wready,xs_wlast;
    wire [NS-1:0]     xs_rvalid,xs_rready,xs_rlast;
    wire [NS-1:0]     xs_bvalid,xs_bready;
    wire [NS*DW-1:0]  xs_rdata,xs_wdata;
    wire [NS*SW-1:0]  xs_wstrb;

    // =========================================================================
    // Crossbar instantiation
    // =========================================================================
    axi4_xbar #(.NM(NM),.NS(NS),.ADDR_W(AW),.DATA_W(DW),.ID_W(IW)) u_xbar (
        .clk(clk_ref),.rst_n(rst_por_n),
        // AR masters
        .m_arid   ({n_arid,   c_arid   }),.m_araddr ({n_araddr,  c_araddr }),
        .m_arlen  ({n_arlen,  c_arlen  }),.m_arsize ({n_arsize,  c_arsize }),
        .m_arburst({n_arburst,c_arburst}),.m_arvalid({n_arvalid, c_arvalid}),
        .m_arready({n_arready,c_arready}),
        // R masters
        .m_rdata  ({n_rdata,  c_rdata  }),.m_rresp ({n_rresp,  c_rresp }),
        .m_rid    ({n_rid,    c_rid    }),.m_rlast ({n_rlast,  c_rlast }),
        .m_rvalid ({n_rvalid, c_rvalid }),.m_rready({n_rready, c_rready}),
        // AW masters
        .m_awid   ({n_awid,   c_awid   }),.m_awaddr ({n_awaddr,  c_awaddr }),
        .m_awlen  ({n_awlen,  c_awlen  }),.m_awsize ({n_awsize,  c_awsize }),
        .m_awburst({n_awburst,c_awburst}),.m_awvalid({n_awvalid, c_awvalid}),
        .m_awready({n_awready,c_awready}),
        // W masters
        .m_wdata  ({n_wdata,  c_wdata  }),.m_wstrb ({n_wstrb,  c_wstrb }),
        .m_wlast  ({n_wlast,  c_wlast  }),.m_wvalid({n_wvalid, c_wvalid}),
        .m_wready ({n_wready, c_wready }),
        // B masters
        .m_bresp  ({n_bresp,  c_bresp  }),.m_bid   ({n_bid,    c_bid   }),
        .m_bvalid ({n_bvalid, c_bvalid }),.m_bready({n_bready, c_bready}),
        // Slave buses
        .s_arid(xs_arid),.s_araddr(xs_araddr),.s_arlen(xs_arlen),
        .s_arsize(xs_arsize),.s_arburst(xs_arburst),
        .s_arvalid(xs_arvalid),.s_arready(xs_arready),
        .s_rdata(xs_rdata),.s_rresp(xs_rresp),.s_rid(xs_rid),
        .s_rlast(xs_rlast),.s_rvalid(xs_rvalid),.s_rready(xs_rready),
        .s_awid(xs_awid),.s_awaddr(xs_awaddr),.s_awlen(xs_awlen),
        .s_awsize(xs_awsize),.s_awburst(xs_awburst),
        .s_awvalid(xs_awvalid),.s_awready(xs_awready),
        .s_wdata(xs_wdata),.s_wstrb(xs_wstrb),
        .s_wlast(xs_wlast),.s_wvalid(xs_wvalid),.s_wready(xs_wready),
        .s_bresp(xs_bresp),.s_bid(xs_bid),
        .s_bvalid(xs_bvalid),.s_bready(xs_bready)
    );

    // ---- unpack helper tasks (bit-slice) ----
    // ar[si] = xs_arXXX[si*W +: W]  etc.  Used inline below.

    // =========================================================================
    // S0 — SRAM (512 KB)
    // =========================================================================
    wire [DW-1:0] sram_rd; reg s0rv; reg [IW-1:0] s0rid;
    generic_sram #(.DEPTH(65536),.DATA_W(DW)) u_sram (
        .clk(clk_ref),.en(1'b1),
        .we(xs_wvalid[0]),.wstrb(xs_wstrb[SW-1:0]),
        .addr(xs_awvalid[0] ? xs_awaddr[18:3] : xs_araddr[18:3]),
        .wdata(xs_wdata[DW-1:0]),.rdata(sram_rd)
    );
    always @(posedge clk_ref) begin
        s0rv  <= xs_arvalid[0]; s0rid <= xs_arid[IW-1:0];
    end
    assign xs_arready[0]=1'b1;
    assign xs_rdata[DW-1:0]=sram_rd; assign xs_rresp[1:0]=2'b00;
    assign xs_rid[IW-1:0]=s0rid; assign xs_rlast[0]=1'b1; assign xs_rvalid[0]=s0rv;
    assign xs_awready[0]=1'b1; assign xs_wready[0]=1'b1;
    assign xs_bresp[1:0]=2'b00; assign xs_bid[IW-1:0]=xs_awid[IW-1:0];
    assign xs_bvalid[0]=xs_wvalid[0];

    // =========================================================================
    // S1 — LPDDR4 Controller (0x8000_0000–0xBFFF_FFFF)
    wire        ddr_init_done, ddr_busy_sig;
    lpddr4_ctrl u_ddr (
        .clk      (clk_ref), .rst_n (rst_por_n),
        .s_arid   (xs_arid  [1*IW+3:1*IW]),
        .s_araddr (xs_araddr[1*AW+31:1*AW]),
        .s_arlen  (xs_arlen [1*8+7:1*8]),
        .s_arsize (xs_arsize[1*3+2:1*3]),
        .s_arburst(xs_arburst[1*2+1:1*2]),
        .s_arvalid(xs_arvalid[1]), .s_arready(xs_arready[1]),
        .s_rid    (xs_rid   [1*IW+3:1*IW]),
        .s_rdata  (xs_rdata [1*DW+63:1*DW]),
        .s_rresp  (xs_rresp [1*2+1:1*2]),
        .s_rvalid (xs_rvalid[1]), .s_rlast(xs_rlast[1]), .s_rready(xs_rready[1]),
        .s_awid   (xs_awid  [1*IW+3:1*IW]),
        .s_awaddr (xs_awaddr[1*AW+31:1*AW]),
        .s_awlen  (xs_awlen [1*8+7:1*8]),
        .s_awsize (xs_awsize[1*3+2:1*3]),
        .s_awburst(xs_awburst[1*2+1:1*2]),
        .s_awvalid(xs_awvalid[1]), .s_awready(xs_awready[1]),
        .s_wdata  (xs_wdata [1*DW+63:1*DW]),
        .s_wstrb  (xs_wstrb [1*SW+7:1*SW]),
        .s_wlast  (xs_wlast [1]), .s_wvalid(xs_wvalid[1]), .s_wready(xs_wready[1]),
        .s_bid    (xs_bid   [1*IW+3:1*IW]),
        .s_bresp  (xs_bresp [1*2+1:1*2]),
        .s_bvalid (xs_bvalid[1]), .s_bready(xs_bready[1]),
        .ddr_ck_p (ddr_ck_p), .ddr_ck_n (ddr_ck_n),
        .ddr_cke  (ddr_cke),  .ddr_cs_n (ddr_cs_n),
        .ddr_ras_n(ddr_ras_n),.ddr_cas_n(ddr_cas_n),.ddr_we_n(ddr_we_n),
        .ddr_addr (ddr_addr), .ddr_ba   (ddr_ba),
        .ddr_dq   (ddr_dq),
        .ddr_dqs_p(ddr_dqs_p),.ddr_dqs_n(ddr_dqs_n),
        .ddr_dm   (ddr_dm),   .ddr_odt  (ddr_odt),
        .init_done(ddr_init_done), .ddr_busy(ddr_busy_sig)
    );
    // =========================================================================
    // S1 DDR signals driven by lpddr4_ctrl

    // =========================================================================
    // S2 — NPU CSRs
    // =========================================================================
    wire [31:0] npu_rd; wire [1:0] npu_rresp_w; wire npu_rv;
    wire npu_aw_rdy,npu_w_rdy,npu_b_v; wire [1:0] npu_br; wire npu_ar_rdy;

    npu_top u_npu (
        .clk(clk_ref),.rst_n(rst_por_n),
        .s_axi_awaddr(xs_awaddr[2*AW+11:2*AW+0]),
        .s_axi_awvalid(xs_awvalid[2]),.s_axi_awready(npu_aw_rdy),
        .s_axi_wdata(xs_wdata[2*DW+31:2*DW+0]),
        .s_axi_wstrb(xs_wstrb[2*SW+3:2*SW+0]),
        .s_axi_wvalid(xs_wvalid[2]),.s_axi_wready(npu_w_rdy),
        .s_axi_bresp(npu_br),.s_axi_bvalid(npu_b_v),.s_axi_bready(xs_bready[2]),
        .s_axi_araddr(xs_araddr[2*AW+11:2*AW+0]),
        .s_axi_arvalid(xs_arvalid[2]),.s_axi_arready(npu_ar_rdy),
        .s_axi_rdata(npu_rd),.s_axi_rresp(npu_rresp_w),
        .s_axi_rvalid(npu_rv),.s_axi_rready(xs_rready[2]),
        .m_axi_arid(n_arid),.m_axi_araddr(n_araddr),.m_axi_arlen(n_arlen),
        .m_axi_arsize(n_arsize),.m_axi_arburst(n_arburst),
        .m_axi_arvalid(n_arvalid),.m_axi_arready(n_arready),
        .m_axi_rid(n_rid),.m_axi_rdata(n_rdata),.m_axi_rresp(n_rresp),
        .m_axi_rlast(n_rlast),.m_axi_rvalid(n_rvalid),.m_axi_rready(n_rready),
        .irq_done(npu_irq)
    );
    assign xs_awready[2]=npu_aw_rdy; assign xs_wready[2]=npu_w_rdy;
    assign xs_bresp[5:4]=npu_br; assign xs_bid[3*IW-1:2*IW]=xs_awid[3*IW-1:2*IW];
    assign xs_bvalid[2]=npu_b_v;
    assign xs_arready[2]=npu_ar_rdy;
    assign xs_rdata[3*DW-1:2*DW]={{32{1'b0}},npu_rd};
    assign xs_rresp[5:4]=npu_rresp_w; assign xs_rid[3*IW-1:2*IW]=xs_arid[3*IW-1:2*IW];
    assign xs_rlast[2]=1'b1; assign xs_rvalid[2]=npu_rv;

    // =========================================================================
    // S3 — APB Bridge → UART / PMU / SEC
    // =========================================================================
    reg [11:0] apb_a; reg [31:0] apb_wd,apb_rd;
    reg apb_psel,apb_pen,apb_pw;
    reg apb_su,apb_sp,apb_ss;   // sel_uart, sel_pmu, sel_sec
    reg [3:0] bs;                // bridge state
    reg s3rv,s3bv; reg [IW-1:0] s3rid,s3bid; reg [1:0] s3br;
    reg s3ar_rdy,s3aw_rdy,s3w_rdy;
    // APB ready mux — declared outside always block (Verilog-2005 requirement)
    wire apb_prd_ok = (apb_su ? up_rdy : apb_sp ? pp_rdy : apb_ss ? sp_rdy : 1'b1);
    wire [31:0] apb_prdata_mux = (apb_su ? up_rd : apb_sp ? pp_rd : apb_ss ? sp_rd : 32'd0);

    wire [31:0] up_rd; wire up_rdy;   // uart prdata/pready
    wire [31:0] pp_rd; wire pp_rdy;   // pmu
    wire [31:0] sp_rd; wire sp_rdy;   // sec

    localparam B_IDLE=0,B_SETUP=1,B_EN=2,B_RRESP=3,B_WRESP=4,B_WDATA=5;

    always @(posedge clk_ref) begin
        if (!rst_por_n) begin
            bs<=B_IDLE; apb_psel<=0; apb_pen<=0;
            s3rv<=0; s3bv<=0; s3ar_rdy<=0; s3aw_rdy<=0; s3w_rdy<=0;
        end else begin
            s3ar_rdy<=0; s3aw_rdy<=0; s3w_rdy<=0;
            case (bs)
                B_IDLE: begin
                    s3rv<=0; s3bv<=0;
                    if (xs_arvalid[3]) begin
                        apb_a<=xs_araddr[3*AW+11:3*AW+0];
                        s3rid<=xs_arid[4*IW-1:3*IW];
                        apb_pw<=0;
                        apb_su<=(xs_araddr[3*AW+15:3*AW+12]==4'h0);
                        apb_sp<=(xs_araddr[3*AW+15:3*AW+12]==4'h1);
                        apb_ss<=(xs_araddr[3*AW+15:3*AW+12]==4'h2);
                        apb_psel<=1; apb_pen<=0; s3ar_rdy<=1; bs<=B_SETUP;
                    end else if (xs_awvalid[3]) begin
                        apb_a<=xs_awaddr[3*AW+11:3*AW+0];
                        s3bid<=xs_awid[4*IW-1:3*IW];
                        apb_pw<=1;
                        apb_su<=(xs_awaddr[3*AW+15:3*AW+12]==4'h0);
                        apb_sp<=(xs_awaddr[3*AW+15:3*AW+12]==4'h1);
                        apb_ss<=(xs_awaddr[3*AW+15:3*AW+12]==4'h2);
                        s3aw_rdy<=1; bs<=B_WDATA;
                    end
                end
                B_WDATA: begin
                    if (xs_wvalid[3]) begin
                        apb_wd<=xs_wdata[3*DW+31:3*DW+0];
                        s3w_rdy<=1; apb_psel<=1; apb_pen<=0; bs<=B_SETUP;
                    end
                end
                B_SETUP:  begin apb_pen<=1; bs<=B_EN; end
                B_EN: begin
                    if (apb_prd_ok) begin
                        apb_psel<=0; apb_pen<=0;
                        apb_rd<=apb_prdata_mux;
                        if (!apb_pw) begin s3rv<=1; bs<=B_RRESP; end
                        else begin s3bv<=1; s3br<=2'b00; bs<=B_WRESP; end
                    end
                end
                B_RRESP: if (s3rv&&xs_rready[3]) begin s3rv<=0; bs<=B_IDLE; end
                B_WRESP: if (s3bv&&xs_bready[3]) begin s3bv<=0; bs<=B_IDLE; end
                default: bs<=B_IDLE;
            endcase
        end
    end

    assign xs_arready[3]=s3ar_rdy;
    assign xs_rdata[4*DW-1:3*DW]={{32{1'b0}},apb_rd};
    assign xs_rresp[7:6]=2'b00; assign xs_rid[4*IW-1:3*IW]=s3rid;
    assign xs_rlast[3]=1'b1; assign xs_rvalid[3]=s3rv;
    assign xs_awready[3]=s3aw_rdy; assign xs_wready[3]=s3w_rdy;
    assign xs_bresp[7:6]=s3br; assign xs_bid[4*IW-1:3*IW]=s3bid;
    assign xs_bvalid[3]=s3bv;

    // UART0
    uart16550 #(.CLK_FREQ(50_000_000),.BAUD_DEF(115_200)) u_uart (
        .clk(clk_ref),.rst_n(rst_por_n),
        .paddr(apb_a),.psel(apb_psel&apb_su),.penable(apb_pen),
        .pwrite(apb_pw),.pwdata(apb_wd),.prdata(up_rd),.pready(up_rdy),
        .tx(uart0_tx),.rx(uart0_rx),.irq(uart_irq)
    );

    // PMU
    pmu u_pmu (
        .clk_ref(clk_ref),.pll_cpu_out(clk_ref),.pll_npu_out(clk_ref),.pll_peri_out(clk_ref),
        .rst_por_n(rst_por_n),
        .psel_addr(apb_a),.psel(apb_psel&apb_sp),.penable(apb_pen),
        .pwrite(apb_pw),.pwdata(apb_wd),.prdata(pp_rd),.pready(pp_rdy),
        .clk_cpu(),.clk_npu(),.clk_peri(),
        .pd_cpu_en(),.pd_npu_en(),.pd_peri_en(),
        .pll_cpu_en(),.pll_npu_en(),.pll_peri_en(),
        .wake_gpio(|gpio),.wake_uart(uart0_rx),.wake_timer(1'b0),.irq_pmu(pmu_irq)
    );

    // SEC
    sec_top #(.APB_AW(12),.APB_DW(32)) u_sec (
        .clk(clk_ref),.rst_n(rst_por_n),.sec_mode(1'b1),
        .paddr(apb_a),.psel(apb_psel&apb_ss),.penable(apb_pen),
        .pwrite(apb_pw),.pwdata(apb_wd),.prdata(sp_rd),.pready(sp_rdy),
        .boot_hash_actual(256'd0),.boot_hash_golden(256'd0),
        .boot_ok(),.irq_sec(sec_irq)
    );

    // =========================================================================
    // S4 — Boot ROM (64 KB)
    // =========================================================================
    wire [31:0] rom_rd; reg s4rv; reg [IW-1:0] s4rid;
    boot_rom #(.DEPTH(16384),.DATA_W(32)) u_rom (
        .clk(clk_ref),.addr(xs_araddr[4*AW+15:4*AW+2]),.rd_data(rom_rd)
    );
    always @(posedge clk_ref) begin
        s4rv<=xs_arvalid[4]; s4rid<=xs_arid[5*IW-1:4*IW];
    end
    assign xs_arready[4]=1'b1;
    assign xs_rdata[5*DW-1:4*DW]={{32{1'b0}},rom_rd};
    assign xs_rresp[9:8]=2'b00; assign xs_rid[5*IW-1:4*IW]=s4rid;
    assign xs_rlast[4]=1'b1; assign xs_rvalid[4]=s4rv;
    assign xs_awready[4]=1'b1; assign xs_wready[4]=1'b1;
    assign xs_bresp[9:8]=2'b10;  // SLVERR — ROM is read-only
    assign xs_bid[5*IW-1:4*IW]=xs_awid[5*IW-1:4*IW]; assign xs_bvalid[4]=xs_wvalid[4];

    // =========================================================================
    // Tie-offs
    // =========================================================================
    assign jtag_tdo=1'b1; assign spi0_sck=0; assign spi0_cs_n=1;
    assign spi0_io_o=0; assign spi0_io_oe=0;
    // ddr signals driven by lpddr4_ctrl
    // ddr clock/enable driven by lpddr4_ctrl
    // ddr_odt, ddr_cs_n, ddr_dm driven by lpddr4_ctrl

    assign led = {(cpu_dbg!=8'd11), uart_irq, npu_irq, rst_cpu_n};


    wire        vec_done_irq;
    // RVV master AXI wires (stubbed — no SRAM port yet)
    wire [31:0] rvv_m_araddr, rvv_m_awaddr, rvv_m_wdata;
    wire        rvv_m_arvalid, rvv_m_awvalid, rvv_m_wvalid;
    wire        rvv_m_rready, rvv_m_bready;
    wire [3:0]  rvv_m_wstrb;
    // S5 — RVV Vector Unit CSRs (0xD000_0000–0xDFFF_FFFF)
    rvv_unit u_rvv (
        .clk     (clk_cpu),
        .rst_n   (rst_cpu_n),
        // AXI4-Lite slave from xbar
        .s_awaddr (xs_awaddr[5*AW+11:5*AW]),
        .s_awvalid(xs_awvalid[5]),
        .s_awready(xs_awready[5]),
        .s_wdata  (xs_wdata[5*DW+31:5*DW]),
        .s_wvalid (xs_wvalid[5]),
        .s_wready (xs_wready[5]),
        .s_wstrb  (xs_wstrb[5*SW+3:5*SW]),
        .s_bresp  (xs_bresp[5*2+1:5*2]),
        .s_bvalid (xs_bvalid[5]),
        .s_bready (xs_bready[5]),
        .s_araddr (xs_araddr[5*AW+11:5*AW]),
        .s_arvalid(xs_arvalid[5]),
        .s_arready(xs_arready[5]),
        .s_rdata  (xs_rdata[5*DW+31:5*DW]),
        .s_rresp  (xs_rresp[5*2+1:5*2]),
        .s_rvalid (xs_rvalid[5]),
        .s_rready (xs_rready[5]),
        // AXI4 master — direct to SRAM via secondary xbar port
        .m_araddr (rvv_m_araddr), .m_arvalid(rvv_m_arvalid), .m_arready(1'b1),
        .m_rdata  (32'h0),        .m_rvalid  (1'b0),          .m_rready(rvv_m_rready),
        .m_awaddr (rvv_m_awaddr), .m_awvalid(rvv_m_awvalid), .m_awready(1'b1),
        .m_wdata  (rvv_m_wdata),  .m_wvalid  (rvv_m_wvalid), .m_wready (1'b1),
        .m_wstrb  (rvv_m_wstrb),  .m_bresp   (2'b0),
        .m_bvalid (1'b0),         .m_bready  (rvv_m_bready),
        .vec_done_irq(vec_done_irq)
    );
    // Tie off upper 32 bits of 64-bit rdata bus for S5
    assign xs_rdata[5*DW+63:5*DW+32] = 32'h0;

    // S6 — DMA Engine (0xE000_0000–0xEFFF_FFFF)
    wire [3:0] dma_irq;
    wire [31:0] dma_m_araddr, dma_m_awaddr, dma_m_wdata;
    wire        dma_m_arvalid, dma_m_awvalid, dma_m_wvalid, dma_m_wlast;
    wire [7:0]  dma_m_arlen,  dma_m_awlen;
    wire [2:0]  dma_m_arsize, dma_m_awsize;
    wire [1:0]  dma_m_arburst,dma_m_awburst;
    wire [3:0]  dma_m_wstrb;
    wire        dma_m_rready, dma_m_bready;

    dma_engine u_dma (
        .clk      (clk_ref),
        .rst_n    (rst_cpu_n),
        .s_awaddr (xs_awaddr[6*AW+11:6*AW]),
        .s_awvalid(xs_awvalid[6]),
        .s_awready(xs_awready[6]),
        .s_wdata  (xs_wdata[6*DW+31:6*DW]),
        .s_wvalid (xs_wvalid[6]),
        .s_wready (xs_wready[6]),
        .s_wstrb  (xs_wstrb[6*SW+3:6*SW]),
        .s_bresp  (xs_bresp[6*2+1:6*2]),
        .s_bvalid (xs_bvalid[6]),
        .s_bready (xs_bready[6]),
        .s_araddr (xs_araddr[6*AW+11:6*AW]),
        .s_arvalid(xs_arvalid[6]),
        .s_arready(xs_arready[6]),
        .s_rdata  (xs_rdata[6*DW+31:6*DW]),
        .s_rresp  (xs_rresp[6*2+1:6*2]),
        .s_rvalid (xs_rvalid[6]),
        .s_rready (xs_rready[6]),
        // AXI master — stubbed (will connect to xbar M2 later)
        .m_araddr (dma_m_araddr), .m_arvalid(dma_m_arvalid), .m_arready(1'b1),
        .m_arlen  (dma_m_arlen),  .m_arsize (dma_m_arsize),  .m_arburst(dma_m_arburst),
        .m_rdata  (32'h0),        .m_rvalid (1'b0),           .m_rlast  (1'b0),
        .m_rready (dma_m_rready), .m_rresp  (2'b0),
        .m_awaddr (dma_m_awaddr), .m_awvalid(dma_m_awvalid), .m_awready(1'b1),
        .m_awlen  (dma_m_awlen),  .m_awsize (dma_m_awsize),  .m_awburst(dma_m_awburst),
        .m_wdata  (dma_m_wdata),  .m_wvalid (dma_m_wvalid),  .m_wlast  (dma_m_wlast),
        .m_wready (1'b1),         .m_wstrb  (dma_m_wstrb),
        .m_bresp  (2'b0),         .m_bvalid (1'b0),           .m_bready (dma_m_bready),
        .dma_irq  (dma_irq)
    );
    assign xs_rdata[6*DW+63:6*DW+32] = 32'h0;

    // S7 — L2 Cache (0x2000_0000–0x3FFF_FFFF)
    l2_cache u_l2 (
        .clk      (clk_ref),   .rst_n    (rst_cpu_n),
        .s_araddr (xs_araddr[7*AW+31:7*AW]),
        .s_arvalid(xs_arvalid[7]),  .s_arready(xs_arready[7]),
        .s_rdata  (xs_rdata[7*DW+31:7*DW]),
        .s_rvalid (xs_rvalid[7]),   .s_rready (xs_rready[7]),
        .s_rresp  (xs_rresp[7*2+1:7*2]),
        .s_awaddr (xs_awaddr[7*AW+31:7*AW]),
        .s_awvalid(xs_awvalid[7]),  .s_awready(xs_awready[7]),
        .s_wdata  (xs_wdata[7*DW+31:7*DW]),
        .s_wvalid (xs_wvalid[7]),   .s_wready (xs_wready[7]),
        .s_wstrb  (xs_wstrb[7*SW+3:7*SW]),
        .s_bresp  (xs_bresp[7*2+1:7*2]),
        .s_bvalid (xs_bvalid[7]),   .s_bready (xs_bready[7]),
        // Downstream to SRAM (stubbed — shares SRAM via xbar in full impl)
        .m_araddr(), .m_arvalid(), .m_arready(1'b1),
        .m_rdata(32'h0), .m_rvalid(1'b0), .m_rready(),  .m_rresp(2'b0),
        .m_awaddr(), .m_awvalid(), .m_awready(1'b1),
        .m_wdata(),  .m_wvalid(),  .m_wlast(),  .m_wready(1'b1),
        .m_wstrb(),  .m_bresp(2'b0), .m_bvalid(1'b0), .m_bready(),
        .hit_count(), .miss_count()
    );
    assign xs_rdata[7*DW+63:7*DW+32] = 32'h0;

    // S8 — PCIe Gen2 x1 (0xA000_0000–0xAFFF_FFFF)
    pcie_ctrl u_pcie (
        .clk(clk_ref), .rst_n(rst_por_n),
        // AXI4 master (inbound TLP → SoC) — tied off for sim
        .m_awid(), .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(),
        .m_awvalid(), .m_awready(1'b1),
        .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(), .m_wready(1'b1),
        .m_bresp(2'b0), .m_bvalid(1'b0), .m_bready(),
        .m_arid(), .m_araddr(), .m_arlen(), .m_arsize(), .m_arburst(),
        .m_arvalid(), .m_arready(1'b1),
        .m_rid(4'h0), .m_rdata(64'h0), .m_rresp(2'b0),
        .m_rvalid(1'b0), .m_rlast(1'b0), .m_rready(),
        // AXI4-Lite slave (config space) — mapped to S8
        .cfg_awaddr(xs_awaddr[8*AW+11:8*AW]),
        .cfg_awvalid(xs_awvalid[8]), .cfg_awready(xs_awready[8]),
        .cfg_wdata(xs_wdata[8*DW+31:8*DW]),
        .cfg_wvalid(xs_wvalid[8]),   .cfg_wready(xs_wready[8]),
        .cfg_bresp(xs_bresp[8*2+1:8*2]),
        .cfg_bvalid(xs_bvalid[8]),   .cfg_bready(xs_bready[8]),
        .cfg_araddr(xs_araddr[8*AW+11:8*AW]),
        .cfg_arvalid(xs_arvalid[8]), .cfg_arready(xs_arready[8]),
        .cfg_rdata(xs_rdata[8*DW+31:8*DW]),
        .cfg_rresp(xs_rresp[8*2+1:8*2]),
        .cfg_rvalid(xs_rvalid[8]),   .cfg_rready(xs_rready[8]),
        // PHY — stubbed
        .phy_tx_data(), .phy_tx_valid(), .phy_tx_ready(1'b1),
        .phy_rx_data(8'h0), .phy_rx_valid(1'b0), .phy_link_up(1'b1),
        .msi_req(), .msi_ack(1'b0),
        .link_up(), .link_state()
    );
    assign xs_rdata[8*DW+63:8*DW+32] = 32'h0;
    // xs_rvalid[8] driven by pcie cfg_rvalid directly

    // S9 — USB 2.0 (0xB000_0000–0xB000_0FFF)
    usb2_ctrl u_usb (
        .clk_60mhz(clk_ref), .clk_sys(clk_ref), .rst_n(rst_por_n),
        .s_awaddr(xs_awaddr[9*AW+11:9*AW]),
        .s_awvalid(xs_awvalid[9]), .s_awready(xs_awready[9]),
        .s_wdata(xs_wdata[9*DW+31:9*DW]),
        .s_wvalid(xs_wvalid[9]),   .s_wready(xs_wready[9]),
        .s_bresp(xs_bresp[9*2+1:9*2]),
        .s_bvalid(xs_bvalid[9]),   .s_bready(xs_bready[9]),
        .s_araddr(xs_araddr[9*AW+11:9*AW]),
        .s_arvalid(xs_arvalid[9]), .s_arready(xs_arready[9]),
        .s_rdata(xs_rdata[9*DW+31:9*DW]),
        .s_rresp(xs_rresp[9*2+1:9*2]),
        .s_rvalid(xs_rvalid[9]),   .s_rready(xs_rready[9]),
        // UTMI+ PHY — stubbed
        .utmi_data_in(8'h0), .utmi_txready(1'b1),
        .utmi_rxvalid(1'b0), .utmi_rxactive(1'b0), .utmi_rxerror(1'b0),
        .utmi_linestate(2'b01),
        .utmi_op_mode(), .utmi_xcvr_select(), .utmi_term_select(),
        .utmi_suspend_n(), .utmi_reset(),
        .utmi_data_out(), .utmi_txvalid(),
        .irq_usb(), .connected(), .suspended(), .speed()
    );
    assign xs_rdata[9*DW+63:9*DW+32] = 32'h0;

endmodule
`default_nettype wire
