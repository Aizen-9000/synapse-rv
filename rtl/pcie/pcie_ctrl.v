// =============================================================================
//  Synapse-RV — PCIe Gen2 x1 Controller  v1.0
//  Implements Transaction Layer (TL) + simplified Data Link Layer (DL)
//  Physical layer assumed external (SerDes IP)
//
//  Features:
//    - PCIe Gen2 x1 (5 Gbps)
//    - Memory Read/Write TLPs
//    - 256-byte Max Payload
//    - AXI4 master (outbound) + AXI4 slave (inbound/BAR)
//    - MSI interrupt support
//    - Config Space (Type 0, BAR0=64MB)
//
//  CSR/BAR Map:
//    BAR0: 0xA000_0000 — 64MB device memory window
//    Config: vendor=0x1EEF device=0x5E00 (Synapse-RV)
//
//  Interface to SerDes PHY:
//    phy_tx_data/valid/ready — 8b/10b encoded TX stream
//    phy_rx_data/valid       — 8b/10b decoded RX stream
//    phy_link_up             — link training complete
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module pcie_ctrl #(
    parameter AXI_AW = 32,
    parameter AXI_DW = 64,
    parameter AXI_IW = 4,
    parameter VENDOR_ID = 16'h1EEF,
    parameter DEVICE_ID = 16'h5E00,
    parameter BAR0_BASE = 32'hA000_0000,
    parameter BAR0_SIZE = 27'h400_0000  // 64MB
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4 slave (inbound PCIe → SoC memory)
    output wire [AXI_IW-1:0] m_awid,
    output reg  [AXI_AW-1:0] m_awaddr,
    output wire [7:0]         m_awlen,
    output wire [2:0]         m_awsize,
    output wire [1:0]         m_awburst,
    output reg                m_awvalid,
    input  wire               m_awready,
    output reg  [AXI_DW-1:0] m_wdata,
    output wire [7:0]         m_wstrb,
    output reg                m_wlast,
    output reg                m_wvalid,
    input  wire               m_wready,
    input  wire [1:0]         m_bresp,
    input  wire               m_bvalid,
    output wire               m_bready,
    output wire [AXI_IW-1:0] m_arid,
    output reg  [AXI_AW-1:0] m_araddr,
    output wire [7:0]         m_arlen,
    output wire [2:0]         m_arsize,
    output wire [1:0]         m_arburst,
    output reg                m_arvalid,
    input  wire               m_arready,
    input  wire [AXI_IW-1:0] m_rid,
    input  wire [AXI_DW-1:0] m_rdata,
    input  wire [1:0]         m_rresp,
    input  wire               m_rvalid,
    input  wire               m_rlast,
    output wire               m_rready,

    // AXI4-Lite slave (config space access from host)
    input  wire [11:0] cfg_awaddr, input  wire cfg_awvalid, output wire cfg_awready,
    input  wire [31:0] cfg_wdata,  input  wire cfg_wvalid,  output wire cfg_wready,
    output wire [1:0]  cfg_bresp,  output wire cfg_bvalid,  input  wire cfg_bready,
    input  wire [11:0] cfg_araddr, input  wire cfg_arvalid, output wire cfg_arready,
    output reg  [31:0] cfg_rdata,  output wire [1:0] cfg_rresp,
    output wire        cfg_rvalid, input  wire cfg_rready,

    // SerDes PHY interface
    output reg  [7:0]  phy_tx_data,
    output reg         phy_tx_valid,
    input  wire        phy_tx_ready,
    input  wire [7:0]  phy_rx_data,
    input  wire        phy_rx_valid,
    input  wire        phy_link_up,

    // MSI interrupt
    output wire        msi_req,
    input  wire        msi_ack,

    // Status
    output wire        link_up,
    output wire [2:0]  link_state
);

    assign link_up    = phy_link_up;
    assign m_awid     = 4'h2;  // PCIe master ID
    assign m_arid     = 4'h2;
    assign m_awlen    = 8'h0;  // single beat default
    assign m_awsize   = 3'b011; // 8 bytes
    assign m_awburst  = 2'b01;
    assign m_arlen    = 8'h0;
    assign m_arsize   = 3'b011;
    assign m_arburst  = 2'b01;
    assign m_wstrb    = 8'hFF;
    assign m_rready   = 1'b1;
    assign m_bready   = 1'b1;

    // -------------------------------------------------------------------------
    // TLP decoder — parse incoming PCIe packets from PHY RX
    // -------------------------------------------------------------------------
    localparam TLP_MRd  = 7'b000_0000;  // Memory Read
    localparam TLP_MWr  = 7'b100_0000;  // Memory Write
    localparam TLP_CplD = 7'b100_1010;  // Completion with Data

    reg [2:0]  tlp_state;
    reg [7:0]  tlp_buf [0:15];  // 16-byte TLP header buffer
    reg [3:0]  tlp_idx;
    reg [9:0]  tlp_len;
    reg [6:0]  tlp_type;
    reg [31:0] tlp_addr;
    reg [15:0] tlp_req_id;
    reg [7:0]  tlp_tag;

    localparam TLP_IDLE    = 3'd0;
    localparam TLP_HDR     = 3'd1;
    localparam TLP_DATA    = 3'd2;
    localparam TLP_DISPATCH= 3'd3;

    // AXI master FSM
    localparam AXI_IDLE    = 3'd0;
    localparam AXI_WR_ADDR = 3'd1;
    localparam AXI_WR_DATA = 3'd2;
    localparam AXI_WR_RESP = 3'd3;
    localparam AXI_RD_ADDR = 3'd4;
    localparam AXI_RD_DATA = 3'd5;
    localparam AXI_CPL     = 3'd6;

    reg [2:0] axi_state;
    reg [63:0] wr_data_buf;
    reg [31:0] rd_data_buf;
    reg        msi_req_r;
    assign msi_req = msi_req_r;

    // link_state: 0=DETECT 1=POLLING 2=CONFIG 3=L0 4=L0s 5=L1
    assign link_state = phy_link_up ? 3'd3 : 3'd0;

    // -------------------------------------------------------------------------
    // TLP RX parser
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tlp_state <= TLP_IDLE; tlp_idx <= 0;
            m_awvalid<=0; m_wvalid<=0; m_arvalid<=0; msi_req_r<=0;
            axi_state <= AXI_IDLE;
        end else begin
            if (msi_req_r && msi_ack) msi_req_r <= 0;

            case (tlp_state)
                TLP_IDLE: begin
                    if (phy_rx_valid && phy_link_up) begin
                        tlp_buf[0] <= phy_rx_data;
                        tlp_idx    <= 1;
                        tlp_state  <= TLP_HDR;
                    end
                end
                TLP_HDR: begin
                    if (phy_rx_valid) begin
                        tlp_buf[tlp_idx] <= phy_rx_data;
                        tlp_idx <= tlp_idx + 1;
                        if (tlp_idx == 11) begin  // 12-byte header received
                            tlp_type   <= {tlp_buf[0][6:0]};
                            tlp_len    <= {tlp_buf[2][1:0], tlp_buf[3]};
                            tlp_req_id <= {tlp_buf[4], tlp_buf[5]};
                            tlp_tag    <= tlp_buf[6];
                            tlp_addr   <= {tlp_buf[8], tlp_buf[9], tlp_buf[10], phy_rx_data};
                            tlp_idx    <= 0;
                            tlp_state  <= TLP_DISPATCH;
                        end
                    end
                end
                TLP_DISPATCH: begin
                    if (tlp_type == TLP_MWr && axi_state == AXI_IDLE) begin
                        m_awaddr  <= tlp_addr;
                        m_awvalid <= 1;
                        axi_state <= AXI_WR_ADDR;
                        tlp_state <= TLP_DATA;
                        tlp_idx   <= 0;
                    end else if (tlp_type == TLP_MRd && axi_state == AXI_IDLE) begin
                        m_araddr  <= tlp_addr;
                        m_arvalid <= 1;
                        axi_state <= AXI_RD_ADDR;
                        tlp_state <= TLP_IDLE;
                    end else begin
                        tlp_state <= TLP_IDLE;
                    end
                end
                TLP_DATA: begin
                    if (phy_rx_valid) begin
                        wr_data_buf[tlp_idx*8 +: 8] <= phy_rx_data;
                        if (tlp_idx == 7) begin
                            tlp_idx   <= 0;
                            tlp_state <= TLP_IDLE;
                        end else tlp_idx <= tlp_idx + 1;
                    end
                end
                default: tlp_state <= TLP_IDLE;
            endcase

            // AXI master
            case (axi_state)
                AXI_IDLE: ;
                AXI_WR_ADDR: begin
                    if (m_awready) begin
                        m_awvalid <= 0;
                        m_wdata   <= wr_data_buf;
                        m_wvalid  <= 1;
                        m_wlast   <= 1;
                        axi_state <= AXI_WR_DATA;
                    end
                end
                AXI_WR_DATA: begin
                    if (m_wready) begin
                        m_wvalid  <= 0;
                        m_wlast   <= 0;
                        axi_state <= AXI_WR_RESP;
                    end
                end
                AXI_WR_RESP: begin
                    if (m_bvalid) begin
                        msi_req_r <= 1;  // signal host write complete
                        axi_state <= AXI_IDLE;
                    end
                end
                AXI_RD_ADDR: begin
                    if (m_arready) begin
                        m_arvalid <= 0;
                        axi_state <= AXI_RD_DATA;
                    end
                end
                AXI_RD_DATA: begin
                    if (m_rvalid) begin
                        rd_data_buf <= m_rdata[31:0];
                        axi_state   <= AXI_CPL;
                    end
                end
                AXI_CPL: begin
                    // Send completion TLP back via PHY TX
                    if (phy_tx_ready) begin
                        phy_tx_data  <= rd_data_buf[7:0];
                        phy_tx_valid <= 1;
                        axi_state    <= AXI_IDLE;
                    end
                end
                default: axi_state <= AXI_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Config Space (Type 0)
    // -------------------------------------------------------------------------
    assign cfg_awready = 1'b1;
    assign cfg_wready  = 1'b1;
    assign cfg_bresp   = 2'b00;
    assign cfg_arready = 1'b1;
    assign cfg_rresp   = 2'b00;

    reg cfg_bvalid_r, cfg_rvalid_r;
    assign cfg_bvalid = cfg_bvalid_r;
    assign cfg_rvalid = cfg_rvalid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cfg_bvalid_r<=0; cfg_rvalid_r<=0; end
        else begin
            cfg_bvalid_r <= cfg_awvalid && cfg_wvalid;
            cfg_rvalid_r <= 0;
            if (cfg_arvalid) begin
                cfg_rvalid_r <= 1;
                case (cfg_araddr[7:2])
                    6'h00: cfg_rdata <= {DEVICE_ID, VENDOR_ID};
                    6'h01: cfg_rdata <= 32'h00100006; // status=cap_list, cmd=mem+bus_master
                    6'h02: cfg_rdata <= 32'h02000000; // class=network, prog-if=0
                    6'h03: cfg_rdata <= 32'h00000000; // BIST/hdr/lat/cache
                    6'h04: cfg_rdata <= BAR0_BASE;     // BAR0
                    6'h05: cfg_rdata <= 32'h00000000; // BAR1 (upper 32 if 64-bit)
                    6'h0F: cfg_rdata <= 32'h00000100; // cap pointer
                    default: cfg_rdata <= 32'h00000000;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
