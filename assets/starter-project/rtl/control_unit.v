`timescale 1ns/1ps

// Pure-combinational decoder for the 25 RV32I instructions specified in
// experiment 1, plus SLTU/SLTIU/BLTU/BGEU which the lab1 implementation kept
// as the stretch goal.
module control_unit (
    input  wire [31:0] instr,
    output reg         reg_write,
    output reg         mem_read,
    output reg         mem_write,
    output reg         alu_src_b_imm,
    output reg         alu_src_a_pc,
    output reg  [3:0]  alu_op,
    output reg         branch,
    output reg         jump,
    output reg         jalr,
    output reg         mem_byte
);
    localparam OPC_LUI    = 7'b0110111;
    localparam OPC_AUIPC  = 7'b0010111;
    localparam OPC_JAL    = 7'b1101111;
    localparam OPC_JALR   = 7'b1100111;
    localparam OPC_BRANCH = 7'b1100011;
    localparam OPC_LOAD   = 7'b0000011;
    localparam OPC_STORE  = 7'b0100011;
    localparam OPC_OPIMM  = 7'b0010011;
    localparam OPC_OP     = 7'b0110011;

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

    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];

    always @(*) begin
        reg_write     = 1'b0;
        mem_read      = 1'b0;
        mem_write     = 1'b0;
        alu_src_b_imm = 1'b0;
        alu_src_a_pc  = 1'b0;
        alu_op        = ALU_ADD;
        branch        = 1'b0;
        jump          = 1'b0;
        jalr          = 1'b0;
        mem_byte      = 1'b0;

        case (opcode)
            OPC_LUI: begin
                reg_write     = 1'b1;
                alu_src_b_imm = 1'b1;
                alu_op        = ALU_PASS;
            end
            OPC_AUIPC: begin
                reg_write     = 1'b1;
                alu_src_a_pc  = 1'b1;
                alu_src_b_imm = 1'b1;
                alu_op        = ALU_ADD;
            end
            OPC_JAL: begin
                reg_write = 1'b1;
                jump      = 1'b1;
            end
            OPC_JALR: begin
                reg_write     = 1'b1;
                jump          = 1'b1;
                jalr          = 1'b1;
                alu_src_b_imm = 1'b1;
            end
            OPC_BRANCH: begin
                branch = 1'b1;
                alu_op = ALU_SUB;
            end
            OPC_LOAD: begin
                reg_write     = 1'b1;
                mem_read      = 1'b1;
                alu_src_b_imm = 1'b1;
                alu_op        = ALU_ADD;
                case (funct3)
                    3'b000: mem_byte = 1'b1; // LB
                    3'b010: mem_byte = 1'b0; // LW
                    default: begin
                        reg_write = 1'b0;
                        mem_read  = 1'b0;
                    end
                endcase
            end
            OPC_STORE: begin
                mem_write     = 1'b1;
                alu_src_b_imm = 1'b1;
                alu_op        = ALU_ADD;
                case (funct3)
                    3'b000: mem_byte = 1'b1; // SB
                    3'b010: mem_byte = 1'b0; // SW
                    default: mem_write = 1'b0;
                endcase
            end
            OPC_OPIMM: begin
                reg_write     = 1'b1;
                alu_src_b_imm = 1'b1;
                case (funct3)
                    3'b000: alu_op = ALU_ADD;
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                    3'b001: alu_op = ALU_SLL;
                    3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    default: reg_write = 1'b0;
                endcase
            end
            OPC_OP: begin
                reg_write = 1'b1;
                case (funct3)
                    3'b000: alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
                    3'b001: alu_op = ALU_SLL;
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                    default: reg_write = 1'b0;
                endcase
            end
            default: reg_write = 1'b0;
        endcase
    end
endmodule
