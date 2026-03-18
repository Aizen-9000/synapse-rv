`timescale 1ns/1ps
module uart_tb;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;  // 50 MHz
    reg [7:0] paddr=0; reg psel=0,penable=0,pwrite=0;
    reg [31:0] pwdata=0;
    wire [31:0] prdata; wire pready;
    wire tx; reg rx=1; wire irq;

    uart16550 #(.APB_AW(8),.CLK_FREQ(50_000_000),.BAUD_DEF(115_200)) dut(
        .clk(clk),.rst_n(rst_n),.paddr(paddr),.psel(psel),.penable(penable),
        .pwrite(pwrite),.pwdata(pwdata),.prdata(prdata),.pready(pready),
        .tx(tx),.rx(rx),.irq(irq));

    initial begin $dumpfile("uart_waves.vcd"); $dumpvars(0,uart_tb); end

    integer pass=0, fail=0;
    task chk; input [31:0] g,e; input [127:0] n;
        begin if(g===e)begin $display("[PASS] %0s",n);pass=pass+1;end
        else begin $display("[FAIL] %0s got=%0h exp=%0h",n,g,e);fail=fail+1;end end
    endtask

    // APB write: setup on negedge, penable on next posedge
    task apb_wr; input [7:0] a; input [31:0] d;
        begin
            @(negedge clk); paddr=a; pwdata=d; pwrite=1; psel=1; penable=0;
            @(posedge clk); #1; penable=1;
            @(posedge clk); #1; psel=0; penable=0; pwrite=0;
            @(posedge clk);  // settle
        end
    endtask

    // APB read: prdata is registered, need extra cycle to capture
    reg [31:0] rdata;
    task apb_rd; input [7:0] a;
        begin
            @(negedge clk); paddr=a; pwrite=0; psel=1; penable=0;
            @(posedge clk); #1; penable=1;           // UART sees psel, latches prdata
            @(posedge clk); #1;                       // prdata now stable
            @(posedge clk); #1; rdata=prdata;         // capture
            psel=0; penable=0;
            @(posedge clk);  // settle
        end
    endtask

    integer b, t;
    initial begin
        $display("===== UART16550 Testbench v1.2 =====");
        rst_n=0; repeat(10)@(posedge clk); rst_n=1; repeat(10)@(posedge clk);

        // T1: LSR on reset — txempty=1 → lsr[5]=1
        $display("--- T1: LSR reset state ---");
        $display("  DBG txw=%0d txr=%0d txempty=%0b lsr=0x%02h",
            dut.txw,dut.txr,dut.txempty,dut.lsr);
        apb_rd(8'h14);
        $display("  DBG rdata=0x%08h rdata[5]=%0b",rdata,rdata[5]);
        chk(rdata[5],1'b1,"lsr_tx_empty");
        chk(rdata[0],1'b0,"lsr_rx_not_ready");

        // T2: SCR scratch
        $display("--- T2: SCR scratch ---");
        apb_wr(8'h1C,32'hDE); apb_rd(8'h1C);
        chk(rdata[7:0],8'hDE,"scr_readback");

        // T3: TX byte 0x55 — start bit must go low within 1500 clocks
        $display("--- T3: TX byte 0x55 ---");
        apb_wr(8'h00,32'h55);
        $display("  DBG after write: txw=%0d txempty=%0b tx=%0b",dut.txw,dut.txempty,tx);
        t=0; while(tx===1'b1 && t<1500) begin @(posedge clk); t=t+1; end
        if(t<1500)begin $display("[PASS] tx_start_bit (cycle %0d)",t);pass=pass+1;end
        else begin
            $display("[FAIL] tx_start_bit never seen");
            $display("  DBG txbits=%0d txsub=%0d txsr=0x%03h tx=%0b",
                dut.txbits,dut.txsub,dut.txsr,tx);
            fail=fail+1;
        end

        // T4: RX loopback 0xA5 — wait for TX to finish then inject
        $display("--- T4: RX loopback 0xA5 ---");
        repeat(5500)@(posedge clk);
        rx=0; repeat(432)@(posedge clk);  // start bit
        begin reg [7:0] byt; byt=8'hA5;
            for(b=0;b<8;b=b+1)begin rx=byt[b]; repeat(432)@(posedge clk); end
        end
        rx=1; repeat(432)@(posedge clk);  // stop bit
        repeat(300)@(posedge clk);
        $display("  DBG RX: rxw=%0d rxr=%0d rxbusy=%0b rxempty=%0b",
            dut.rxw,dut.rxr,dut.rxbusy,dut.rxempty);
        apb_rd(8'h14); chk(rdata[0],1'b1,"rx_byte_ready");
        $display("  DBG rxf[0]=0x%02h rxsr=0x%02h rxbits=%0d",dut.rxf[0],dut.rxsr,dut.rxbits);
        apb_rd(8'h00); chk(rdata[7:0],8'hA5,"rx_byte_value");

        // T5: IER
        $display("--- T5: RX interrupt enable ---");
        apb_wr(8'h04,32'h01); apb_rd(8'h04);
        chk(rdata[0],1'b1,"ier_rx_set");

        $display("\n===== UART: %0d PASS  %0d FAIL =====",pass,fail);
        $finish;
    end
    initial begin #25_000_000; $display("[WATCHDOG]"); $finish; end
endmodule
