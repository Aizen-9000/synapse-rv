// =============================================================================
//  Synapse-RV NPU — Top Level  v1.1  [FIXED]
//  FIX 1: All AXI4-Lite ports consistently named s_axi_* (was mixed s_axi/s_axil)
//  FIX 2: Added m_axi_* master port for DMA (NPU reads activations from DDR)
//  FIX 3: Wstrb added to AXI4-Lite write channel
//
//  CSR Map (CPU → NPU via AXI4-Lite slave):
//    0x000 : CMD        [0]=start  [1]=clear
//    0x004 : TILE_CNT   [15:0]
//    0x008 : ACT_CFG    [1:0]=act_sel  [12:8]=shift
//    0x00C : STATUS     [0]=busy  [1]=done  [17:2]=tiles_completed
//    0x010 : WBUF_ADDR  weight buffer write address
//    0x014 : WBUF_DATA_LO  lower 32 bits of weight data
//    0x018 : WBUF_DATA_HI  upper 32 bits of weight data (triggers write)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module npu_top #(
    parameter ADDR_W  = 32,
    parameter DATA_W  = 64,
    parameter AXI_IW  = 4
)(
    input  wire          clk,
    input  wire          rst_n,

    // ---- AXI4-Lite Slave — CPU config (32-bit data width) ----
    input  wire [11:0]   s_axi_awaddr,
    input  wire          s_axi_awvalid,
    output wire          s_axi_awready,
    input  wire [31:0]   s_axi_wdata,
    input  wire [3:0]    s_axi_wstrb,
    input  wire          s_axi_wvalid,
    output wire          s_axi_wready,
    output reg  [1:0]    s_axi_bresp,
    output reg           s_axi_bvalid,
    input  wire          s_axi_bready,
    input  wire [11:0]   s_axi_araddr,
    input  wire          s_axi_arvalid,
    output wire          s_axi_arready,
    output reg  [31:0]   s_axi_rdata,
    output reg  [1:0]    s_axi_rresp,
    output reg           s_axi_rvalid,
    input  wire          s_axi_rready,

    // ---- AXI4 Master — DMA reads activations from DDR/SRAM ----
    output reg  [AXI_IW-1:0]  m_axi_arid,
    output reg  [ADDR_W-1:0]  m_axi_araddr,
    output reg  [7:0]          m_axi_arlen,
    output reg  [2:0]          m_axi_arsize,
    output reg  [1:0]          m_axi_arburst,
    output reg                 m_axi_arvalid,
    input  wire                m_axi_arready,
    input  wire [AXI_IW-1:0]  m_axi_rid,
    input  wire [DATA_W-1:0]  m_axi_rdata,
    input  wire [1:0]          m_axi_rresp,
    input  wire                m_axi_rlast,
    input  wire                m_axi_rvalid,
    output reg                 m_axi_rready,

    // ---- Interrupt to CPU ----
    output wire          irq_done
);

    // =========================================================
    // CSR registers
    // =========================================================
    reg [31:0] csr_cmd;
    reg [31:0] csr_tile_cnt;
    reg [31:0] csr_act_cfg;
    reg [31:0] csr_wbuf_addr;
    reg [31:0] csr_wbuf_data_lo;

    wire [31:0] csr_status;

    // =========================================================
    // AXI4-Lite Write Path
    // =========================================================
    reg [11:0] aw_addr_lat;
    reg        aw_pend;

    assign s_axi_awready = ~aw_pend;
    assign s_axi_wready  = aw_pend;

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_pend       <= 0;
            s_axi_bvalid  <= 0;
            s_axi_bresp   <= 2'b00;
            csr_cmd       <= 0;
            csr_tile_cnt  <= 32'd1;
            csr_act_cfg   <= 32'h0000_0101;  // ReLU, shift=1
            csr_wbuf_addr <= 0;
            csr_wbuf_data_lo <= 0;
        end else begin
            // Latch write address
            if (s_axi_awvalid && s_axi_awready) begin
                aw_addr_lat <= s_axi_awaddr;
                aw_pend     <= 1;
            end
            // Write data
            if (s_axi_wvalid && s_axi_wready) begin
                aw_pend      <= 0;
                s_axi_bvalid <= 1;
                s_axi_bresp  <= 2'b00;
                case (aw_addr_lat[7:0])
                    8'h00: csr_cmd          <= s_axi_wdata;
                    8'h04: csr_tile_cnt     <= s_axi_wdata;
                    8'h08: csr_act_cfg      <= s_axi_wdata;
                    8'h10: csr_wbuf_addr    <= s_axi_wdata;
                    8'h14: csr_wbuf_data_lo <= s_axi_wdata;
                    // 0x18 write triggers 64-bit weight write (handled below)
                    default: ;
                endcase
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 0;
        end
    end

    // Weight buffer write: triggered when CPU writes WBUF_DATA_HI (0x18)
    wire wbuf_wr_en = s_axi_wvalid && s_axi_wready && (aw_addr_lat[7:0] == 8'h18);
    wire [63:0] wbuf_wr_data = {s_axi_wdata, csr_wbuf_data_lo};

    // =========================================================
    // AXI4-Lite Read Path
    // =========================================================
    assign s_axi_arready = ~s_axi_rvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_rvalid <= 0;
            s_axi_rdata  <= 0;
            s_axi_rresp  <= 2'b00;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rresp  <= 2'b00;
                case (s_axi_araddr[7:0])
                    8'h00: s_axi_rdata <= csr_cmd;
                    8'h04: s_axi_rdata <= csr_tile_cnt;
                    8'h08: s_axi_rdata <= csr_act_cfg;
                    8'h0C: s_axi_rdata <= csr_status;
                    default: s_axi_rdata <= 32'hDEAD_C0DE;
                endcase
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 0;
        end
    end

    // =========================================================
    // Internal submodule wiring
    // =========================================================
    wire        ctrl_sa_enable, ctrl_sa_clear, ctrl_act_valid;
    wire        ctrl_busy, ctrl_done;
    wire [15:0] ctrl_tiles_done;
    wire        wbuf_ready;
    wire [63:0] wbuf_rd_data;

    // Sequential read address into weight buffer
    reg [14:0] npu_wbuf_rd_addr;
    always @(posedge clk) begin
        if (!rst_n || ctrl_sa_clear) npu_wbuf_rd_addr <= 15'd0;
        else if (ctrl_sa_enable)     npu_wbuf_rd_addr <= npu_wbuf_rd_addr + 15'd1;
    end

    npu_weight_buffer #(.DEPTH(32768), .DATA_W(64), .ADDR_W(15)) u_wbuf (
        .clk         (clk),
        .rst_n       (rst_n),
        .cpu_wr_en   (wbuf_wr_en),
        .cpu_wr_addr (csr_wbuf_addr[14:0]),
        .cpu_wr_data (wbuf_wr_data),
        .npu_rd_addr (npu_wbuf_rd_addr),
        .npu_rd_data (wbuf_rd_data),
        .ready       (wbuf_ready)
    );

    npu_systolic_array #(.ROWS(8), .COLS(8)) u_sa (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (ctrl_sa_enable),
        .clear           (ctrl_sa_clear),
        .in_a_flat       (wbuf_rd_data),   // activations stream from weight buf
        .in_b_flat       (wbuf_rd_data),   // weights same bus (real: separate buf)
        .accum_flat      (accum_flat_w),
        .accum_valid_flat(accum_valid_w)
    );

    wire signed [32*64-1:0] accum_flat_w;
    wire        [63:0]      accum_valid_w;
    wire signed [8*64-1:0]  act_out_w;
    wire                    act_valid_out_w;

    npu_activation #(.N(64)) u_act (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (ctrl_act_valid),
        .act_sel       (csr_act_cfg[1:0]),
        .shift         ({3'b0, csr_act_cfg[12:8]}),
        .accum_flat_in (accum_flat_w),
        .out_flat      (act_out_w),
        .valid_out     (act_valid_out_w)
    );

    npu_ctrl #(.TILE_CYCLES(256)) u_ctrl (
        .clk             (clk),
        .rst_n           (rst_n),
        .cmd_start       (csr_cmd[0]),
        .cmd_tile_count  (csr_tile_cnt[15:0]),
        .weights_ready   (wbuf_ready),
        .sa_enable       (ctrl_sa_enable),
        .sa_clear        (ctrl_sa_clear),
        .act_valid       (ctrl_act_valid),
        .status_busy     (ctrl_busy),
        .status_done     (ctrl_done),
        .tiles_completed (ctrl_tiles_done)
    );

    assign csr_status = {ctrl_tiles_done, 14'b0, ctrl_done, ctrl_busy};
    assign irq_done   = ctrl_done;

    // =========================================================
    // DMA master — stub: will be expanded to stream activation
    // data from DDR into a second internal activation buffer
    // =========================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            m_axi_arvalid <= 0;
            m_axi_arid    <= 0;
            m_axi_araddr  <= 0;
            m_axi_arlen   <= 8'd0;
            m_axi_arsize  <= 3'd3;    // 8-byte beats
            m_axi_arburst <= 2'b01;   // INCR
            m_axi_rready  <= 1;
        end else begin
            // When inference starts, DMA will issue burst reads for activations.
            // For now: acknowledge any incoming read data silently.
            m_axi_rready <= 1;
            if (m_axi_arvalid && m_axi_arready)
                m_axi_arvalid <= 0;
        end
    end

endmodule
`default_nettype wire
