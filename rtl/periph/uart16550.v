`timescale 1ns/1ps
`default_nettype none
module uart16550 #(
    parameter APB_AW   = 8,
    parameter APB_DW   = 32,
    parameter FIFO_D   = 16,
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD_DEF = 115_200
)(
    input  wire              clk, rst_n,
    input  wire [APB_AW-1:0] paddr,
    input  wire              psel, penable, pwrite,
    input  wire [APB_DW-1:0] pwdata,
    output reg  [APB_DW-1:0] prdata,
    output wire              pready,
    output reg               tx,
    input  wire              rx,
    output wire              irq
);
    assign pready = 1'b1;
    reg [7:0]  ier, lcr, scr;
    reg [15:0] divisor;
    wire dlab = lcr[7];

    // baud16 tick
    reg [15:0] baud_cnt;
    reg        baud16;
    always @(posedge clk) begin
        if (!rst_n || baud_cnt == divisor - 1) begin
            baud_cnt <= 0;
            baud16   <= rst_n ? 1'b1 : 1'b0;
        end else begin
            baud_cnt <= baud_cnt + 1;
            baud16   <= 0;
        end
    end

    // TX FIFO
    reg [7:0] txf [0:FIFO_D-1];
    reg [$clog2(FIFO_D):0] txw, txr;
    wire txfull  = (txw - txr) == FIFO_D[$clog2(FIFO_D):0];
    wire txempty = (txw == txr);

    // TX shift engine  (owns txw, txr, txsr, txbits, txsub, tx)
    reg [9:0] txsr;
    reg [3:0] txbits, txsub;
    always @(posedge clk) begin
        if (!rst_n) begin
            tx<=1'b1; txbits<=0; txsub<=0; txr<=0; txw<=0; txsr<=10'h3FF;
        end else begin
            // APB write to THR (addr 0x00, DLAB=0)
            if (psel && penable && pwrite && (paddr[5:2]==4'h0) && !dlab && !txfull) begin
                txf[txw[$clog2(FIFO_D)-1:0]] <= pwdata[7:0];
                txw <= txw + 1;
            end
            // baud16 shift engine
            if (baud16) begin
                txsub <= txsub + 1;
                if (txsub == 4'd15) begin
                    if (txbits == 0) begin
                        if (!txempty) begin
                            txsr   <= {1'b1, txf[txr[$clog2(FIFO_D)-1:0]], 1'b0};
                            txr    <= txr + 1;
                            txbits <= 4'd10;
                        end
                    end else begin
                        tx     <= txsr[0];
                        txsr   <= {1'b1, txsr[9:1]};
                        txbits <= txbits - 1;
                    end
                end
            end
        end
    end

    // RX FIFO
    reg [7:0] rxf [0:FIFO_D-1];
    reg [$clog2(FIFO_D):0] rxw, rxr;
    wire rxfull  = (rxw - rxr) == FIFO_D[$clog2(FIFO_D):0];
    wire rxempty = (rxw == rxr);

    // RX engine: IDLE -> START(verify mid) -> DATA(8 bits) -> STOP -> commit
    reg [1:0] rx_sync;
    reg [1:0] rxstate;
    reg [7:0] rxsr;
    reg [3:0] rxbits, rxsub;
    reg       rxbusy;
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_sync<=2'b11; rxstate<=0; rxbusy<=0;
            rxbits<=0; rxsub<=0; rxw<=0; rxr<=0;
        end else begin
            rx_sync <= {rx_sync[0], rx};
            if (psel && penable && !pwrite && (paddr[5:2]==4'h0) && !dlab && !rxempty)
                rxr <= rxr + 1;
            if (baud16) begin
                case (rxstate)
                    2'd0: begin // IDLE
                        if (rx_sync[1] == 1'b0) begin
                            rxstate<=2'd1; rxsub<=1;
                        end
                    end
                    2'd1: begin // START - count to mid, verify still low
                        rxsub <= rxsub + 1;
                        if (rxsub == 4'd8) begin
                            if (rx_sync[1] == 1'b0) begin
                                rxstate<=2'd2; rxbits<=0; rxsub<=0;
                            end else begin
                                rxstate<=2'd0; // glitch, abort
                            end
                        end
                    end
                    2'd2: begin // DATA - sample 8 bits, one per 16 baud16 ticks
                        rxsub <= rxsub + 1;
                        if (rxsub == 4'd8) begin
                            rxsr   <= {rx_sync[1], rxsr[7:1]};
                            rxbits <= rxbits + 1;
                            if (rxbits == 4'd7) rxstate<=2'd3;
                        end
                    end
                    2'd3: begin // STOP - wait mid-stop then commit
                        rxsub <= rxsub + 1;
                        if (rxsub == 4'd8) begin
                            rxstate<=2'd0;
                            if (!rxfull) begin
                                rxf[rxw[$clog2(FIFO_D)-1:0]] <= rxsr;
                                rxw <= rxw + 1;
                            end
                        end
                    end
                endcase
            end
        end
    end

    // LSR: [5]=TX hold reg empty  [0]=RX data ready
    wire [7:0] lsr = {2'b00, txempty, 4'b0000, !rxempty};
    wire rx_irq = !rxempty & ier[0];
    wire tx_irq =  txempty & ier[1];
    assign irq  = rx_irq | tx_irq;
    wire [3:0] iir = tx_irq ? 4'b0010 : rx_irq ? 4'b0100 : 4'b0001;

    // APB reads (registered)
    always @(posedge clk) begin
        if (!rst_n) prdata <= 0;
        else if (psel && !penable && !pwrite) begin
            case (paddr[5:2])
                4'h0: prdata <= dlab ? {24'd0,divisor[7:0]}
                                     : {24'd0, rxempty ? 8'h00 : rxf[rxr[$clog2(FIFO_D)-1:0]]};
                4'h1: prdata <= dlab ? {24'd0,divisor[15:8]} : {24'd0,ier};
                4'h2: prdata <= {28'd0,iir};
                4'h3: prdata <= {24'd0,lcr};
                4'h5: prdata <= {24'd0,lsr};
                4'h7: prdata <= {24'd0,scr};
                default: prdata <= 32'd0;
            endcase
        end
    end

    // APB writes
    always @(posedge clk) begin
        if (!rst_n) begin
            ier<=0; lcr<=8'h03; scr<=0;
            divisor <= CLK_FREQ / (16 * BAUD_DEF);
        end else if (psel && penable && pwrite) begin
            case (paddr[5:2])
                4'h1: if (!dlab) ier <= pwdata[7:0]; else divisor[15:8] <= pwdata[7:0];
                4'h3: lcr <= pwdata[7:0];
                4'h7: scr <= pwdata[7:0];
                4'h0: if (dlab) divisor[7:0] <= pwdata[7:0];
                default: ;
            endcase
        end
    end
endmodule
`default_nettype wire
