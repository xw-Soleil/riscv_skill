`timescale 1ns/1ps

// Two-source forwarding network: EX/MEM (`fwd_ex`) wins over MEM/WB
// (`fwd_wb`); for loads only the WB-stage forward path is meaningful because
// the data has not been read yet at EX/MEM time.
module forward_unit (
    input  wire        ex_valid,
    input  wire [4:0]  ex_rs1,
    input  wire [4:0]  ex_rs2,
    input  wire        mem_valid,
    input  wire        mem_reg_write,
    input  wire        mem_mem_read,
    input  wire [4:0]  mem_rd,
    output reg  [1:0]  forward_a,
    output reg  [1:0]  forward_b
);
    always @(*) begin
        forward_a = 2'b00;
        forward_b = 2'b00;
        if (ex_valid && mem_valid && mem_reg_write && mem_rd != 5'd0) begin
            if (mem_rd == ex_rs1) forward_a = mem_mem_read ? 2'b01 : 2'b10;
            if (mem_rd == ex_rs2) forward_b = mem_mem_read ? 2'b01 : 2'b10;
        end
    end
endmodule
