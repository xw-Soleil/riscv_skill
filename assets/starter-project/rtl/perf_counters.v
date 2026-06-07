`timescale 1ns/1ps

// Centralised performance counter block.  Mirrors the cache hit/miss
// counters and aggregates total cycles, retired instructions, and front-
// or back-end stalls so the testbench can compute CPI and AMAT.
module perf_counters (
    input  wire        clk,
    input  wire        rst,
    input  wire        retire_valid,
    input  wire        imem_stall,
    input  wire        dmem_stall,
    input  wire        load_use_stall,
    input  wire        branch_flush,

    output reg [63:0]  cycles,
    output reg [63:0]  instr_retired,
    output reg [63:0]  imem_stall_cycles,
    output reg [63:0]  dmem_stall_cycles,
    output reg [63:0]  load_use_stalls,
    output reg [63:0]  branch_flushes
);
    always @(posedge clk) begin
        if (rst) begin
            cycles            <= 64'd0;
            instr_retired     <= 64'd0;
            imem_stall_cycles <= 64'd0;
            dmem_stall_cycles <= 64'd0;
            load_use_stalls   <= 64'd0;
            branch_flushes    <= 64'd0;
        end else begin
            cycles <= cycles + 64'd1;
            if (retire_valid)   instr_retired     <= instr_retired + 64'd1;
            if (imem_stall)     imem_stall_cycles <= imem_stall_cycles + 64'd1;
            if (dmem_stall)     dmem_stall_cycles <= dmem_stall_cycles + 64'd1;
            if (load_use_stall) load_use_stalls   <= load_use_stalls + 64'd1;
            if (branch_flush)   branch_flushes    <= branch_flushes + 64'd1;
        end
    end
endmodule
