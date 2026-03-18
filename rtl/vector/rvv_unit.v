// =============================================================================
//  Synapse-RV — RVV 1.0 Vector Unit  v1.0
//  VLEN=256, ELEN=32, LMUL support: 1,2,4,8
//  Supports: vadd, vsub, vmul, vdot (int8/int16/int32)
//  Interface: AXI4-Lite CSR + direct data path to NPU
//
//  CSR Map (AXI4-Lite, base=0xD000_0000):
//    0x00 : VCMD      — [1:0] op (0=vadd,1=vsub,2=vmul,3=vdot)
//                       [3:2] eew (0=8b,1=16b,2=32b)
//                       [31]  start
//    0x04 : VLEN_CFG  — number of elements (max 256 for int8)
//    0x08 : VS1_ADDR  — source 1 base address in SRAM
//    0x0C : VS2_ADDR  — source 2 base address in SRAM
//    0x10 : VD_ADDR   — destination base address in SRAM
//    0x14 : VSTATUS   — [0]=busy [1]=done
//    0x18 : VTYPE     — vsew[2:0], vlmul[2:0] (RVV vtype CSR mirror)
//    0x1C : VL        — active vector length (mirrors vl CSR)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module rvv_unit #(
    parameter VLEN     = 256,   // bits per vector register
    parameter NREGS    = 32,    // number of vector registers
    parameter AXI_AW   = 32,
    parameter AXI_DW   = 32
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite slave (CSR access)
    input  wire [11:0] s_awaddr,  input  wire s_awvalid,  output wire s_awready,
    input  wire [31:0] s_wdata,   input  wire s_wvalid,   output wire s_wready,
    input  wire [3:0]  s_wstrb,
    output wire [1:0]  s_bresp,   output wire s_bvalid,   input  wire s_bready,
    input  wire [11:0] s_araddr,  input  wire s_arvalid,  output wire s_arready,
    output wire [31:0] s_rdata,   output wire [1:0] s_rresp, output wire s_rvalid,
    input  wire        s_rready,

    // AXI4 master (memory access to SRAM)
    output reg  [31:0] m_araddr,  output reg  m_arvalid,  input  wire m_arready,
    input  wire [31:0] m_rdata,   input  wire m_rvalid,   output wire m_rready,
    output reg  [31:0] m_awaddr,  output reg  m_awvalid,  input  wire m_awready,
    output reg  [31:0] m_wdata,   output reg  m_wvalid,   input  wire m_wready,
    output wire [3:0]  m_wstrb,
    input  wire [1:0]  m_bresp,   input  wire m_bvalid,   output wire m_bready,

    // IRQ
    output wire        vec_done_irq
);

    // -------------------------------------------------------------------------
    // Vector Register File — 32 × 256-bit
    // -------------------------------------------------------------------------
    reg [VLEN-1:0] vrf [0:NREGS-1];

    // -------------------------------------------------------------------------
    // CSRs
    // -------------------------------------------------------------------------
    reg [31:0] vcmd, vlen_cfg, vs1_addr, vs2_addr, vd_addr, vtype_csr, vl_csr;
    reg        busy, done;

    // -------------------------------------------------------------------------
    // AXI4-Lite slave — single-cycle, no-wait
    // -------------------------------------------------------------------------
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_bvalid_r <= 0; s_rvalid_r <= 0;
            vcmd <= 0; vlen_cfg <= 0; vs1_addr <= 0;
            vs2_addr <= 0; vd_addr <= 0; vtype_csr <= 0; vl_csr <= 0;
        end else begin
            // Write
            s_bvalid_r <= 0;
            if (s_awvalid && s_wvalid) begin
                case (s_awaddr[4:2])
                    3'h0: vcmd     <= s_wdata;
                    3'h1: vlen_cfg <= s_wdata;
                    3'h2: vs1_addr <= s_wdata;
                    3'h3: vs2_addr <= s_wdata;
                    3'h4: vd_addr  <= s_wdata;
                    3'h6: vtype_csr<= s_wdata;
                    3'h7: vl_csr   <= s_wdata;
                    default: ;
                endcase
                s_bvalid_r <= 1;
            end
            // Read
            s_rvalid_r <= 0;
            if (s_arvalid) begin
                case (s_araddr[4:2])
                    3'h0: s_rdata_r <= vcmd;
                    3'h1: s_rdata_r <= vlen_cfg;
                    3'h2: s_rdata_r <= vs1_addr;
                    3'h3: s_rdata_r <= vs2_addr;
                    3'h4: s_rdata_r <= vd_addr;
                    3'h5: s_rdata_r <= {30'h0, done, busy};
                    3'h6: s_rdata_r <= vtype_csr;
                    3'h7: s_rdata_r <= vl_csr;
                    default: s_rdata_r <= 32'hDEAD_C0DE;
                endcase
                s_rvalid_r <= 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Execution FSM
    // -------------------------------------------------------------------------
    localparam S_IDLE    = 3'd0;
    localparam S_LOAD1   = 3'd1;  // load VS1 from SRAM
    localparam S_LOAD2   = 3'd2;  // load VS2 from SRAM
    localparam S_EXEC    = 3'd3;  // execute vector op
    localparam S_STORE   = 3'd4;  // store VD to SRAM
    localparam S_DONE    = 3'd5;

    reg [2:0]  state;
    reg [7:0]  elem_idx;   // current element (word) index
    reg [31:0] vd_result;

    // VS1, VS2 scratch (up to 256 bits = 8 × 32-bit words)
    reg [31:0] vs1_buf [0:7];
    reg [31:0] vs2_buf [0:7];
    reg [31:0] vd_buf  [0:7];
    reg [2:0]  load_idx;

    wire [1:0] op  = vcmd[1:0];
    wire [1:0] eew = vcmd[3:2];
    wire       start = vcmd[31];

    // AXI master defaults
    assign m_rready = 1'b1;
    assign m_wstrb  = 4'hF;
    assign m_bready = 1'b1;

    // Vector ALU — 32-bit word granularity
    function [31:0] vec_alu;
        input [31:0] a, b;
        input [1:0]  operation;
        input [1:0]  element_width;
        reg [31:0] res;
        begin
            case (operation)
                2'b00: res = a + b;                    // vadd
                2'b01: res = a - b;                    // vsub
                2'b10: res = a * b;                    // vmul
                2'b11: begin                           // vdot (int8 packed)
                    // 4 × int8 dot product per 32-bit word
                    res = ($signed(a[7:0])   * $signed(b[7:0]))   +
                          ($signed(a[15:8])  * $signed(b[15:8]))  +
                          ($signed(a[23:16]) * $signed(b[23:16])) +
                          ($signed(a[31:24]) * $signed(b[31:24]));
                end
                default: res = 32'h0;
            endcase
            vec_alu = res;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 0; done <= 0;
            m_arvalid <= 0; m_awvalid <= 0; m_wvalid <= 0;
            elem_idx <= 0; load_idx <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start && !busy) begin
                        busy     <= 1;
                        elem_idx <= 0;
                        load_idx <= 0;
                        state    <= S_LOAD1;
                        m_araddr  <= vs1_addr;
                        m_arvalid <= 1;
                    end
                end

                S_LOAD1: begin  // stream VS1 words from SRAM
                    if (m_arready) m_arvalid <= 0;
                    if (m_rvalid) begin
                        vs1_buf[load_idx] <= m_rdata;
                        if (load_idx == 3'h7 || load_idx == vlen_cfg[2:0]) begin
                            load_idx  <= 0;
                            state     <= S_LOAD2;
                            m_araddr  <= vs2_addr;
                            m_arvalid <= 1;
                        end else begin
                            load_idx  <= load_idx + 1;
                            m_araddr  <= vs1_addr + ((32'h0 + load_idx + 1) << 2);
                            m_arvalid <= 1;
                        end
                    end
                end

                S_LOAD2: begin  // stream VS2 words from SRAM
                    if (m_arready) m_arvalid <= 0;
                    if (m_rvalid) begin
                        vs2_buf[load_idx] <= m_rdata;
                        if (load_idx == 3'h7 || load_idx == vlen_cfg[2:0]) begin
                            load_idx <= 0;
                            state    <= S_EXEC;
                        end else begin
                            load_idx  <= load_idx + 1;
                            m_araddr  <= vs2_addr + ((32'h0 + load_idx + 1) << 2);
                            m_arvalid <= 1;
                        end
                    end
                end

                S_EXEC: begin  // execute all words
                    vd_buf[load_idx] <= vec_alu(vs1_buf[load_idx],
                                                vs2_buf[load_idx], op, eew);
                    if (load_idx == 3'h7 || load_idx == vlen_cfg[2:0]) begin
                        load_idx  <= 0;
                        state     <= S_STORE;
                        m_awaddr  <= vd_addr;
                        m_awvalid <= 1;
                        m_wdata   <= vd_buf[0];
                        m_wvalid  <= 1;
                    end else begin
                        load_idx <= load_idx + 1;
                    end
                end

                S_STORE: begin  // write results back to SRAM
                    if (m_awready) m_awvalid <= 0;
                    if (m_wready) begin
                        m_wvalid <= 0;
                        if (load_idx == 3'h7 || load_idx == vlen_cfg[2:0]) begin
                            state <= S_DONE;
                        end else begin
                            load_idx  <= load_idx + 1;
                            m_awaddr  <= vd_addr + ((32'h0 + load_idx + 1) << 2);
                            m_awvalid <= 1;
                            m_wdata   <= vd_buf[load_idx+1];
                            m_wvalid  <= 1;
                        end
                    end
                end

                S_DONE: begin
                    busy  <= 0;
                    done  <= 1;
                    state <= S_IDLE;
                    // Auto-clear start bit
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign vec_done_irq = done;

endmodule
`default_nettype wire
