// =============================================================================
//  Synapse-RV — CPU AXI4 Master Stub  v1.1  [FIXED]
//  FIX: Proper AXI4 handshake (both AR+R and AW+W+B channels)
//  FIX: Boots from 0xFFFF_0000 (Boot ROM), then writes NPU CSRs, kicks inference
//  FIX: Added IRQ input so stub can poll/respond to NPU done interrupt
//
//  REPLACE THIS WITH: git clone https://github.com/openhwgroup/cva6
//  CVA6 drops in here with the same AXI4 master port interface.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module cpu_stub #(
    parameter ADDR_W = 32,
    parameter DATA_W = 64
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              irq,          // NPU done interrupt

    // AXI4 Read channels
    output reg  [ADDR_W-1:0] m_araddr,
    output reg  [3:0]        m_arid,
    output reg  [7:0]        m_arlen,
    output reg  [2:0]        m_arsize,
    output reg  [1:0]        m_arburst,
    output reg               m_arvalid,
    input  wire              m_arready,
    input  wire [DATA_W-1:0] m_rdata,
    input  wire [1:0]        m_rresp,
    input  wire              m_rlast,
    input  wire              m_rvalid,
    output reg               m_rready,

    // AXI4 Write channels
    output reg  [ADDR_W-1:0] m_awaddr,
    output reg  [3:0]        m_awid,
    output reg  [7:0]        m_awlen,
    output reg  [2:0]        m_awsize,
    output reg  [1:0]        m_awburst,
    output reg               m_awvalid,
    input  wire              m_awready,
    output reg  [DATA_W-1:0] m_wdata,
    output reg  [DATA_W/8-1:0] m_wstrb,
    output reg               m_wlast,
    output reg               m_wvalid,
    input  wire              m_wready,
    input  wire [1:0]        m_bresp,
    input  wire              m_bvalid,
    output reg               m_bready,

    // Debug: what the CPU is doing
    output reg [7:0]         dbg_state
);

    // ---- FSM ----
    localparam [4:0]
        BOOT_FETCH   = 5'd0,   // read first instruction from ROM
        BOOT_WAIT    = 5'd1,
        NPU_WR_ADDR  = 5'd2,   // write NPU TILE_CNT register
        NPU_WR_DATA  = 5'd3,
        NPU_WR_RESP  = 5'd4,
        NPU_WR_CMD_A = 5'd5,   // write NPU CMD = START
        NPU_WR_CMD_D = 5'd6,
        NPU_WR_CMD_R = 5'd7,
        WAIT_IRQ     = 5'd8,   // poll NPU STATUS (or wait for IRQ)


        TX_UART_A    = 5'd9,
        TX_UART_D    = 5'd10,
        TX_UART_R    = 5'd11,
        READ_STATUS_A= 5'd12,
        READ_STATUS_D= 5'd13,
        DONE         = 5'd14;

    reg [4:0] state;
    reg [7:0] boot_words_read;

    // NPU base address
    localparam NPU_BASE     = 32'hC000_0000;
    localparam NPU_TILE_CNT = NPU_BASE + 32'h4;
    localparam NPU_CMD      = NPU_BASE + 32'h0;
    localparam NPU_STATUS   = NPU_BASE + 32'hC;
    localparam BOOT_ROM_BASE= 32'hFFFF_0000;
    localparam UART_THR     = 32'hF000_0000;  // UART Transmit Holding Reg

    always @(posedge clk) begin
        if (!rst_n) begin
            state           <= BOOT_FETCH;
            boot_words_read <= 0;
            m_araddr  <= BOOT_ROM_BASE;
            m_arid    <= 4'd0;
            m_arlen   <= 8'd0;
            m_arsize  <= 3'd3;        // 8-byte beats
            m_arburst <= 2'b01;       // INCR
            m_arvalid <= 1'b0;
            m_rready  <= 1'b1;
            m_awaddr  <= 32'd0;
            m_awid    <= 4'd0;
            m_awlen   <= 8'd0;
            m_awsize  <= 3'd2;        // 4-byte beats for CSR writes
            m_awburst <= 2'b01;
            m_awvalid <= 1'b0;
            m_wdata   <= 64'd0;
            m_wstrb   <= 8'hFF;
            m_wlast   <= 1'b1;
            m_wvalid  <= 1'b0;
            m_bready  <= 1'b1;
            dbg_state <= 8'd0;
        end else begin
            dbg_state <= {3'b0, state};

            case (state)
                // ---- Read a few words from Boot ROM ----
                BOOT_FETCH: begin
                    m_araddr  <= BOOT_ROM_BASE + {boot_words_read, 3'b000};
                    m_arvalid <= 1'b1;
                    state     <= BOOT_WAIT;
                end

                BOOT_WAIT: begin
                    if (m_arvalid && m_arready) m_arvalid <= 1'b0;
                    if (m_rvalid) begin
                        boot_words_read <= boot_words_read + 1;
                        if (boot_words_read >= 8'd7)
                            state <= NPU_WR_ADDR;   // done fetching, go configure NPU
                        else
                            state <= BOOT_FETCH;
                    end
                end

                // ---- Write NPU TILE_CNT = 1 ----
                NPU_WR_ADDR: begin
                    m_awaddr  <= NPU_TILE_CNT;
                    m_awvalid <= 1'b1;
                    state     <= NPU_WR_DATA;
                end

                NPU_WR_DATA: begin
                    if (m_awvalid && m_awready) begin
                        m_awvalid <= 1'b0;
                        m_wdata   <= 64'h0000_0001;
                        m_wstrb   <= 8'h0F;
                        m_wvalid  <= 1'b1;
                        m_wlast   <= 1'b1;
                        state     <= NPU_WR_RESP;
                    end
                end

                NPU_WR_RESP: begin
                    if (m_wvalid && m_wready)  m_wvalid <= 1'b0;
                    if (m_bvalid) state <= NPU_WR_CMD_A;
                end

                // ---- Write NPU CMD = 1 (START) ----
                NPU_WR_CMD_A: begin
                    m_awaddr  <= NPU_CMD;
                    m_awvalid <= 1'b1;
                    state     <= NPU_WR_CMD_D;
                end

                NPU_WR_CMD_D: begin
                    if (m_awvalid && m_awready) begin
                        m_awvalid <= 1'b0;
                        m_wdata   <= 64'h0000_0001;
                        m_wstrb   <= 8'h0F;
                        m_wvalid  <= 1'b1;
                        m_wlast   <= 1'b1;
                        state     <= NPU_WR_CMD_R;
                    end
                end

                NPU_WR_CMD_R: begin
                    if (m_wvalid && m_wready)  m_wvalid <= 1'b0;
                    if (m_bvalid) state <= WAIT_IRQ;
                end

                // ---- Wait for NPU IRQ, then read STATUS ----
                WAIT_IRQ: begin
                    if (irq) state <= TX_UART_A;
                end

                TX_UART_A: begin
                    m_awaddr  <= UART_THR;
                    m_awvalid <= 1'b1;
                    state     <= TX_UART_D;
                end

                TX_UART_D: begin
                    if (m_awvalid && m_awready) begin
                        m_awvalid <= 1'b0;
                        m_wdata   <= 64'h0000_0041;
                        m_wstrb   <= 8'h01;
                        m_wvalid  <= 1'b1;
                        m_wlast   <= 1'b1;
                        state     <= TX_UART_R;
                    end
                end

                TX_UART_R: begin
                    if (m_wvalid && m_wready) m_wvalid <= 1'b0;
                    if (m_bvalid) state <= READ_STATUS_A;
                end

                READ_STATUS_A: begin
                    m_araddr  <= NPU_STATUS;
                    m_arvalid <= 1'b1;
                    state     <= READ_STATUS_D;
                end

                READ_STATUS_D: begin
                    if (m_arvalid && m_arready) m_arvalid <= 1'b0;
                    if (m_rvalid) state <= DONE;
                end

                DONE: begin
                    // CPU stub halts — real CVA6 would continue executing
                    // m_rdata now holds NPU STATUS with done=1
                end

                default: state <= BOOT_FETCH;
            endcase
        end
    end

endmodule
`default_nettype wire
