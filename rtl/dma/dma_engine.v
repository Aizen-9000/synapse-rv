// =============================================================================
//  Synapse-RV — DMA Engine  v1.0
//  4-channel scatter-gather DMA
//  AXI4 master (memory), AXI4-Lite slave (CSR)
//
//  CSR Map (base=0xE000_0000):
//    0x00 : CH_SEL     — active channel [1:0]
//    0x04 : SRC_ADDR   — source address
//    0x08 : DST_ADDR   — destination address
//    0x0C : LEN        — transfer length in bytes
//    0x10 : CTRL       — [0]=start [1]=irq_en [2]=circ_mode
//    0x14 : STATUS     — [3:0]=ch_done [7:4]=ch_busy
//    0x18 : BURST_LEN  — AXI burst length (default 15 = 16 beats)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module dma_engine #(
    parameter N_CH  = 4,
    parameter AW    = 32,
    parameter DW    = 32
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite slave (CSR)
    input  wire [11:0] s_awaddr,  input  wire s_awvalid, output wire s_awready,
    input  wire [31:0] s_wdata,   input  wire s_wvalid,  output wire s_wready,
    input  wire [3:0]  s_wstrb,
    output wire [1:0]  s_bresp,   output wire s_bvalid,  input  wire s_bready,
    input  wire [11:0] s_araddr,  input  wire s_arvalid, output wire s_arready,
    output wire [31:0] s_rdata,   output wire [1:0] s_rresp,
    output wire        s_rvalid,  input  wire s_rready,

    // AXI4 master (memory read)
    output reg  [31:0] m_araddr,  output reg        m_arvalid, input wire m_arready,
    output reg  [7:0]  m_arlen,   output reg  [2:0] m_arsize,
    output wire [1:0]  m_arburst,
    input  wire [31:0] m_rdata,   input  wire        m_rvalid,
    input  wire        m_rlast,   output wire        m_rready,
    input  wire [1:0]  m_rresp,

    // AXI4 master (memory write)
    output reg  [31:0] m_awaddr,  output reg        m_awvalid, input wire m_awready,
    output reg  [7:0]  m_awlen,   output reg  [2:0] m_awsize,
    output wire [1:0]  m_awburst,
    output reg  [31:0] m_wdata,   output reg        m_wvalid,
    output reg         m_wlast,   input  wire        m_wready,
    output wire [3:0]  m_wstrb,
    input  wire [1:0]  m_bresp,   input  wire        m_bvalid,
    output wire        m_bready,

    // IRQ — one per channel
    output wire [N_CH-1:0] dma_irq
);

    // -------------------------------------------------------------------------
    // AXI defaults
    // -------------------------------------------------------------------------
    assign m_arburst = 2'b01;  // INCR
    assign m_awburst = 2'b01;
    assign m_arsize  = 3'b010; // 4 bytes
    assign m_awsize  = 3'b010;
    assign m_wstrb   = 4'hF;
    assign m_rready  = 1'b1;
    assign m_bready  = 1'b1;

    // -------------------------------------------------------------------------
    // Channel registers
    // -------------------------------------------------------------------------
    reg [31:0] src_addr [0:N_CH-1];
    reg [31:0] dst_addr [0:N_CH-1];
    reg [31:0] xfer_len [0:N_CH-1];
    reg [31:0] burst_len[0:N_CH-1];
    reg [N_CH-1:0] irq_en;
    reg [N_CH-1:0] circ_mode;
    reg [N_CH-1:0] ch_start;
    reg [N_CH-1:0] ch_busy;
    reg [N_CH-1:0] ch_done;

    // -------------------------------------------------------------------------
    // AXI4-Lite CSR
    // -------------------------------------------------------------------------
    reg [1:0]  ch_sel;
    assign s_awready = 1'b1;
    assign s_wready  = 1'b1;
    assign s_bresp   = 2'b00;
    assign s_arready = 1'b1;
    assign s_rresp   = 2'b00;

    reg s_bvalid_r, s_rvalid_r;
    reg [31:0] s_rdata_r;
    assign s_bvalid = s_bvalid_r;
    assign s_rvalid = s_rvalid_r;
    assign s_rdata  = s_rdata_r;

    integer ci;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch_sel <= 0; s_bvalid_r <= 0; s_rvalid_r <= 0;
            for (ci=0; ci<N_CH; ci=ci+1) begin
                src_addr[ci]  <= 0; dst_addr[ci] <= 0;
                xfer_len[ci]  <= 0; burst_len[ci]<= 32'hF;
                irq_en[ci[1:0]]    <= 0; circ_mode[ci[1:0]]<= 0;
                ch_start[ci[1:0]]  <= 0;
            end
        end else begin
            s_bvalid_r <= 0; s_rvalid_r <= 0;
            // Clear start pulse
            for (ci=0; ci<N_CH; ci=ci+1)
                if (ch_start[ci[1:0]]) ch_start[ci[1:0]] <= 0;

            if (s_awvalid && s_wvalid) begin
                case (s_awaddr[4:2])
                    3'h0: ch_sel             <= s_wdata[1:0];
                    3'h1: src_addr[ch_sel]   <= s_wdata;
                    3'h2: dst_addr[ch_sel]   <= s_wdata;
                    3'h3: xfer_len[ch_sel]   <= s_wdata;
                    3'h4: begin
                        if (s_wdata[0]) ch_start[ch_sel] <= 1'b1;
                        irq_en[ch_sel]   <= s_wdata[1];
                        circ_mode[ch_sel]<= s_wdata[2];
                    end
                    3'h6: burst_len[ch_sel]  <= s_wdata;
                    default: ;
                endcase
                s_bvalid_r <= 1;
            end
            if (s_arvalid) begin
                case (s_araddr[4:2])
                    3'h0: s_rdata_r <= {30'h0, ch_sel};
                    3'h1: s_rdata_r <= src_addr[ch_sel];
                    3'h2: s_rdata_r <= dst_addr[ch_sel];
                    3'h3: s_rdata_r <= xfer_len[ch_sel];
                    3'h4: s_rdata_r <= {29'h0, circ_mode[ch_sel],
                                         irq_en[ch_sel], ch_busy[ch_sel]};
                    3'h5: s_rdata_r <= {{(28){1'b0}}, ch_busy, ch_done};
                    3'h6: s_rdata_r <= burst_len[ch_sel];
                    default: s_rdata_r <= 32'hDEAD_C0DE;
                endcase
                s_rvalid_r <= 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // DMA FSM — simple round-robin channel arbiter
    // -------------------------------------------------------------------------
    localparam DMA_IDLE   = 3'd0;
    localparam DMA_RD_REQ = 3'd1;
    localparam DMA_RD_DAT = 3'd2;
    localparam DMA_WR_REQ = 3'd3;
    localparam DMA_WR_DAT = 3'd4;
    localparam DMA_WR_RSP = 3'd5;
    localparam DMA_DONE   = 3'd6;

    reg [2:0]  state;
    reg [1:0]  active_ch;
    reg [31:0] bytes_left;
    reg [31:0] cur_src, cur_dst;
    reg [7:0]  beat_cnt;
    reg [31:0] rd_buf [0:15];  // 16-beat burst buffer
    reg [3:0]  rd_idx, wr_idx;

    // Find next ready channel
    reg [1:0] next_ch;
    always @(*) begin
        next_ch = active_ch;
        if      (ch_start[0]) next_ch = 2'd0;
        else if (ch_start[1]) next_ch = 2'd1;
        else if (ch_start[2]) next_ch = 2'd2;
        else if (ch_start[3]) next_ch = 2'd3;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= DMA_IDLE; active_ch <= 0;
            m_arvalid <= 0; m_awvalid <= 0; m_wvalid <= 0; m_wlast <= 0;
            for (ci=0; ci<N_CH; ci=ci+1) begin
                ch_busy[ci[1:0]] <= 0; ch_done[ci[1:0]] <= 0;
            end
        end else begin
            // Clear done flags after one cycle
            for (ci=0; ci<N_CH; ci=ci+1)
                if (ch_done[ci[1:0]] && !irq_en[ci[1:0]]) ch_done[ci[1:0]] <= 0;

            case (state)
                DMA_IDLE: begin
                    if (|ch_start) begin
                        active_ch           <= next_ch;
                        ch_busy[next_ch]    <= 1;
                        ch_done[next_ch]    <= 0;
                        cur_src             <= src_addr[next_ch];
                        cur_dst             <= dst_addr[next_ch];
                        bytes_left          <= xfer_len[next_ch];
                        state               <= DMA_RD_REQ;
                        rd_idx              <= 0;
                        wr_idx              <= 0;
                        beat_cnt            <= (xfer_len[next_ch] >= 64) ? 8'hF : 8'h0;
                        m_araddr            <= src_addr[next_ch];
                        m_arlen             <= (xfer_len[next_ch] >= 64) ? 8'hF : 8'h0;
                        m_arvalid           <= 1;
                    end
                end

                DMA_RD_REQ: begin
                    if (m_arready) begin
                        m_arvalid <= 0;
                        state     <= DMA_RD_DAT;
                        rd_idx    <= 0;
                    end
                end

                DMA_RD_DAT: begin
                    if (m_rvalid) begin
                        rd_buf[rd_idx] <= m_rdata;
                        rd_idx         <= rd_idx + 1;
                        if (m_rlast) begin
                            state     <= DMA_WR_REQ;
                            m_awaddr  <= cur_dst;
                            m_awlen   <= beat_cnt;
                            m_awvalid <= 1;
                            wr_idx    <= 0;
                        end
                    end
                end

                DMA_WR_REQ: begin
                    if (m_awready) begin
                        m_awvalid <= 0;
                        m_wdata   <= rd_buf[0];
                        m_wvalid  <= 1;
                        m_wlast   <= (beat_cnt == 0);
                        wr_idx    <= 1;
                        state     <= DMA_WR_DAT;
                    end
                end

                DMA_WR_DAT: begin
                    if (m_wready) begin
                        if (m_wlast) begin
                            m_wvalid <= 0;
                            state    <= DMA_WR_RSP;
                        end else begin
                            m_wdata  <= rd_buf[wr_idx];
                            m_wlast  <= (wr_idx == beat_cnt);
                            wr_idx   <= wr_idx + 1;
                        end
                    end
                end

                DMA_WR_RSP: begin
                    if (m_bvalid) begin
                        // Update pointers
                        cur_src    <= cur_src + ((32'h0 + beat_cnt + 1) << 2);
                        cur_dst    <= cur_dst + ((32'h0 + beat_cnt + 1) << 2);
                        bytes_left <= bytes_left - ((32'h0 + beat_cnt + 1) << 2);
                        if (bytes_left <= ((32'h0 + beat_cnt + 1) << 2)) begin
                            state <= DMA_DONE;
                        end else begin
                            // Next burst
                            m_araddr  <= cur_src + ((32'h0 + beat_cnt + 1) << 2);
                            m_arlen   <= (bytes_left >= 64) ? 8'hF : 8'h0;
                            beat_cnt  <= (bytes_left >= 64) ? 8'hF : 8'h0;
                            m_arvalid <= 1;
                            state     <= DMA_RD_REQ;
                            rd_idx    <= 0;
                        end
                    end
                end

                DMA_DONE: begin
                    ch_busy[active_ch] <= 0;
                    ch_done[active_ch] <= 1;
                    if (circ_mode[active_ch]) begin
                        // Restart from original addresses
                        cur_src    <= src_addr[active_ch];
                        cur_dst    <= dst_addr[active_ch];
                        bytes_left <= xfer_len[active_ch];
                        m_araddr   <= src_addr[active_ch];
                        m_arlen    <= (xfer_len[active_ch] >= 64) ? 8'hF : 8'h0;
                        m_arvalid  <= 1;
                        state      <= DMA_RD_REQ;
                    end else begin
                        state <= DMA_IDLE;
                    end
                end

                default: state <= DMA_IDLE;
            endcase
        end
    end

    // IRQ output
    genvar gi;
    generate
        for (gi=0; gi<N_CH; gi=gi+1) begin : irq_gen
            assign dma_irq[gi] = ch_done[gi] && irq_en[gi];
        end
    endgenerate

endmodule
`default_nettype wire
