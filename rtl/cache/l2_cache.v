// =============================================================================
//  Synapse-RV — L2 Cache Controller  v1.0
//  Direct-mapped, 64KB, 64-byte cache lines, write-back + write-allocate
//  512 sets × 1 way × 64 bytes/line = 32KB (configurable via parameters)
//
//  Interface:
//    Upstream  : AXI4 slave  (from CPU/NPU via xbar)
//    Downstream: AXI4 master (to SRAM/DDR)
//
//  Parameters:
//    CACHE_SIZE  = 65536  (64KB)
//    LINE_SIZE   = 64     (bytes, 16 × 32-bit words)
//    N_WAYS      = 1      (direct-mapped; extend to 4 for set-assoc)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module l2_cache #(
    parameter CACHE_SIZE = 4096,
    parameter LINE_SIZE  = 64,
    parameter N_SETS     = CACHE_SIZE / LINE_SIZE,   // 1024 sets
    parameter INDEX_W    = 6,    // log2(N_SETS)
    parameter OFFSET_W   = 6,    // log2(LINE_SIZE)
    parameter TAG_W      = 32 - INDEX_W - OFFSET_W, // 16 bits
    parameter WORDS      = LINE_SIZE / 4             // 16 words per line
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4 slave (upstream — from CPU/NPU)
    input  wire [31:0] s_araddr,  input  wire s_arvalid, output wire s_arready,
    output reg  [31:0] s_rdata,   output reg  s_rvalid,  input  wire s_rready,
    output wire [1:0]  s_rresp,
    input  wire [31:0] s_awaddr,  input  wire s_awvalid, output wire s_awready,
    input  wire [31:0] s_wdata,   input  wire s_wvalid,  output wire s_wready,
    input  wire [3:0]  s_wstrb,
    output wire [1:0]  s_bresp,   output wire s_bvalid,  input  wire s_bready,

    // AXI4 master (downstream — to SRAM/DDR)
    output reg  [31:0] m_araddr,  output reg  m_arvalid, input  wire m_arready,
    input  wire [31:0] m_rdata,   input  wire m_rvalid,  output wire m_rready,
    input  wire [1:0]  m_rresp,
    output reg  [31:0] m_awaddr,  output reg  m_awvalid, input  wire m_awready,
    output reg  [31:0] m_wdata,   output reg  m_wvalid,  output reg  m_wlast,
    output wire [3:0]  m_wstrb,   input  wire m_wready,
    input  wire [1:0]  m_bresp,   input  wire m_bvalid,  output wire m_bready,

    // Performance counters
    output reg [31:0]  hit_count,
    output reg [31:0]  miss_count
);

    assign s_rresp  = 2'b00;
    assign s_bresp  = 2'b00;
    assign m_rready = 1'b1;
    assign m_bready = 1'b1;
    assign m_wstrb  = 4'hF;

    // -------------------------------------------------------------------------
    // Cache arrays — tag, valid, dirty, data
    // -------------------------------------------------------------------------
    reg [TAG_W-1:0]      tag_arr   [0:N_SETS-1];
    reg                  valid_arr [0:N_SETS-1];
    reg                  dirty_arr [0:N_SETS-1];
    reg [31:0]           data_arr  [0:N_SETS-1][0:WORDS-1];

    // -------------------------------------------------------------------------
    // Address breakdown
    // -------------------------------------------------------------------------
    wire [TAG_W-1:0]    req_tag;
    wire [INDEX_W-1:0]  req_idx;
    wire [OFFSET_W-1:0] req_off;
    wire [31:0]         req_addr;

    reg is_write;
    reg [31:0] req_addr_r, req_wdata_r;
    reg [3:0]  req_wstrb_r;

    assign req_addr = req_addr_r;
    assign req_tag  = req_addr[31:OFFSET_W+INDEX_W];
    assign req_idx  = req_addr[OFFSET_W+INDEX_W-1:OFFSET_W];
    assign req_off  = req_addr[OFFSET_W-1:2];   // word offset

    wire hit = valid_arr[req_idx] && (tag_arr[req_idx] == req_tag);

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam S_IDLE      = 3'd0;
    localparam S_TAG_CHK   = 3'd1;
    localparam S_WB_ADDR   = 3'd2;   // write-back dirty line
    localparam S_WB_DATA   = 3'd3;
    localparam S_WB_RESP   = 3'd4;
    localparam S_FILL_ADDR = 3'd5;   // cache line fill
    localparam S_FILL_DATA = 3'd6;
    localparam S_RESPOND   = 3'd7;

    reg [2:0]  state;
    reg [3:0]  word_idx;
    reg [31:0] wb_base;   // base address of dirty line being written back

    assign s_arready = (state == S_IDLE);
    assign s_awready = (state == S_IDLE);
    assign s_wready  = (state == S_IDLE);

    reg s_bvalid_r;
    assign s_bvalid  = s_bvalid_r;

    integer si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; s_rvalid <= 0; s_bvalid_r <= 0;
            m_arvalid <= 0; m_awvalid <= 0; m_wvalid <= 0; m_wlast <= 0;
            hit_count <= 0; miss_count <= 0; word_idx <= 0; is_write <= 0;
            for (si=0; si<N_SETS; si=si+1) begin
                valid_arr[si] = 0; dirty_arr[si] = 0;
            end
        end else begin
            s_rvalid   <= 0;
            s_bvalid_r <= 0;

            case (state)
                S_IDLE: begin
                    if (s_awvalid && s_wvalid) begin
                        is_write    <= 1;
                        req_addr_r  <= s_awaddr;
                        req_wdata_r <= s_wdata;
                        req_wstrb_r <= s_wstrb;
                        state       <= S_TAG_CHK;
                    end else if (s_arvalid) begin
                        is_write    <= 0;
                        req_addr_r  <= s_araddr;
                        req_wdata_r <= 0;
                        req_wstrb_r <= 0;
                        state       <= S_TAG_CHK;
                    end
                end

                S_TAG_CHK: begin
                    if (hit) begin
                        hit_count <= hit_count + 1;
                        if (is_write) begin
                            // Write hit — update data and mark dirty
                            if (req_wstrb_r[0]) data_arr[req_idx][req_off][7:0]   <= req_wdata_r[7:0];
                            if (req_wstrb_r[1]) data_arr[req_idx][req_off][15:8]  <= req_wdata_r[15:8];
                            if (req_wstrb_r[2]) data_arr[req_idx][req_off][23:16] <= req_wdata_r[23:16];
                            if (req_wstrb_r[3]) data_arr[req_idx][req_off][31:24] <= req_wdata_r[31:24];
                            dirty_arr[req_idx] <= 1;
                            s_bvalid_r <= 1;
                            state      <= S_IDLE;
                        end else begin
                            // Read hit
                            s_rdata  <= data_arr[req_idx][req_off];
                            s_rvalid <= 1;
                            state    <= S_IDLE;
                        end
                    end else begin
                        // Miss
                        miss_count <= miss_count + 1;
                        if (dirty_arr[req_idx] && valid_arr[req_idx]) begin
                            // Write-back dirty line first
                            wb_base   <= {tag_arr[req_idx], req_idx, {OFFSET_W{1'b0}}};
                            word_idx  <= 0;
                            m_awaddr  <= {tag_arr[req_idx], req_idx, {OFFSET_W{1'b0}}};
                            m_awvalid <= 1;
                            state     <= S_WB_ADDR;
                        end else begin
                            // Fill directly
                            m_araddr  <= {req_addr[31:OFFSET_W], {OFFSET_W{1'b0}}};
                            m_arvalid <= 1;
                            word_idx  <= 0;
                            state     <= S_FILL_ADDR;
                        end
                    end
                end

                S_WB_ADDR: begin
                    if (m_awready) begin
                        m_awvalid <= 0;
                        m_wdata   <= data_arr[req_idx][0];
                        m_wvalid  <= 1;
                        m_wlast   <= (WORDS == 1);
                        word_idx  <= 1;
                        state     <= S_WB_DATA;
                    end
                end

                S_WB_DATA: begin
                    if (m_wready) begin
                        if (m_wlast) begin
                            m_wvalid <= 0;
                            m_wlast  <= 0;
                            state    <= S_WB_RESP;
                        end else begin
                            m_wdata  <= data_arr[req_idx][word_idx];
                            m_wlast  <= (word_idx == WORDS-1);
                            word_idx <= word_idx + 1;
                        end
                    end
                end

                S_WB_RESP: begin
                    if (m_bvalid) begin
                        dirty_arr[req_idx] <= 0;
                        m_araddr  <= {req_addr_r[31:OFFSET_W], {OFFSET_W{1'b0}}};
                        m_arvalid <= 1;
                        word_idx  <= 0;
                        state     <= S_FILL_ADDR;
                    end
                end

                S_FILL_ADDR: begin
                    if (m_arready) begin
                        m_arvalid <= 0;
                        state     <= S_FILL_DATA;
                    end
                end

                S_FILL_DATA: begin
                    if (m_rvalid) begin
                        data_arr[req_idx][word_idx[3:0]] <= m_rdata;
                        if (word_idx == 4'(WORDS-1)) begin
                            tag_arr[req_idx]   <= req_tag;
                            valid_arr[req_idx] <= 1;
                            dirty_arr[req_idx] <= 0;
                            word_idx           <= 0;
                            state              <= S_RESPOND;
                        end else begin
                            word_idx <= word_idx + 1;
                        end
                    end
                end

                S_RESPOND: begin
                    if (is_write) begin
                        if (req_wstrb_r[0]) data_arr[req_idx][req_off][7:0]   <= req_wdata_r[7:0];
                        if (req_wstrb_r[1]) data_arr[req_idx][req_off][15:8]  <= req_wdata_r[15:8];
                        if (req_wstrb_r[2]) data_arr[req_idx][req_off][23:16] <= req_wdata_r[23:16];
                        if (req_wstrb_r[3]) data_arr[req_idx][req_off][31:24] <= req_wdata_r[31:24];
                        dirty_arr[req_idx] <= 1;
                        s_bvalid_r <= 1;
                    end else begin
                        s_rdata  <= data_arr[req_idx][req_off];
                        s_rvalid <= 1;
                    end
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
