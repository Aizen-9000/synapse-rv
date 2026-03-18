// =============================================================================
//  Synapse-RV NPU — PE Testbench
//  File   : npu_pe_tb.v
//  Rev    : 0.1
// =============================================================================
//
//  HOW TO RUN (with Verilator — free & fast):
//  -------------------------------------------
//  Install Verilator:
//    Ubuntu/Debian : sudo apt install verilator
//    Mac (brew)    : brew install verilator
//
//  Run simulation:
//    verilator --binary --timing -Wall \
//              rtl/npu_pe.v sim/npu_pe_tb.v \
//              -o sim_npu_pe --top-module npu_pe_tb
//    ./obj_dir/sim_npu_pe
//
//  Or with Icarus Verilog (even simpler, also free):
//    iverilog -o sim_npu_pe rtl/npu_pe.v sim/npu_pe_tb.v
//    vvp sim_npu_pe
//
//  WHAT THIS TESTBENCH CHECKS:
//  ----------------------------
//  TEST 1 — Basic MAC:
//      Feed weight=3, input=4 for 3 cycles.
//      Expected accum = 3*4 + 3*4 + 3*4 = 36
//
//  TEST 2 — Negative numbers (signed arithmetic):
//      weight=-2, input=5 → product = -10 per cycle
//      Expected accum = -10 * N
//
//  TEST 3 — Clear then restart:
//      Verify clear zeroes the accumulator mid-run.
//
//  TEST 4 — Systolic pass-through:
//      Verify in_a and in_b are forwarded to neighbours with 1-cycle delay.
//
//  TEST 5 — Enable gating:
//      Verify that when enable=0 the accumulator holds its value.
//
// =============================================================================

`timescale 1ns / 1ps

module npu_pe_tb;

    // ---------- DUT signals ----------
    reg        clk;
    reg        rst_n;
    reg        enable;
    reg        clear;
    reg  signed [7:0]  in_a;
    reg  signed [7:0]  in_b;
    wire signed [7:0]  in_a_out;
    wire signed [7:0]  in_b_out;
    wire signed [31:0] accum;
    wire               accum_valid;

    // ---------- Instantiate DUT ----------
    npu_pe dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .clear      (clear),
        .in_a       (in_a),
        .in_b       (in_b),
        .in_a_out   (in_a_out),
        .in_b_out   (in_b_out),
        .accum      (accum),
        .accum_valid(accum_valid)
    );

    // ---------- Clock: 5ns half-period = 100 MHz ----------
    initial clk = 0;
    always #5 clk = ~clk;

    // ---------- Helper task: check result ----------
    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [127:0] test_name;  // label
        input signed [31:0] got;
        input signed [31:0] expected;
        begin
            if (got === expected) begin
                $display("  PASS | %-20s | got %0d", test_name, got);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL | %-20s | got %0d, expected %0d", test_name, got, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ---------- Main test sequence ----------
    integer i;
    initial begin
        $display("=================================================");
        $display("  Synapse-RV NPU PE — Simulation v0.1");
        $display("=================================================");

        // -- Init --
        rst_n  = 0;
        enable = 0;
        clear  = 0;
        in_a   = 0;
        in_b   = 0;

        // -- Release reset after 3 cycles --
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // =========================================================
        // TEST 1: Basic positive MAC
        // weight=3, input=4, 4 cycles → expected accum = 3*4*4 = 48
        // =========================================================
        $display("\n[TEST 1] Basic MAC: weight=3, input=4, 4 cycles");
        clear  = 1; @(posedge clk); #1; clear = 0;   // reset accumulator
        in_a   = 8'sd4;    // input activation
        in_b   = 8'sd3;    // weight
        enable = 1;
        repeat(4) @(posedge clk); #1;
        enable = 0;
        @(posedge clk); #1;  // let output settle
        check("accum=48", accum, 32'sd48);

        // =========================================================
        // TEST 2: Signed (negative weight)
        // weight=-2, input=5, 3 cycles → expected accum = -2*5*3 = -30
        // =========================================================
        $display("\n[TEST 2] Signed MAC: weight=-2, input=5, 3 cycles");
        clear  = 1; @(posedge clk); #1; clear = 0;
        in_a   = 8'sd5;
        in_b   = -8'sd2;
        enable = 1;
        repeat(3) @(posedge clk); #1;
        enable = 0;
        @(posedge clk); #1;
        check("accum=-30", accum, -32'sd30);

        // =========================================================
        // TEST 3: Clear mid-run
        // Run 2 cycles (weight=7, input=7 → 49 each), then clear,
        // then run 1 more cycle → expected accum = 49
        // =========================================================
        $display("\n[TEST 3] Mid-run clear");
        clear  = 1; @(posedge clk); #1; clear = 0;
        in_a   = 8'sd7;
        in_b   = 8'sd7;
        enable = 1;
        repeat(2) @(posedge clk); #1;   // accum = 98
        // Now clear while enable is still high
        clear = 1; @(posedge clk); #1; clear = 0;
        // Run 1 more cycle
        repeat(1) @(posedge clk); #1;
        enable = 0;
        @(posedge clk); #1;
        check("accum=49 after clear", accum, 32'sd49);

        // =========================================================
        // TEST 4: Systolic pass-through (1-cycle registered delay)
        // =========================================================
        $display("\n[TEST 4] Systolic forwarding");
        clear  = 1; @(posedge clk); #1; clear = 0;
        enable = 0;
        in_a   = 8'sd42;
        in_b   = -8'sd99;
        @(posedge clk); #1;   // inputs are registered on this edge
        @(posedge clk); #1;   // outputs are stable now
        check("in_a_out=42",  $signed(in_a_out), 32'sd42);
        check("in_b_out=-99", $signed(in_b_out), -32'sd99);

        // =========================================================
        // TEST 5: Enable gating — accum should hold when enable=0
        // =========================================================
        $display("\n[TEST 5] Enable gating");
        clear  = 1; @(posedge clk); #1; clear = 0;
        in_a   = 8'sd10;
        in_b   = 8'sd10;
        enable = 1;
        repeat(2) @(posedge clk); #1;   // accum = 200
        enable = 0;
        in_a   = 8'sd99;   // change inputs — should be ignored
        in_b   = 8'sd99;
        repeat(3) @(posedge clk); #1;   // accum should stay 200
        check("held at 200", accum, 32'sd200);

        // =========================================================
        // TEST 6: Overflow boundary — int8 max values
        // weight=127, input=127 → product=16129 per cycle
        // Run 1 cycle only (checking single product)
        // =========================================================
        $display("\n[TEST 6] Max int8 values");
        clear  = 1; @(posedge clk); #1; clear = 0;
        in_a   = 8'sd127;
        in_b   = 8'sd127;
        enable = 1;
        repeat(1) @(posedge clk); #1;
        enable = 0;
        @(posedge clk); #1;
        check("accum=16129", accum, 32'sd16129);

        // =========================================================
        // Summary
        // =========================================================
        $display("\n=================================================");
        $display("  Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("=================================================");

        if (fail_count == 0)
            $display("  ALL TESTS PASSED — PE is correct!");
        else
            $display("  SOME TESTS FAILED — check RTL logic.");

        $finish;
    end

    // Optional: dump waveforms for GTKWave
    initial begin
        $dumpfile("npu_pe_waves.vcd");
        $dumpvars(0, npu_pe_tb);
    end

endmodule
