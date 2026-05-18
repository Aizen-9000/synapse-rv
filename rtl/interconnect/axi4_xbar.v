// =============================================================================
//  Synapse-RV — AXI4 Crossbar Interconnect  v1.1  [FIXED]
//  FIX: Added complete AW/W/B write path (was read-only before)
//  FIX: Proper write response routing back to requesting master
//
//  3 Masters : [0]=CPU-D  [1]=NPU-DMA  [2]=CPU-I (read-only)
//  5 Slaves  : [0]=SRAM   [1]=DDR      [2]=NPU-CFG  [3]=PERIPH  [4]=BOOT-ROM
//
//  Address Map:
//    S0 SRAM     : 0x0000_0000 – 0x7FFF_FFFF
//    S1 DDR      : 0x8000_0000 – 0xBFFF_FFFF
//    S2 NPU-CFG  : 0xC000_0000 – 0xCFFF_FFFF
//    S3 PERIPH   : 0xF000_0000 – 0xFFFE_FFFF
//    S4 BOOT-ROM : 0xFFFF_0000 – 0xFFFF_FFFF  (highest priority)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module axi4_xbar #(
    parameter NM     = 3,
    parameter NS     = 5,
    parameter ADDR_W = 32,
    parameter DATA_W = 64,
    parameter ID_W   = 4
)(
    input  wire clk,
    input  wire rst_n,

    // ---- Master AR (read address) channels ----
    input  wire [NM*ID_W-1:0]    m_arid,
    input  wire [NM*ADDR_W-1:0]  m_araddr,
    input  wire [NM*8-1:0]       m_arlen,
    input  wire [NM*3-1:0]       m_arsize,
    input  wire [NM*2-1:0]       m_arburst,
    input  wire [NM-1:0]         m_arvalid,
    output reg  [NM-1:0]         m_arready,

    // ---- Master R (read data) channels ----
    output reg  [NM*DATA_W-1:0]  m_rdata,
    output reg  [NM*2-1:0]       m_rresp,
    output reg  [NM*ID_W-1:0]    m_rid,
    output reg  [NM-1:0]         m_rlast,
    output reg  [NM-1:0]         m_rvalid,
    input  wire [NM-1:0]         m_rready,

    // ---- Master AW (write address) channels ----
    input  wire [NM*ID_W-1:0]    m_awid,
    input  wire [NM*ADDR_W-1:0]  m_awaddr,
    input  wire [NM*8-1:0]       m_awlen,
    input  wire [NM*3-1:0]       m_awsize,
    input  wire [NM*2-1:0]       m_awburst,
    input  wire [NM-1:0]         m_awvalid,
    output reg  [NM-1:0]         m_awready,

    // ---- Master W (write data) channels ----
    input  wire [NM*DATA_W-1:0]  m_wdata,
    input  wire [NM*DATA_W/8-1:0] m_wstrb,
    input  wire [NM-1:0]         m_wlast,
    input  wire [NM-1:0]         m_wvalid,
    output reg  [NM-1:0]         m_wready,

    // ---- Master B (write response) channels ----
    output reg  [NM*2-1:0]       m_bresp,
    output reg  [NM*ID_W-1:0]    m_bid,
    output reg  [NM-1:0]         m_bvalid,
    input  wire [NM-1:0]         m_bready,

    // ---- Slave AR channels ----
    output reg  [NS*ID_W-1:0]    s_arid,
    output reg  [NS*ADDR_W-1:0]  s_araddr,
    output reg  [NS*8-1:0]       s_arlen,
    output reg  [NS*3-1:0]       s_arsize,
    output reg  [NS*2-1:0]       s_arburst,
    output reg  [NS-1:0]         s_arvalid,
    input  wire [NS-1:0]         s_arready,

    // ---- Slave R channels ----
    input  wire [NS*DATA_W-1:0]  s_rdata,
    input  wire [NS*2-1:0]       s_rresp,
    input  wire [NS*ID_W-1:0]    s_rid,
    input  wire [NS-1:0]         s_rlast,
    input  wire [NS-1:0]         s_rvalid,
    output reg  [NS-1:0]         s_rready,

    // ---- Slave AW channels ----
    output reg  [NS*ID_W-1:0]    s_awid,
    output reg  [NS*ADDR_W-1:0]  s_awaddr,
    output reg  [NS*8-1:0]       s_awlen,
    output reg  [NS*3-1:0]       s_awsize,
    output reg  [NS*2-1:0]       s_awburst,
    output reg  [NS-1:0]         s_awvalid,
    input  wire [NS-1:0]         s_awready,

    // ---- Slave W channels ----
    output reg  [NS*DATA_W-1:0]  s_wdata,
    output reg  [NS*DATA_W/8-1:0] s_wstrb,
    output reg  [NS-1:0]         s_wlast,
    output reg  [NS-1:0]         s_wvalid,
    input  wire [NS-1:0]         s_wready,

    // ---- Slave B channels ----
    input  wire [NS*2-1:0]       s_bresp,
    input  wire [NS*ID_W-1:0]    s_bid,
    input  wire [NS-1:0]         s_bvalid,
    output reg  [NS-1:0]         s_bready
);

    // =========================================================
    // Address decode function
    // Returns one-hot slave index for a given address.
    // Priority: highest slave index wins on overlap.
    // =========================================================
    function automatic [NS-1:0] decode;
        input [ADDR_W-1:0] addr;
        reg [NS-1:0] hit;
        begin
            hit = {NS{1'b0}};
            // S4: Boot ROM  0xFFFF_0000–0xFFFF_FFFF
            if ((addr & 32'hFFFF_0000) == 32'hFFFF_0000) hit[4] = 1'b1;
            // S3: Periph    0xF000_0000–0xFFFE_FFFF
            else if ((addr & 32'hF000_0000) == 32'hF000_0000) hit[3] = 1'b1;
            // S2: NPU-CFG   0xC000_0000–0xCFFF_FFFF
            else if ((addr & 32'hF000_0000) == 32'hC000_0000) hit[2] = 1'b1;
            else if ((addr & 32'hF000_0000) == 32'hD000_0000) hit[5] = 1'b1;
            else if ((addr & 32'hF000_0000) == 32'hE000_0000) hit[6] = 1'b1;
            else if ((addr & 32'hE000_0000) == 32'h20000000) hit[7] = 1'b1;
            else if ((addr & 32'hF000_0000) == 32'hA000_0000) hit[8] = 1'b1;
            else if ((addr & 32'hFFFF_F000) == 32'hB000_0000) hit[9] = 1'b1;
            // S1: DDR       0x8000_0000–0xBFFF_FFFF
            else if (addr[31]) hit[1] = 1'b1;
            // S0: SRAM      0x0000_0000–0x7FFF_FFFF
            else               hit[0] = 1'b1;
            decode = hit;
        end
    endfunction

    // =========================================================
    // Read path arbitration (AR + R channels)
    // =========================================================
    reg [$clog2(NM)-1:0] ar_rr [0:NS-1];
    reg [NS-1:0] decode_tmp;   // round-robin pointer per slave
    reg [NM-1:0]         ar_grant [0:NS-1]; // which master owns each slave

    integer si, mi, mi2;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_arready <= {NM{1'b0}};
            s_arvalid <= {NS{1'b0}};
            m_rvalid  <= {NM{1'b0}};
            s_rready  <= {NS{1'b1}};
            for (si = 0; si < NS; si = si+1) begin
                ar_rr[si]    <= 0;
                ar_grant[si] <= {NM{1'b0}};
            end
        end else begin
            // Default deassert
            m_arready <= {NM{1'b0}};
            s_arvalid <= {NS{1'b0}};
            m_rvalid  <= {NM{1'b0}};

            // AR routing: for each slave, pick next requesting master (round-robin)
            for (si = 0; si < NS; si = si+1) begin
                if (!s_arvalid[si]) begin  // slave port is free
                    for (mi = 0; mi < NM; mi = mi+1) begin
                        mi2 = (ar_rr[si] + mi) % NM;
                        decode_tmp = decode(m_araddr[mi2*ADDR_W +: ADDR_W]);
                        if (m_arvalid[mi2] && decode_tmp[si] && !s_arvalid[si]) begin
                            s_arid   [si*ID_W   +: ID_W  ] <= m_arid   [mi2*ID_W   +: ID_W  ];
                            s_araddr [si*ADDR_W +: ADDR_W] <= m_araddr [mi2*ADDR_W +: ADDR_W];
                            s_arlen  [si*8      +: 8     ] <= m_arlen  [mi2*8      +: 8     ];
                            s_arsize [si*3      +: 3     ] <= m_arsize [mi2*3      +: 3     ];
                            s_arburst[si*2      +: 2     ] <= m_arburst[mi2*2      +: 2     ];
                            s_arvalid[si]                  <= 1'b1;
                            ar_grant[si]                   <= ({NM{1'b0}} | ({{(NM-1){1'b0}},1'b1} << mi2));
                            m_arready[mi2]                 <= s_arready[si];
                            if (s_arready[si])
                                ar_rr[si] <= ((mi2 + 1) % NM);
                        end
                    end
                end
            end

            // R routing: return read data to the master that owns this slave
            for (si = 0; si < NS; si = si+1) begin
                s_rready[si] <= 1'b1;
                if (s_rvalid[si]) begin
                    for (mi = 0; mi < NM; mi = mi+1) begin
                        if (ar_grant[si][mi]) begin
                            m_rdata [mi*DATA_W +: DATA_W] <= s_rdata[si*DATA_W +: DATA_W];
                            m_rresp [mi*2      +: 2     ] <= s_rresp[si*2      +: 2     ];
                            m_rid   [mi*ID_W   +: ID_W  ] <= s_rid  [si*ID_W   +: ID_W  ];
                            m_rlast [mi]                  <= s_rlast[si];
                            m_rvalid[mi]                  <= 1'b1;
                            s_rready[si]                  <= m_rready[mi];
                        end
                    end
                end
            end
        end
    end

    // =========================================================
    // Write path arbitration (AW + W + B channels)
    // =========================================================
    reg [$clog2(NM)-1:0] aw_rr [0:NS-1];
    reg [NM-1:0]         aw_grant [0:NS-1];
    reg [NS-1:0]         aw_active;  // slave currently in a write transaction

    always @(posedge clk) begin
        if (!rst_n) begin
            m_awready <= {NM{1'b0}};
            m_wready  <= {NM{1'b0}};
            m_bvalid  <= {NM{1'b0}};
            s_awvalid <= {NS{1'b0}};
            s_wvalid  <= {NS{1'b0}};
            s_bready  <= {NS{1'b1}};
            aw_active <= {NS{1'b0}};
            for (si = 0; si < NS; si = si+1) begin
                aw_rr[si]    <= 0;
                aw_grant[si] <= {NM{1'b0}};
            end
        end else begin
            m_awready <= {NM{1'b0}};
            m_wready  <= {NM{1'b0}};
            m_bvalid  <= {NM{1'b0}};
            s_awvalid <= {NS{1'b0}};
            s_wvalid  <= {NS{1'b0}};

            // AW routing
            for (si = 0; si < NS; si = si+1) begin
                if (!aw_active[si]) begin
                    for (mi = 0; mi < NM; mi = mi+1) begin
                        mi2 = (aw_rr[si] + mi) % NM;
                        decode_tmp = decode(m_awaddr[mi2*ADDR_W +: ADDR_W]);
                        if (m_awvalid[mi2] && decode_tmp[si] && !s_awvalid[si]) begin
                            s_awid   [si*ID_W   +: ID_W  ] <= m_awid   [mi2*ID_W   +: ID_W  ];
                            s_awaddr [si*ADDR_W +: ADDR_W] <= m_awaddr [mi2*ADDR_W +: ADDR_W];
                            s_awlen  [si*8      +: 8     ] <= m_awlen  [mi2*8      +: 8     ];
                            s_awsize [si*3      +: 3     ] <= m_awsize [mi2*3      +: 3     ];
                            s_awburst[si*2      +: 2     ] <= m_awburst[mi2*2      +: 2     ];
                            s_awvalid[si]                  <= 1'b1;
                            aw_grant[si]                   <= ({NM{1'b0}} | ({{(NM-1){1'b0}},1'b1} << mi2));
                            m_awready[mi2]                 <= s_awready[si];
                            if (s_awready[si]) begin
                                aw_active[si] <= 1'b1;
                                aw_rr[si] <= ((mi2 + 1) % NM);
                            end
                        end
                    end
                end
            end

            // W routing: forward write data to the active slave
            for (si = 0; si < NS; si = si+1) begin
                if (aw_active[si]) begin
                    for (mi = 0; mi < NM; mi = mi+1) begin
                        if (aw_grant[si][mi] && m_wvalid[mi]) begin
                            s_wdata [si*DATA_W     +: DATA_W  ] <= m_wdata [mi*DATA_W     +: DATA_W  ];
                            s_wstrb [si*DATA_W/8   +: DATA_W/8] <= m_wstrb [mi*DATA_W/8   +: DATA_W/8];
                            s_wlast [si]                        <= m_wlast [mi];
                            s_wvalid[si]                        <= 1'b1;
                            m_wready[mi]                        <= s_wready[si];
                        end
                    end
                end
            end

            // B routing: return write response to master
            for (si = 0; si < NS; si = si+1) begin
                s_bready[si] <= 1'b1;
                if (s_bvalid[si] && aw_active[si]) begin
                    for (mi = 0; mi < NM; mi = mi+1) begin
                        if (aw_grant[si][mi]) begin
                            m_bresp [mi*2    +: 2   ] <= s_bresp[si*2    +: 2   ];
                            m_bid   [mi*ID_W +: ID_W] <= s_bid  [si*ID_W +: ID_W];
                            m_bvalid[mi]              <= 1'b1;
                            s_bready[si]              <= m_bready[mi];
                            if (m_bready[mi])
                                aw_active[si] <= 1'b0;  // transaction complete
                        end
                    end
                end
            end
        end
    end

endmodule
`default_nettype wire
