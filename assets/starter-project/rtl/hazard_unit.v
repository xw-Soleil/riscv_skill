`timescale 1ns/1ps

// Detects load-use hazards between an instruction in EX (a load) and the
// following instruction in ID that consumes the load's destination register.
module hazard_unit (
    input  wire        if_id_valid,
    input  wire [31:0] if_id_instr,
    input  wire        id_ex_mem_read,
    input  wire [4:0]  id_ex_rd,
    output wire        load_use_stall
);
    wire [6:0] opcode = if_id_instr[6:0];
    wire [4:0] rs1    = if_id_instr[19:15];
    wire [4:0] rs2    = if_id_instr[24:20];

    reg uses_rs1, uses_rs2;
    always @(*) begin
        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;
        case (opcode)
            7'b0110011: begin uses_rs1 = 1'b1; uses_rs2 = 1'b1; end // R
            7'b0010011,
            7'b0000011,
            7'b1100111: uses_rs1 = 1'b1;                            // I/Load/JALR
            7'b0100011,
            7'b1100011: begin uses_rs1 = 1'b1; uses_rs2 = 1'b1; end // S/B
            default: ;
        endcase
    end

    assign load_use_stall = if_id_valid && id_ex_mem_read && id_ex_rd != 5'd0
                          && ((uses_rs1 && rs1 == id_ex_rd) || (uses_rs2 && rs2 == id_ex_rd));
endmodule
