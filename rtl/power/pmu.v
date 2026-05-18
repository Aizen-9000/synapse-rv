// =============================================================================
//  Synapse-RV — Power Management Unit (PMU) v2.0  [REAL DVFS]
//
//  Features:
//    - 3 independent clock domains: CPU, NPU, PERI
//    - Clock gating per domain (ICG cells)
//    - PLL enable/disable control
//    - DVFS voltage/frequency levels: 0=OFF 1=LOW(div4) 2=MED(div2) 3=HIGH(div1)
//    - Wake sources: GPIO, UART, TIMER
//    - Power states: ACTIVE, SLEEP, DEEP_SLEEP
//
//  APB CSR Map:
//    0x00 : PWR_CTRL   — [1:0]=cpu_dvfs [3:2]=npu_dvfs [5:4]=peri_dvfs
//    0x04 : CLK_GATE   — [0]=cpu_en [1]=npu_en [2]=peri_en
//    0x08 : PLL_CTRL   — [0]=cpu_pll_en [1]=npu_pll_en [2]=peri_pll_en
//    0x0C : PWR_STATE  — [1:0] 0=ACTIVE 1=SLEEP 2=DEEP_SLEEP
//    0x10 : WAKE_EN    — [0]=gpio [1]=uart [2]=timer
//    0x14 : STATUS     — [0]=cpu_pll_lock [1]=npu_pll_lock [2]=peri_pll_lock
//                        [4]=in_sleep [5]=in_deep_sleep
//    0x18 : IRQ_STATUS — [0]=pwr_change [1]=wake_event
//    0x1C : IRQ_CLEAR  — write 1 to clear
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module pmu (
    input  wire        clk_ref,
    input  wire        pll_cpu_out, pll_npu_out, pll_peri_out,
    input  wire        rst_por_n,
    input  wire [11:0] psel_addr,
    input  wire        psel, penable, pwrite,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        clk_cpu, clk_npu, clk_peri,
    output wire        pd_cpu_en, pd_npu_en, pd_peri_en,
    output wire        pll_cpu_en, pll_npu_en, pll_peri_en,
    input  wire        wake_gpio, wake_uart, wake_timer,
    output wire        irq_pmu
);
    assign pready = 1'b1;

    // -------------------------------------------------------------------------
    // CSRs
    // -------------------------------------------------------------------------
    reg [1:0] cpu_dvfs, npu_dvfs, peri_dvfs;
    reg       cpu_clk_en, npu_clk_en, peri_clk_en;
    reg       cpu_pll_en_r, npu_pll_en_r, peri_pll_en_r;
    reg [1:0] pwr_state;
    reg [2:0] wake_en;
    reg [1:0] irq_status;

    localparam PWR_ACTIVE     = 2'd0;
    localparam PWR_SLEEP      = 2'd1;
    localparam PWR_DEEP_SLEEP = 2'd2;

    // -------------------------------------------------------------------------
    // APB write
    // -------------------------------------------------------------------------
    always @(posedge clk_ref or negedge rst_por_n) begin
        if (!rst_por_n) begin
            cpu_dvfs      <= 2'd3;  // HIGH by default
            npu_dvfs      <= 2'd3;
            peri_dvfs     <= 2'd2;  // MEDIUM for peripherals
            cpu_clk_en    <= 1'b1;
            npu_clk_en    <= 1'b1;
            peri_clk_en   <= 1'b1;
            cpu_pll_en_r  <= 1'b1;
            npu_pll_en_r  <= 1'b1;
            peri_pll_en_r <= 1'b1;
            pwr_state     <= PWR_ACTIVE;
            wake_en       <= 3'b111;
            irq_status    <= 2'b0;
        end else begin
            // Wake from sleep on any enabled source
            if (pwr_state != PWR_ACTIVE) begin
                if ((wake_en[0] && wake_gpio) ||
                    (wake_en[1] && wake_uart) ||
                    (wake_en[2] && wake_timer)) begin
                    pwr_state  <= PWR_ACTIVE;
                    cpu_clk_en <= 1'b1;
                    npu_clk_en <= 1'b1;
                    irq_status <= irq_status | 2'b10;  // wake_event
                end
            end

            if (psel && penable && pwrite) begin
                case (psel_addr[4:2])
                    3'h0: begin
                        cpu_dvfs  <= pwdata[1:0];
                        npu_dvfs  <= pwdata[3:2];
                        peri_dvfs <= pwdata[5:4];
                        irq_status <= irq_status | 2'b01;  // pwr_change
                    end
                    3'h1: begin
                        cpu_clk_en  <= pwdata[0];
                        npu_clk_en  <= pwdata[1];
                        peri_clk_en <= pwdata[2];
                    end
                    3'h2: begin
                        cpu_pll_en_r  <= pwdata[0];
                        npu_pll_en_r  <= pwdata[1];
                        peri_pll_en_r <= pwdata[2];
                    end
                    3'h3: begin
                        pwr_state <= pwdata[1:0];
                        if (pwdata[1:0] == PWR_SLEEP) begin
                            npu_clk_en <= 1'b0;  // gate NPU in sleep
                        end
                        if (pwdata[1:0] == PWR_DEEP_SLEEP) begin
                            npu_clk_en  <= 1'b0;  // gate all non-essential
                            cpu_dvfs    <= 2'd1;   // drop to LOW freq
                        end
                    end
                    3'h4: wake_en <= pwdata[2:0];
                    3'h7: irq_status <= irq_status & ~pwdata[1:0]; // clear
                    default: ;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // APB read
    // -------------------------------------------------------------------------
    always @(posedge clk_ref or negedge rst_por_n) begin
        if (!rst_por_n) prdata <= 32'h0;
        else if (psel && penable && !pwrite) begin
            case (psel_addr[4:2])
                3'h0: prdata <= {26'h0, peri_dvfs, npu_dvfs, cpu_dvfs};
                3'h1: prdata <= {29'h0, peri_clk_en, npu_clk_en, cpu_clk_en};
                3'h2: prdata <= {29'h0, peri_pll_en_r, npu_pll_en_r, cpu_pll_en_r};
                3'h3: prdata <= {30'h0, pwr_state};
                3'h4: prdata <= {29'h0, wake_en};
                3'h5: prdata <= {26'h0, (pwr_state==PWR_DEEP_SLEEP),
                                  (pwr_state==PWR_SLEEP), 2'b11, 2'b11};
                3'h6: prdata <= {30'h0, irq_status};
                default: prdata <= 32'hDEAD_C0DE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Clock dividers — DVFS levels
    // 2'b00=OFF 2'b01=div4 2'b10=div2 2'b11=div1(full)
    // -------------------------------------------------------------------------
    reg [1:0] div_cnt_cpu, div_cnt_npu, div_cnt_peri;
    reg clk_cpu_div, clk_npu_div, clk_peri_div;

    always @(posedge clk_ref or negedge rst_por_n) begin
        if (!rst_por_n) begin
            div_cnt_cpu<=0; div_cnt_npu<=0; div_cnt_peri<=0;
            clk_cpu_div<=0; clk_npu_div<=0; clk_peri_div<=0;
        end else begin
            // CPU clock divider
            case (cpu_dvfs)
                2'd3: clk_cpu_div <= clk_ref;         // div1
                2'd2: begin div_cnt_cpu<=div_cnt_cpu+1;
                       if(div_cnt_cpu==0) clk_cpu_div<=~clk_cpu_div; end
                2'd1: begin div_cnt_cpu<=div_cnt_cpu+1;
                       if(div_cnt_cpu==1) begin clk_cpu_div<=~clk_cpu_div; div_cnt_cpu<=0; end end
                2'd0: clk_cpu_div <= 1'b0;
            endcase
            // NPU clock divider
            case (npu_dvfs)
                2'd3: clk_npu_div <= clk_ref;
                2'd2: begin div_cnt_npu<=div_cnt_npu+1;
                       if(div_cnt_npu==0) clk_npu_div<=~clk_npu_div; end
                2'd1: begin div_cnt_npu<=div_cnt_npu+1;
                       if(div_cnt_npu==1) begin clk_npu_div<=~clk_npu_div; div_cnt_npu<=0; end end
                2'd0: clk_npu_div <= 1'b0;
            endcase
            // PERI clock divider
            case (peri_dvfs)
                2'd3: clk_peri_div <= clk_ref;
                2'd2: begin div_cnt_peri<=div_cnt_peri+1;
                       if(div_cnt_peri==0) clk_peri_div<=~clk_peri_div; end
                2'd1: begin div_cnt_peri<=div_cnt_peri+1;
                       if(div_cnt_peri==1) begin clk_peri_div<=~clk_peri_div; div_cnt_peri<=0; end end
                2'd0: clk_peri_div <= 1'b0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // ICG (Integrated Clock Gate) — AND gate with latch-based enable
    // In real silicon: replace with sky130_fd_sc_hd__dlclkp_1
    // -------------------------------------------------------------------------
    wire clk_cpu_src  = (cpu_dvfs  == 2'd3) ? pll_cpu_out  : clk_cpu_div;
    wire clk_npu_src  = (npu_dvfs  == 2'd3) ? pll_npu_out  : clk_npu_div;
    wire clk_peri_src = (peri_dvfs == 2'd3) ? pll_peri_out : clk_peri_div;

    assign clk_cpu  = clk_cpu_src  & cpu_clk_en;
    assign clk_npu  = clk_npu_src  & npu_clk_en;
    assign clk_peri = clk_peri_src & peri_clk_en;

    // -------------------------------------------------------------------------
    // Power domain enables
    // -------------------------------------------------------------------------
    assign pd_cpu_en  = (pwr_state != PWR_DEEP_SLEEP);
    assign pd_npu_en  = (pwr_state == PWR_ACTIVE) && npu_clk_en;
    assign pd_peri_en = (pwr_state != PWR_DEEP_SLEEP);

    // -------------------------------------------------------------------------
    // PLL enables
    // -------------------------------------------------------------------------
    assign pll_cpu_en  = cpu_pll_en_r  && (pwr_state != PWR_DEEP_SLEEP);
    assign pll_npu_en  = npu_pll_en_r  && (pwr_state == PWR_ACTIVE);
    assign pll_peri_en = peri_pll_en_r && (pwr_state != PWR_DEEP_SLEEP);

    // -------------------------------------------------------------------------
    // IRQ
    // -------------------------------------------------------------------------
    assign irq_pmu = |irq_status;

endmodule
`default_nettype wire
