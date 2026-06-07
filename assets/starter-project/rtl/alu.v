`timescale 1ns/1ps

// ALU for the 4-stage pipelined RV32I core.
// Supports add/sub, logical, shifts, signed/unsigned compare, and PASS-B (LUI).
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] y
);
    localparam ALU_ADD  = 4'd0;
    localparam ALU_SUB  = 4'd1;
    localparam ALU_AND  = 4'd2;
    localparam ALU_OR   = 4'd3;
    localparam ALU_XOR  = 4'd4;
    localparam ALU_SLL  = 4'd5;
    localparam ALU_SRL  = 4'd6;
    localparam ALU_SRA  = 4'd7;
    localparam ALU_SLT  = 4'd8;
    localparam ALU_SLTU = 4'd9;
    localparam ALU_PASS = 4'd10;

    wire [4:0]  sh = b[4:0];
    wire signed [31:0] sa = a;

    always @(*) begin
        case (op)
            ALU_ADD : y = a + b;
            ALU_SUB : y = a - b;
            ALU_AND : y = a & b;
            ALU_OR  : y = a | b;
            ALU_XOR : y = a ^ b;
            ALU_SLL : y = a << sh;
            ALU_SRL : y = a >> sh;
            ALU_SRA : y = sa >>> sh;
            ALU_SLT : y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU: y = (a < b) ? 32'd1 : 32'd0;
            ALU_PASS: y = b;
            default : y = 32'd0;
        endcase
    end
endmodule
