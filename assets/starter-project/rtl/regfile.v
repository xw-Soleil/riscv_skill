`timescale 1ns/1ps

// 32x32 register file with synchronous write and asynchronous read.
// x0 reads as zero; same-cycle write/read forwarding.
module regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  wa,
    input  wire [31:0] wd,
    input  wire [4:0]  ra1,
    input  wire [4:0]  ra2,
    output wire [31:0] rd1,
    output wire [31:0] rd2
);
    reg [31:0] regs [0:31];
    integer i;

    initial begin
        for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;
    end

    always @(posedge clk) begin
        if (we && wa != 5'd0) regs[wa] <= wd;
    end

    assign rd1 = (ra1 == 5'd0) ? 32'd0
               : (we && wa == ra1) ? wd : regs[ra1];
    assign rd2 = (ra2 == 5'd0) ? 32'd0
               : (we && wa == ra2) ? wd : regs[ra2];
endmodule
