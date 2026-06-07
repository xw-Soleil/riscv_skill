`timescale 1ns/1ps

// Baseline SoC with no caches.  Every CPU memory access goes directly to
// main memory through a `bypass_port`, paying MEM_LATENCY cycles.  Used
// as the speedup baseline in the experiment.
module riscv_nocache_soc #(
    parameter integer BLOCK_BYTES    = 32,
    parameter integer MEM_SIZE_BYTES = 1 << 16,
    parameter integer MEM_LATENCY    = 100
) (
    input  wire        clk,
    input  wire        rst,

    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    output wire        debug_imem_stall,
    output wire        debug_dmem_stall,
    output wire        debug_load_use_stall,
    output wire        debug_branch_flush,

    output wire [63:0] cycles,
    output wire [63:0] instr_retired,
    output wire [63:0] imem_stall_cycles,
    output wire [63:0] dmem_stall_cycles,
    output wire [63:0] load_use_stalls,
    output wire [63:0] branch_flushes,
    output wire [31:0] imem_accesses,
    output wire [31:0] dmem_accesses,
    output wire [31:0] mem_accesses
);
    localparam integer BLOCK_BITS = BLOCK_BYTES * 8;

    wire        cpu_imem_req;
    wire [31:0] cpu_imem_addr;
    wire [31:0] cpu_imem_rdata;
    wire        cpu_imem_ready;

    wire        cpu_dmem_req;
    wire [31:0] cpu_dmem_addr;
    wire        cpu_dmem_we;
    wire [3:0]  cpu_dmem_be;
    wire [31:0] cpu_dmem_wdata;
    wire [31:0] cpu_dmem_rdata;
    wire        cpu_dmem_ready;

    riscv_core u_core (
        .clk(clk), .rst(rst),
        .imem_req(cpu_imem_req), .imem_addr(cpu_imem_addr),
        .imem_rdata(cpu_imem_rdata), .imem_ready(cpu_imem_ready),
        .dmem_req(cpu_dmem_req), .dmem_addr(cpu_dmem_addr),
        .dmem_we(cpu_dmem_we), .dmem_be(cpu_dmem_be),
        .dmem_wdata(cpu_dmem_wdata),
        .dmem_rdata(cpu_dmem_rdata), .dmem_ready(cpu_dmem_ready),
        .retire_valid(retire_valid), .retire_pc(retire_pc),
        .retire_instr(retire_instr),
        .debug_imem_stall(debug_imem_stall),
        .debug_dmem_stall(debug_dmem_stall),
        .debug_load_use_stall(debug_load_use_stall),
        .debug_branch_flush(debug_branch_flush)
    );

    wire                  i2m_req, i2m_we;
    wire [31:0]           i2m_addr;
    wire [BLOCK_BITS-1:0] i2m_wdata;
    wire [BLOCK_BYTES-1:0] i2m_be;
    wire [BLOCK_BITS-1:0] i2m_rdata;
    wire                  i2m_ready;

    bypass_port #(.BLOCK_BYTES(BLOCK_BYTES), .IS_DCACHE(0)) u_ipath (
        .clk(clk), .rst(rst),
        .cpu_req(cpu_imem_req), .cpu_we(1'b0), .cpu_be(4'b0),
        .cpu_addr(cpu_imem_addr), .cpu_wdata(32'd0),
        .cpu_rdata(cpu_imem_rdata), .cpu_ready(cpu_imem_ready),
        .mem_req(i2m_req), .mem_we(i2m_we), .mem_addr(i2m_addr),
        .mem_wdata(i2m_wdata), .mem_be(i2m_be),
        .mem_rdata(i2m_rdata), .mem_ready(i2m_ready),
        .accesses(imem_accesses)
    );

    wire                  d2m_req, d2m_we;
    wire [31:0]           d2m_addr;
    wire [BLOCK_BITS-1:0] d2m_wdata;
    wire [BLOCK_BYTES-1:0] d2m_be;
    wire [BLOCK_BITS-1:0] d2m_rdata;
    wire                  d2m_ready;

    bypass_port #(.BLOCK_BYTES(BLOCK_BYTES), .IS_DCACHE(1)) u_dpath (
        .clk(clk), .rst(rst),
        .cpu_req(cpu_dmem_req), .cpu_we(cpu_dmem_we),
        .cpu_be(cpu_dmem_be), .cpu_addr(cpu_dmem_addr),
        .cpu_wdata(cpu_dmem_wdata),
        .cpu_rdata(cpu_dmem_rdata), .cpu_ready(cpu_dmem_ready),
        .mem_req(d2m_req), .mem_we(d2m_we), .mem_addr(d2m_addr),
        .mem_wdata(d2m_wdata), .mem_be(d2m_be),
        .mem_rdata(d2m_rdata), .mem_ready(d2m_ready),
        .accesses(dmem_accesses)
    );

    wire                  arb_req, arb_we;
    wire [31:0]           arb_addr;
    wire [BLOCK_BITS-1:0] arb_wdata;
    wire [BLOCK_BYTES-1:0] arb_be;
    wire [BLOCK_BITS-1:0] arb_rdata;
    wire                  arb_ready;

    mem_arbiter #(.BLOCK_BYTES(BLOCK_BYTES)) u_arb (
        .clk(clk), .rst(rst),
        .a_req(d2m_req), .a_we(d2m_we), .a_addr(d2m_addr),
        .a_wdata(d2m_wdata), .a_be(d2m_be),
        .a_rdata(d2m_rdata), .a_ready(d2m_ready),
        .b_req(i2m_req), .b_we(i2m_we), .b_addr(i2m_addr),
        .b_wdata(i2m_wdata), .b_be(i2m_be),
        .b_rdata(i2m_rdata), .b_ready(i2m_ready),
        .m_req(arb_req), .m_we(arb_we), .m_addr(arb_addr),
        .m_wdata(arb_wdata), .m_be(arb_be),
        .m_rdata(arb_rdata), .m_ready(arb_ready)
    );

    main_memory #(
        .SIZE_BYTES (MEM_SIZE_BYTES),
        .BLOCK_BYTES(BLOCK_BYTES),
        .LATENCY    (MEM_LATENCY)
    ) u_mem (
        .clk(clk), .rst(rst),
        .req(arb_req), .we(arb_we), .addr(arb_addr),
        .wdata(arb_wdata), .be(arb_be),
        .rdata(arb_rdata), .ready(arb_ready),
        .mem_accesses(mem_accesses)
    );

    perf_counters u_perf (
        .clk(clk), .rst(rst),
        .retire_valid(retire_valid),
        .imem_stall(debug_imem_stall),
        .dmem_stall(debug_dmem_stall),
        .load_use_stall(debug_load_use_stall),
        .branch_flush(debug_branch_flush),
        .cycles(cycles), .instr_retired(instr_retired),
        .imem_stall_cycles(imem_stall_cycles),
        .dmem_stall_cycles(dmem_stall_cycles),
        .load_use_stalls(load_use_stalls),
        .branch_flushes(branch_flushes)
    );
endmodule
