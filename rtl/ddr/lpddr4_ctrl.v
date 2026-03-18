// =============================================================================
//  Synapse-RV — LPDDR4 Controller  v1.0
//  AXI4 slave → LPDDR4 command/data PHY interface
//
//  Supports:
//    - 32-bit data bus, 16-bit address
//    - 8-bank DDR4 timing (tRCD=14, tCL=14, tRP=14, tRAS=33 cycles)
//    - Auto-precharge, auto-refresh (tREFI=7800ns @ 200MHz = 1560 cycles)
//    - Write/read bursting (BL=8)
//    - ZQ calibration on init
//
//  PHY interface (to pad ring):
//    ddr_ck_p/n   — differential clock
//    ddr_cke      — clock enable
//    ddr_cs_n     — chip select
//    ddr_ras_n    — row address strobe
//    ddr_cas_n    — column address strobe
//    ddr_we_n     — write enable
//    ddr_addr     — 16-bit address/command
//    ddr_ba       — 3-bit bank address
//    ddr_dq       — 32-bit data
//    ddr_dqs_p/n  — data strobe differential
//    ddr_dm       — data mask
//    ddr_odt      — on-die termination
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module lpddr4_ctrl #(
    parameter AXI_AW  = 32,
    parameter AXI_DW  = 64,
    parameter AXI_IW  = 4,
    // LPDDR4 timing (in controller clock cycles @ 200MHz)
    parameter T_RCD   = 14,   // RAS-to-CAS delay
    parameter T_CL    = 14,   // CAS latency
    parameter T_RP    = 14,   // precharge time
    parameter T_RAS   = 33,   // row active time
    parameter T_WR    = 15,   // write recovery
    parameter T_REFI  = 1560, // refresh interval
    parameter T_RFC   = 140,  // refresh cycle time
    parameter BL      = 8     // burst length
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4 slave
    input  wire [AXI_IW-1:0]  s_arid,
    input  wire [AXI_AW-1:0]  s_araddr,
    input  wire [7:0]          s_arlen,
    input  wire [2:0]          s_arsize,
    input  wire [1:0]          s_arburst,
    input  wire                s_arvalid,
    output wire                s_arready,
    output reg  [AXI_IW-1:0]  s_rid,
    output reg  [AXI_DW-1:0]  s_rdata,
    output wire [1:0]          s_rresp,
    output reg                 s_rvalid,
    output reg                 s_rlast,
    input  wire                s_rready,
    input  wire [AXI_IW-1:0]  s_awid,
    input  wire [AXI_AW-1:0]  s_awaddr,
    input  wire [7:0]          s_awlen,
    input  wire [2:0]          s_awsize,
    input  wire [1:0]          s_awburst,
    input  wire                s_awvalid,
    output wire                s_awready,
    input  wire [AXI_DW-1:0]  s_wdata,
    input  wire [7:0]          s_wstrb,
    input  wire                s_wlast,
    input  wire                s_wvalid,
    output wire                s_wready,
    output reg  [AXI_IW-1:0]  s_bid,
    output wire [1:0]          s_bresp,
    output reg                 s_bvalid,
    input  wire                s_bready,

    // LPDDR4 PHY interface
    output wire        ddr_ck_p,
    output wire        ddr_ck_n,
    output reg         ddr_cke,
    output reg         ddr_cs_n,
    output reg         ddr_ras_n,
    output reg         ddr_cas_n,
    output reg         ddr_we_n,
    output reg  [15:0] ddr_addr,
    output reg  [2:0]  ddr_ba,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs_p,
    inout  wire [3:0]  ddr_dqs_n,
    output reg  [3:0]  ddr_dm,
    output reg         ddr_odt,

    // Status
    output wire        init_done,
    output wire        ddr_busy
);

    // -------------------------------------------------------------------------
    // DDR clock generation
    // -------------------------------------------------------------------------
    assign ddr_ck_p = clk;
    assign ddr_ck_n = ~clk;

    // -------------------------------------------------------------------------
    // DQ bus — tristate
    // -------------------------------------------------------------------------
    reg [31:0] dq_out;
    reg        dq_oe;
    assign ddr_dq    = dq_oe ? dq_out : 32'hzzzzzzzz;
    assign ddr_dqs_p = dq_oe ? 4'b1010 : 4'hz;
    assign ddr_dqs_n = dq_oe ? 4'b0101 : 4'hz;

    // -------------------------------------------------------------------------
    // Initialization FSM
    // -------------------------------------------------------------------------
    localparam INIT_IDLE    = 4'd0;
    localparam INIT_WAIT200 = 4'd1;  // 200us power-on wait
    localparam INIT_CKE     = 4'd2;
    localparam INIT_MRS     = 4'd3;  // Mode Register Set
    localparam INIT_ZQ      = 4'd4;  // ZQ calibration
    localparam INIT_DONE    = 4'd5;

    reg [3:0]  init_state;
    reg [15:0] init_cnt;
    reg        init_done_r;
    assign init_done = init_done_r;

    // Main controller FSM
    localparam S_IDLE     = 4'd0;
    localparam S_ACTIVATE = 4'd1;
    localparam S_RCD_WAIT = 4'd2;
    localparam S_READ     = 4'd3;
    localparam S_WRITE    = 4'd4;
    localparam S_CL_WAIT  = 4'd5;
    localparam S_RD_DATA  = 4'd6;
    localparam S_WR_DATA  = 4'd7;
    localparam S_PRECHARGE= 4'd8;
    localparam S_RP_WAIT  = 4'd9;
    localparam S_REFRESH  = 4'd10;
    localparam S_RFC_WAIT = 4'd11;
    localparam S_RESPOND  = 4'd12;

    reg [3:0]  state;
    reg [7:0]  timer;
    reg [10:0] refi_cnt;
    reg        refresh_needed;
    reg        is_write;

    // Request registers
    reg [AXI_IW-1:0] req_id;
    reg [AXI_AW-1:0] req_addr;
    reg [7:0]        req_len;
    reg [AXI_DW-1:0] req_wdata;
    reg [7:0]        req_wstrb;
    reg [7:0]        burst_cnt;
    reg [AXI_DW-1:0] rd_data_buf;

    // DDR address breakdown: [31:29]=bank [28:13]=row [12:3]=col [2:0]=byte
    wire [2:0]  req_bank = req_addr[31:29];
    wire [15:0] req_row  = req_addr[28:13];
    wire [9:0]  req_col  = req_addr[12:3];

    assign s_arready = (state == S_IDLE) && init_done_r && !refresh_needed && !s_awvalid;
    assign s_awready = (state == S_IDLE) && init_done_r && !refresh_needed;
    assign s_wready  = (state == S_WR_DATA);
    assign s_rresp   = 2'b00;
    assign s_bresp   = 2'b00;
    assign ddr_busy  = (state != S_IDLE);

    // -------------------------------------------------------------------------
    // Refresh counter
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin refi_cnt <= 0; refresh_needed <= 0; end
        else if (state == S_REFRESH) begin refi_cnt <= 0; refresh_needed <= 0; end
        else begin
            refi_cnt <= refi_cnt + 1;
            if (refi_cnt >= T_REFI) refresh_needed <= 1;
        end
    end

    // -------------------------------------------------------------------------
    // Initialization sequence
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_state <= INIT_WAIT200; init_cnt <= 0; init_done_r <= 0;
            ddr_cke <= 0; ddr_cs_n <= 1; ddr_odt <= 0;
            ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1; ddr_addr<=0; ddr_ba<=0;
        end else if (!init_done_r) begin
            init_cnt <= init_cnt + 1;
            case (init_state)
                INIT_WAIT200: begin
                    ddr_cke <= 0; ddr_cs_n <= 1;
                    if (init_cnt == 16'hFFFF) begin // ~200us @ 200MHz = 40000 cycles
                        init_state <= INIT_CKE; init_cnt <= 0;
                    end
                end
                INIT_CKE: begin
                    ddr_cke <= 1; ddr_cs_n <= 0;
                    if (init_cnt == 10) begin init_state <= INIT_MRS; init_cnt <= 0; end
                end
                INIT_MRS: begin
                    // MRS command: RAS=0 CAS=0 WE=0
                    ddr_ras_n<=0; ddr_cas_n<=0; ddr_we_n<=0;
                    ddr_ba   <= 3'd0;
                    ddr_addr <= 16'h0320; // CL=14, BL=8
                    if (init_cnt == 1) begin
                        ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1;
                    end
                    if (init_cnt == 10) begin init_state <= INIT_ZQ; init_cnt <= 0; end
                end
                INIT_ZQ: begin
                    // ZQ long calibration
                    ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=0; ddr_addr<=16'h0400;
                    if (init_cnt == 1) ddr_we_n <= 1;
                    if (init_cnt == 200) begin init_state <= INIT_DONE; init_cnt <= 0; end
                end
                INIT_DONE: begin
                    init_done_r <= 1;
                end
                default: init_state <= INIT_DONE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Main controller FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; timer <= 0; burst_cnt <= 0;
            s_rvalid<=0; s_rlast<=0; s_bvalid<=0; dq_oe<=0;
            ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1;
        end else begin
            s_rvalid <= 0; s_rlast <= 0;
            if (s_bvalid && s_bready) s_bvalid <= 0;

            case (state)
                S_IDLE: begin
                    ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1; dq_oe<=0;
                    if (!init_done_r) ;
                    else if (refresh_needed) begin
                        state <= S_REFRESH;
                        // AUTO REFRESH command
                        ddr_ras_n<=0; ddr_cas_n<=0; ddr_we_n<=1; ddr_cs_n<=0;
                        timer <= T_RFC;
                    end else if (s_awvalid) begin
                        is_write  <= 1;
                        req_id    <= s_awid;
                        req_addr  <= s_awaddr;
                        req_len   <= s_awlen;
                        burst_cnt <= 0;
                        state     <= S_ACTIVATE;
                        // ACTIVATE command
                        ddr_ras_n<=0; ddr_cas_n<=1; ddr_we_n<=1;
                        ddr_ba   <= s_awaddr[31:29];
                        ddr_addr <= s_awaddr[28:13];
                        timer    <= T_RCD;
                    end else if (s_arvalid) begin
                        is_write  <= 0;
                        req_id    <= s_arid;
                        req_addr  <= s_araddr;
                        req_len   <= s_arlen;
                        burst_cnt <= 0;
                        state     <= S_ACTIVATE;
                        ddr_ras_n<=0; ddr_cas_n<=1; ddr_we_n<=1;
                        ddr_ba   <= s_araddr[31:29];
                        ddr_addr <= s_araddr[28:13];
                        timer    <= T_RCD;
                    end
                end

                S_ACTIVATE: begin
                    ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1;
                    if (timer > 0) timer <= timer - 1;
                    else state <= is_write ? S_WRITE : S_READ;
                end

                S_READ: begin
                    // CAS-READ command with auto-precharge
                    ddr_ras_n<=1; ddr_cas_n<=0; ddr_we_n<=1;
                    ddr_ba   <= req_addr[31:29];
                    ddr_addr <= {5'h10, req_col}; // A10=1 for auto-precharge
                    timer    <= T_CL;
                    state    <= S_CL_WAIT;
                end

                S_WRITE: begin
                    // CAS-WRITE command
                    ddr_ras_n<=1; ddr_cas_n<=0; ddr_we_n<=0;
                    ddr_ba   <= req_addr[31:29];
                    ddr_addr <= {5'h10, req_col};
                    timer    <= 2;
                    state    <= S_WR_DATA;
                end

                S_CL_WAIT: begin
                    ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1;
                    if (timer > 0) timer <= timer - 1;
                    else begin state <= S_RD_DATA; timer <= req_len; end
                end

                S_RD_DATA: begin
                    // Capture read data from DQ bus
                    rd_data_buf <= {ddr_dq, ddr_dq};  // 64-bit from 32-bit DQ
                    s_rdata     <= {ddr_dq, ddr_dq};
                    s_rid       <= req_id;
                    s_rvalid    <= 1;
                    s_rlast     <= (burst_cnt == req_len);
                    if (burst_cnt == req_len) begin
                        state <= S_PRECHARGE;
                        timer <= T_RP;
                    end else burst_cnt <= burst_cnt + 1;
                end

                S_WR_DATA: begin
                    if (timer > 0) begin timer <= timer - 1; end
                    else if (s_wvalid) begin
                        dq_oe   <= 1;
                        dq_out  <= s_wdata[31:0];
                        ddr_dm  <= ~s_wstrb[3:0];
                        req_wdata <= s_wdata;
                        if (s_wlast || burst_cnt == req_len) begin
                            dq_oe <= 0;
                            timer <= T_WR;
                            state <= S_PRECHARGE;
                        end else burst_cnt <= burst_cnt + 1;
                    end
                end

                S_PRECHARGE: begin
                    ddr_ras_n<=0; ddr_cas_n<=1; ddr_we_n<=0;
                    ddr_addr <= 16'h0400; // A10=1 all banks
                    if (timer > 0) timer <= timer - 1;
                    else begin
                        ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1;
                        state <= S_RESPOND;
                    end
                end

                S_RESPOND: begin
                    if (is_write) begin
                        s_bid    <= req_id;
                        s_bvalid <= 1;
                    end
                    state <= S_IDLE;
                end

                S_REFRESH: begin
                    ddr_ras_n<=1; ddr_cas_n<=1; ddr_we_n<=1;
                    if (timer > 0) timer <= timer - 1;
                    else state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
