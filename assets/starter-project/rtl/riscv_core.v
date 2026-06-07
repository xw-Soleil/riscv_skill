`timescale 1ns/1ps

// 4-stage RV32I core: IF | ID | EX | MEM/WB
// Three pipeline registers: IF/ID, ID/EX, EX/MEM.
//
// Memory ports use a simple "ready" handshake so an attached cache can stall
// the pipeline on a miss:
//   * Instruction fetch:  imem_req is high while the IF stage is alive.
//                         imem_ready=1 means imem_rdata is the instruction
//                         requested at imem_addr in this cycle.
    //                         imem_ready=0 freezes PC and IF/ID while a bubble
    //                         is inserted into ID/EX.
//   * Data:               dmem_req is high in the MEM stage when the
//                         in-flight instruction is a load or store.
//                         dmem_ready=0 freezes PC, IF/ID, ID/EX and EX/MEM.
//                         dmem_ready=1 retires the load/store and produces
//                         dmem_rdata for a load.
//
// LB sign-extension and SB byte-lane replication are handled here so the
// cache speaks in 32-bit words plus a 4-bit byte-enable mask.
module riscv_core (
    input  wire        clk,
    input  wire        rst,

    // ---------------- IF stage : I-cache ----------------
    output wire        imem_req,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    input  wire        imem_ready,

    // ---------------- MEM stage : D-cache ----------------
    output wire        dmem_req,
    output wire [31:0] dmem_addr,
    output wire        dmem_we,
    output wire [3:0]  dmem_be,
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,

    // ---------------- Trace / debug ----------------
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    output wire        debug_imem_stall,
    output wire        debug_dmem_stall,
    output wire        debug_load_use_stall,
    output wire        debug_branch_flush
);
    localparam NOP = 32'h00000013;

    // -----------------------------------------------------------------
    // IF stage
    // -----------------------------------------------------------------
    reg [31:0] pc;
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    // -----------------------------------------------------------------
    // ID/EX register
    // -----------------------------------------------------------------
    reg        id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_instr;
    reg [31:0] id_ex_rs1_val;
    reg [31:0] id_ex_rs2_val;
    reg [31:0] id_ex_imm;
    reg [4:0]  id_ex_rs1;
    reg [4:0]  id_ex_rs2;
    reg [4:0]  id_ex_rd;
    reg [2:0]  id_ex_funct3;
    reg        id_ex_reg_write;
    reg        id_ex_mem_read;
    reg        id_ex_mem_write;
    reg        id_ex_alu_src_b_imm;
    reg        id_ex_alu_src_a_pc;
    reg [3:0]  id_ex_alu_op;
    reg        id_ex_branch;
    reg        id_ex_jump;
    reg        id_ex_jalr;
    reg        id_ex_mem_byte;

    // -----------------------------------------------------------------
    // EX/MEM register
    // -----------------------------------------------------------------
    reg        ex_mem_valid;
    reg [31:0] ex_mem_pc;
    reg [31:0] ex_mem_instr;
    reg [31:0] ex_mem_alu_y;
    reg [31:0] ex_mem_store_data;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_reg_write;
    reg        ex_mem_mem_read;
    reg        ex_mem_mem_write;
    reg        ex_mem_mem_byte;

    // -----------------------------------------------------------------
    // ID stage : decode, immediate, read regfile
    // -----------------------------------------------------------------
    wire [4:0] id_rs1     = if_id_instr[19:15];
    wire [4:0] id_rs2     = if_id_instr[24:20];
    wire [4:0] id_rd      = if_id_instr[11:7];
    wire [2:0] id_funct3  = if_id_instr[14:12];
    wire [6:0] id_opcode  = if_id_instr[6:0];

    wire ctrl_reg_write, ctrl_mem_read, ctrl_mem_write;
    wire ctrl_alu_src_b_imm, ctrl_alu_src_a_pc;
    wire [3:0] ctrl_alu_op;
    wire ctrl_branch, ctrl_jump, ctrl_jalr, ctrl_mem_byte;

    control_unit u_ctrl (
        .instr        (if_id_instr),
        .reg_write    (ctrl_reg_write),
        .mem_read     (ctrl_mem_read),
        .mem_write    (ctrl_mem_write),
        .alu_src_b_imm(ctrl_alu_src_b_imm),
        .alu_src_a_pc (ctrl_alu_src_a_pc),
        .alu_op       (ctrl_alu_op),
        .branch       (ctrl_branch),
        .jump         (ctrl_jump),
        .jalr         (ctrl_jalr),
        .mem_byte     (ctrl_mem_byte)
    );

    function [31:0] imm_i; input [31:0] in;
        imm_i = {{20{in[31]}}, in[31:20]};
    endfunction
    function [31:0] imm_s; input [31:0] in;
        imm_s = {{20{in[31]}}, in[31:25], in[11:7]};
    endfunction
    function [31:0] imm_b; input [31:0] in;
        imm_b = {{19{in[31]}}, in[31], in[7], in[30:25], in[11:8], 1'b0};
    endfunction
    function [31:0] imm_u; input [31:0] in;
        imm_u = {in[31:12], 12'd0};
    endfunction
    function [31:0] imm_j; input [31:0] in;
        imm_j = {{11{in[31]}}, in[31], in[19:12], in[20], in[30:21], 1'b0};
    endfunction

    reg [31:0] id_imm;
    always @(*) begin
        case (id_opcode)
            7'b0010011,
            7'b0000011,
            7'b1100111: id_imm = imm_i(if_id_instr);
            7'b0100011: id_imm = imm_s(if_id_instr);
            7'b1100011: id_imm = imm_b(if_id_instr);
            7'b0110111,
            7'b0010111: id_imm = imm_u(if_id_instr);
            7'b1101111: id_imm = imm_j(if_id_instr);
            default   : id_imm = 32'd0;
        endcase
    end

    wire [31:0] rf_rs1_val, rf_rs2_val;
    wire        wb_we;
    wire [31:0] wb_data;
    wire [4:0]  wb_rd;

    regfile u_rf (
        .clk(clk),
        .we (wb_we),
        .wa (wb_rd),
        .wd (wb_data),
        .ra1(id_rs1),
        .ra2(id_rs2),
        .rd1(rf_rs1_val),
        .rd2(rf_rs2_val)
    );

    // -----------------------------------------------------------------
    // Hazard / stall logic
    // -----------------------------------------------------------------
    wire load_use_stall;
    hazard_unit u_hazard (
        .if_id_valid    (if_id_valid),
        .if_id_instr    (if_id_instr),
        .id_ex_mem_read (id_ex_mem_read),
        .id_ex_rd       (id_ex_rd),
        .load_use_stall (load_use_stall)
    );

    // The memory subsystem signals pipeline stalls via `*_ready=0`.
    wire imem_stall = !imem_ready;
    wire dmem_stall = ex_mem_valid && (ex_mem_mem_read || ex_mem_mem_write) && !dmem_ready;

    // -----------------------------------------------------------------
    // EX stage : forwarding, ALU, branch resolution
    // -----------------------------------------------------------------
    wire [1:0] fwd_a, fwd_b;
    forward_unit u_fwd (
        .ex_valid     (id_ex_valid),
        .ex_rs1       (id_ex_rs1),
        .ex_rs2       (id_ex_rs2),
        .mem_valid    (ex_mem_valid),
        .mem_reg_write(ex_mem_reg_write),
        .mem_mem_read (ex_mem_mem_read),
        .mem_rd       (ex_mem_rd),
        .forward_a    (fwd_a),
        .forward_b    (fwd_b)
    );

    wire [31:0] mem_wb_data;

    wire [31:0] fwd_rs1 =
          (fwd_a == 2'b10) ? ex_mem_alu_y :
          (fwd_a == 2'b01) ? mem_wb_data  :
                             id_ex_rs1_val;
    wire [31:0] fwd_rs2 =
          (fwd_b == 2'b10) ? ex_mem_alu_y :
          (fwd_b == 2'b01) ? mem_wb_data  :
                             id_ex_rs2_val;

    wire [31:0] alu_a = id_ex_alu_src_a_pc  ? id_ex_pc  : fwd_rs1;
    wire [31:0] alu_b = id_ex_alu_src_b_imm ? id_ex_imm : fwd_rs2;
    wire [31:0] alu_y;
    alu u_alu (.a(alu_a), .b(alu_b), .op(id_ex_alu_op), .y(alu_y));

    wire branch_eq  = (fwd_rs1 == fwd_rs2);
    wire branch_lt  = ($signed(fwd_rs1) < $signed(fwd_rs2));
    wire branch_ltu = (fwd_rs1 < fwd_rs2);
    reg  branch_taken;
    always @(*) begin
        case (id_ex_funct3)
            3'b000 : branch_taken =  branch_eq;   // BEQ
            3'b001 : branch_taken = !branch_eq;   // BNE
            3'b100 : branch_taken =  branch_lt;   // BLT
            3'b101 : branch_taken = !branch_lt;   // BGE
            3'b110 : branch_taken =  branch_ltu;  // BLTU
            3'b111 : branch_taken = !branch_ltu;  // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    wire [31:0] jalr_target  = (fwd_rs1 + id_ex_imm) & 32'hffff_fffe;
    wire [31:0] br_jmp_target = id_ex_pc + id_ex_imm;
    wire [31:0] ex_target = id_ex_jalr ? jalr_target : br_jmp_target;
    wire ex_redirect = id_ex_valid &&
                       (id_ex_jump || (id_ex_branch && branch_taken));

    // -----------------------------------------------------------------
    // MEM stage : send request to D-cache, format load result
    // -----------------------------------------------------------------
    // Byte-lane formation
    wire [1:0]  mem_byte_off = ex_mem_alu_y[1:0];
    reg  [3:0]  store_be;
    reg  [31:0] store_word;
    always @(*) begin
        if (ex_mem_mem_byte) begin
            case (mem_byte_off)
                2'd0: begin store_be = 4'b0001;
                            store_word = {24'd0, ex_mem_store_data[7:0]}; end
                2'd1: begin store_be = 4'b0010;
                            store_word = {16'd0, ex_mem_store_data[7:0], 8'd0}; end
                2'd2: begin store_be = 4'b0100;
                            store_word = {8'd0, ex_mem_store_data[7:0], 16'd0}; end
                default: begin store_be = 4'b1000;
                               store_word = {ex_mem_store_data[7:0], 24'd0}; end
            endcase
        end else begin
            store_be   = 4'b1111;
            store_word = ex_mem_store_data;
        end
    end

    // Load alignment (LB with sign extension; LW returns the whole word)
    reg [31:0] load_aligned;
    always @(*) begin
        if (ex_mem_mem_byte) begin
            case (mem_byte_off)
                2'd0: load_aligned = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
                2'd1: load_aligned = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
                2'd2: load_aligned = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
                default: load_aligned = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
            endcase
        end else begin
            load_aligned = dmem_rdata;
        end
    end

    assign mem_wb_data = ex_mem_mem_read ? load_aligned : ex_mem_alu_y;

    assign dmem_req   = ex_mem_valid && (ex_mem_mem_read || ex_mem_mem_write);
    assign dmem_addr  = {ex_mem_alu_y[31:2], 2'b00};
    assign dmem_we    = ex_mem_valid && ex_mem_mem_write;
    assign dmem_be    = ex_mem_mem_write ? store_be : 4'b1111;
    assign dmem_wdata = store_word;

    // -----------------------------------------------------------------
    // Writeback (combinational, into regfile on the next clock edge)
    // -----------------------------------------------------------------
    assign wb_we   = ex_mem_valid && ex_mem_reg_write && !dmem_stall;
    assign wb_rd   = ex_mem_rd;
    assign wb_data = mem_wb_data;

    // -----------------------------------------------------------------
    // IF stage outputs : address mux feeds the I-cache
    // -----------------------------------------------------------------
    assign imem_req  = !rst;
    assign imem_addr = pc;

    // -----------------------------------------------------------------
    // Trace
    // -----------------------------------------------------------------
    // Once an EBREAK retires the program has halted.  Stop retiring after
    // it so `instr_retired` is the architectural instruction count and does
    // not depend on how many cycles the harness keeps clocking past the end
    // (which otherwise made the count differ between cache configurations).
    localparam EBREAK = 32'h00100073;
    reg halted;
    always @(posedge clk) begin
        if (rst)
            halted <= 1'b0;
        else if (ex_mem_valid && !dmem_stall && ex_mem_instr == EBREAK)
            halted <= 1'b1;
    end

    assign retire_valid = ex_mem_valid && !dmem_stall && !halted;
    assign retire_pc    = ex_mem_pc;
    assign retire_instr = ex_mem_instr;
    assign debug_imem_stall     = imem_stall;
    assign debug_dmem_stall     = dmem_stall;
    assign debug_load_use_stall = load_use_stall;
    assign debug_branch_flush   = ex_redirect;

    // -----------------------------------------------------------------
    // Pipeline register updates
    //   dmem_stall  -> hold every register
    //   imem_stall  -> hold PC + IF/ID, bubble ID/EX
    //   load_use_stall -> hold PC + IF/ID, bubble ID/EX, advance EX/MEM
    //   ex_redirect -> flush IF/ID + ID/EX
    // -----------------------------------------------------------------
    wire stall_front = imem_stall || load_use_stall || dmem_stall;
    wire flush_idex  = ex_redirect || load_use_stall || imem_stall;

    always @(posedge clk) begin
        if (rst) begin
            pc           <= 32'd0;
            if_id_valid  <= 1'b0;
            if_id_pc     <= 32'd0;
            if_id_instr  <= NOP;

            id_ex_valid          <= 1'b0;
            id_ex_pc             <= 32'd0;
            id_ex_instr          <= NOP;
            id_ex_rs1_val        <= 32'd0;
            id_ex_rs2_val        <= 32'd0;
            id_ex_imm            <= 32'd0;
            id_ex_rs1            <= 5'd0;
            id_ex_rs2            <= 5'd0;
            id_ex_rd             <= 5'd0;
            id_ex_funct3         <= 3'd0;
            id_ex_reg_write      <= 1'b0;
            id_ex_mem_read       <= 1'b0;
            id_ex_mem_write      <= 1'b0;
            id_ex_alu_src_b_imm  <= 1'b0;
            id_ex_alu_src_a_pc   <= 1'b0;
            id_ex_alu_op         <= 4'd0;
            id_ex_branch         <= 1'b0;
            id_ex_jump           <= 1'b0;
            id_ex_jalr           <= 1'b0;
            id_ex_mem_byte       <= 1'b0;

            ex_mem_valid     <= 1'b0;
            ex_mem_pc        <= 32'd0;
            ex_mem_instr     <= NOP;
            ex_mem_alu_y     <= 32'd0;
            ex_mem_store_data<= 32'd0;
            ex_mem_rd        <= 5'd0;
            ex_mem_funct3    <= 3'd0;
            ex_mem_reg_write <= 1'b0;
            ex_mem_mem_read  <= 1'b0;
            ex_mem_mem_write <= 1'b0;
            ex_mem_mem_byte  <= 1'b0;
        end else if (dmem_stall) begin
            // Freeze every stage while waiting on D-cache.
        end else begin
            // -------- PC update --------
            if (ex_redirect) begin
                pc <= ex_target;
            end else if (!stall_front) begin
                pc <= pc + 32'd4;
            end

            // -------- IF/ID --------
            if (ex_redirect) begin
                if_id_valid <= 1'b0;
                if_id_pc    <= 32'd0;
                if_id_instr <= NOP;
            end else if (load_use_stall || imem_stall) begin
                // hold IF/ID
            end else begin
                if_id_valid <= 1'b1;
                if_id_pc    <= pc;
                if_id_instr <= imem_rdata;
            end

            // -------- ID/EX --------
            if (flush_idex) begin
                id_ex_valid          <= 1'b0;
                id_ex_reg_write      <= 1'b0;
                id_ex_mem_read       <= 1'b0;
                id_ex_mem_write      <= 1'b0;
                id_ex_alu_src_b_imm  <= 1'b0;
                id_ex_alu_src_a_pc   <= 1'b0;
                id_ex_alu_op         <= 4'd0;
                id_ex_branch         <= 1'b0;
                id_ex_jump           <= 1'b0;
                id_ex_jalr           <= 1'b0;
                id_ex_mem_byte       <= 1'b0;
                id_ex_pc             <= if_id_pc;
                id_ex_instr          <= NOP;
                id_ex_rs1_val        <= 32'd0;
                id_ex_rs2_val        <= 32'd0;
                id_ex_imm            <= 32'd0;
                id_ex_rs1            <= 5'd0;
                id_ex_rs2            <= 5'd0;
                id_ex_rd             <= 5'd0;
                id_ex_funct3         <= 3'd0;
            end else begin
                id_ex_valid          <= if_id_valid;
                id_ex_pc             <= if_id_pc;
                id_ex_instr          <= if_id_instr;
                id_ex_rs1_val        <= rf_rs1_val;
                id_ex_rs2_val        <= rf_rs2_val;
                id_ex_imm            <= id_imm;
                id_ex_rs1            <= id_rs1;
                id_ex_rs2            <= id_rs2;
                id_ex_rd             <= id_rd;
                id_ex_funct3         <= id_funct3;
                id_ex_reg_write      <= ctrl_reg_write;
                id_ex_mem_read       <= ctrl_mem_read;
                id_ex_mem_write      <= ctrl_mem_write;
                id_ex_alu_src_b_imm  <= ctrl_alu_src_b_imm;
                id_ex_alu_src_a_pc   <= ctrl_alu_src_a_pc;
                id_ex_alu_op         <= ctrl_alu_op;
                id_ex_branch         <= ctrl_branch;
                id_ex_jump           <= ctrl_jump;
                id_ex_jalr           <= ctrl_jalr;
                id_ex_mem_byte       <= ctrl_mem_byte;
            end

            // -------- EX/MEM --------
            ex_mem_valid     <= id_ex_valid;
            ex_mem_pc        <= id_ex_pc;
            ex_mem_instr     <= id_ex_instr;
            ex_mem_alu_y     <= id_ex_jump ? (id_ex_pc + 32'd4) : alu_y;
            ex_mem_store_data<= fwd_rs2;
            ex_mem_rd        <= id_ex_rd;
            ex_mem_funct3    <= id_ex_funct3;
            ex_mem_reg_write <= id_ex_reg_write;
            ex_mem_mem_read  <= id_ex_mem_read;
            ex_mem_mem_write <= id_ex_mem_write;
            ex_mem_mem_byte  <= id_ex_mem_byte;
        end
    end
endmodule
