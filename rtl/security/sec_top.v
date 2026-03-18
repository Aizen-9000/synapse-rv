`timescale 1ns/1ps
`default_nettype none

module sec_top #(
    parameter APB_AW = 12,
    parameter APB_DW = 32
)(
    input  wire              clk, rst_n, sec_mode,
    input  wire [APB_AW-1:0] paddr,
    input  wire              psel, penable, pwrite,
    input  wire [31:0]       pwdata,
    output reg  [31:0]       prdata,
    output wire              pready,
    input  wire [255:0]      boot_hash_actual,
    input  wire [255:0]      boot_hash_golden,
    output wire              boot_ok,
    output wire              irq_sec
);
    assign pready = 1'b1;
    wire apb_active = psel && penable;
    wire [7:0] word_addr = {2'b00, paddr[7:2]};
    wire aes_cs  = apb_active && (paddr[11:10] == 2'b00);
    wire sha_cs  = apb_active && (paddr[11:10] == 2'b01);
    wire ctrl_cs = apb_active && (paddr[11:10] == 2'b10);
    wire sha3_cs = apb_active && (paddr[11:10] == 2'b11);

    wire [31:0] aes_rdata;
    aes u_aes (.clk(clk), .reset_n(rst_n), .cs(aes_cs), .we(pwrite),
               .address(word_addr), .write_data(pwdata), .read_data(aes_rdata));

    wire [31:0] sha_rdata;
    wire sha_error;
    sha256 u_sha256 (.clk(clk), .reset_n(rst_n), .cs(sha_cs), .we(pwrite),
                     .address(word_addr), .write_data(pwdata),
                     .read_data(sha_rdata), .error(sha_error));

    wire [31:0] sha3_rdata;
    sha3 u_sha3 (.clk(clk), .reset_n(rst_n), .cs(sha3_cs), .we(pwrite),
                 .address(word_addr), .write_data(pwdata), .read_data(sha3_rdata));

    reg boot_ok_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) boot_ok_r <= 1'b0;
        else        boot_ok_r <= (boot_hash_actual == boot_hash_golden);
    end
    assign boot_ok = boot_ok_r;

    reg [31:0] ctrl_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ctrl_reg <= 32'h0;
        else if (ctrl_cs && pwrite) ctrl_reg <= pwdata;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prdata <= 32'h0;
        else if (apb_active && !pwrite) begin
            if      (aes_cs)  prdata <= aes_rdata;
            else if (sha_cs)  prdata <= sha_rdata;
            else if (sha3_cs) prdata <= sha3_rdata;
            else if (ctrl_cs) prdata <= {boot_ok_r, sec_mode, 28'h0, sha_error, 1'b0};
            else              prdata <= 32'hDEAD_C0DE;
        end
    end
    assign irq_sec = sec_mode && !boot_ok_r;
endmodule
`default_nettype wire
