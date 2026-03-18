// =============================================================================
//  Synapse-RV NPU — Controller FSM  v1.0  [VERIFIED]
//  IDLE → WAIT_WEIGHTS → CLEAR → COMPUTE → DRAIN → DONE → IDLE
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module npu_ctrl #(
    parameter TILE_CYCLES = 256
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cmd_start,
    input  wire [15:0] cmd_tile_count,
    input  wire        weights_ready,
    output reg         sa_enable,
    output reg         sa_clear,
    output reg         act_valid,
    output reg         status_busy,
    output reg         status_done,
    output reg [15:0]  tiles_completed
);
    localparam [2:0]
        IDLE         = 3'd0,
        WAIT_WEIGHTS = 3'd1,
        CLEAR_ARRAY  = 3'd2,
        COMPUTE      = 3'd3,
        DRAIN        = 3'd4,
        DONE         = 3'd5;

    reg [2:0]  state;
    reg [15:0] cycle_cnt;
    reg [15:0] tile_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            sa_enable <= 0; sa_clear <= 0; act_valid <= 0;
            status_busy <= 0; status_done <= 0;
            cycle_cnt <= 0; tile_cnt <= 0; tiles_completed <= 0;
        end else begin
            sa_enable <= 0; sa_clear <= 0; act_valid <= 0;

            case (state)
                IDLE: begin
                    status_busy <= 0; status_done <= 0;
                    cycle_cnt <= 0; tile_cnt <= 0; tiles_completed <= 0;
                    if (cmd_start)
                        state <= weights_ready ? CLEAR_ARRAY : WAIT_WEIGHTS;
                end

                WAIT_WEIGHTS: begin
                    status_busy <= 1;
                    if (weights_ready) state <= CLEAR_ARRAY;
                end

                CLEAR_ARRAY: begin
                    sa_clear    <= 1;
                    status_busy <= 1;
                    cycle_cnt   <= 0;
                    state       <= COMPUTE;
                end

                COMPUTE: begin
                    sa_enable <= 1;
                    cycle_cnt <= cycle_cnt + 1;
                    if (cycle_cnt == (TILE_CYCLES - 1))
                        state <= DRAIN;
                end

                DRAIN: begin
                    act_valid       <= 1;
                    tiles_completed <= tiles_completed + 1;
                    tile_cnt        <= tile_cnt + 1;
                    state <= (tile_cnt == cmd_tile_count - 1) ? DONE : CLEAR_ARRAY;
                end

                DONE: begin
                    status_busy <= 0;
                    status_done <= 1;
                    if (!cmd_start) state <= IDLE;  // wait for CPU to deassert start
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
