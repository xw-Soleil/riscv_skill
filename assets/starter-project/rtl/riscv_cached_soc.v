`timescale 1ns/1ps

// Top wrapper for the cached system: core + L1 I/D caches + optional L2 +
// arbiter + main memory.  The same module is used for the L1-only and
// L1+L2 configurations via the `ENABLE_L2` parameter.
module riscv_cached_soc #(
    parameter integer ICACHE_SIZE_BYTES  = 8192,
    parameter integer ICACHE_WAYS        = 2,
    parameter integer DCACHE_SIZE_BYTES  = 8192,
    parameter integer DCACHE_WAYS        = 2,
    parameter integer BLOCK_BYTES        = 32,   // L1 block size (also L1↔L2 bus)
    parameter integer ENABLE_L2          = 0,
    parameter integer L2_SIZE_BYTES      = 65536,
    parameter integer L2_BLOCK_BYTES     = 64,   // L2 internal block size; spec: 64
    parameter integer L2_WAYS            = 4,
    parameter integer L2_HIT_LATENCY     = 10,
    parameter integer MEM_SIZE_BYTES     = 1 << 16,
    parameter integer MEM_LATENCY        = 100
) (
    input  wire        clk,
    input  wire        rst,

    // Trace
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    output wire        debug_imem_stall,
    output wire        debug_dmem_stall,
    output wire        debug_load_use_stall,
    output wire        debug_branch_flush,

    // Performance counters
    output wire [63:0] cycles,
    output wire [63:0] instr_retired,
    output wire [63:0] imem_stall_cycles,
    output wire [63:0] dmem_stall_cycles,
    output wire [63:0] load_use_stalls,
    output wire [63:0] branch_flushes,
    output wire [31:0] icache_hits,
    output wire [31:0] icache_misses,
    output wire [31:0] dcache_hits,
    output wire [31:0] dcache_misses,
    output wire [31:0] dcache_writes_through,
    output wire [31:0] l2_hits,
    output wire [31:0] l2_misses,
    output wire [31:0] mem_accesses
);
    localparam integer BLOCK_BITS = BLOCK_BYTES * 8;

    // ------------------------------------------------ Core <-> caches
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

    // ------------------------------------------------ L1 caches
    wire                  i2m_req;
    wire                  i2m_we;
    wire [31:0]           i2m_addr;
    wire [BLOCK_BITS-1:0] i2m_wdata;
    wire [BLOCK_BYTES-1:0] i2m_be;
    wire [BLOCK_BITS-1:0] i2m_rdata;
    wire                  i2m_ready;

    l1_icache #(
        .SIZE_BYTES (ICACHE_SIZE_BYTES),
        .BLOCK_BYTES(BLOCK_BYTES),
        .WAYS       (ICACHE_WAYS)
    ) u_icache (
        .clk(clk), .rst(rst),
        .cpu_req(cpu_imem_req), .cpu_addr(cpu_imem_addr),
        .cpu_rdata(cpu_imem_rdata), .cpu_ready(cpu_imem_ready),
        .mem_req(i2m_req), .mem_we(i2m_we),
        .mem_addr(i2m_addr), .mem_wdata(i2m_wdata), .mem_be(i2m_be),
        .mem_rdata(i2m_rdata), .mem_ready(i2m_ready),
        .hits(icache_hits), .misses(icache_misses)
    );

    wire                  d2m_req;
    wire                  d2m_we;
    wire [31:0]           d2m_addr;
    wire [BLOCK_BITS-1:0] d2m_wdata;
    wire [BLOCK_BYTES-1:0] d2m_be;
    wire [BLOCK_BITS-1:0] d2m_rdata;
    wire                  d2m_ready;

    l1_dcache #(
        .SIZE_BYTES (DCACHE_SIZE_BYTES),
        .BLOCK_BYTES(BLOCK_BYTES),
        .WAYS       (DCACHE_WAYS)
    ) u_dcache (
        .clk(clk), .rst(rst),
        .cpu_req(cpu_dmem_req), .cpu_we(cpu_dmem_we),
        .cpu_be(cpu_dmem_be), .cpu_addr(cpu_dmem_addr),
        .cpu_wdata(cpu_dmem_wdata),
        .cpu_rdata(cpu_dmem_rdata), .cpu_ready(cpu_dmem_ready),
        .mem_req(d2m_req), .mem_we(d2m_we),
        .mem_addr(d2m_addr), .mem_wdata(d2m_wdata), .mem_be(d2m_be),
        .mem_rdata(d2m_rdata), .mem_ready(d2m_ready),
        .hits(dcache_hits), .misses(dcache_misses),
        .writes_through(dcache_writes_through)
    );

    // ------------------------------------------------ Arbiter -> next level
    wire                  arb_req;
    wire                  arb_we;
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

    // ------------------------------------------------ Optional L2
    //
    // When L2 is enabled, the main-memory port runs at L2_BLOCK_BYTES
    // width (e.g. 64B per the spec) and the L2 internally maps the
    // BLOCK_BYTES (32B) L1 bus to the L2 line by selecting one
    // sub-block on hit/fill.  When L2 is disabled the arbiter speaks
    // directly to a BLOCK_BYTES-wide main memory.
    localparam integer L2_BLOCK_BITS = L2_BLOCK_BYTES * 8;

    generate
        if (ENABLE_L2) begin : gen_l2
            wire                       l2m_req;
            wire                       l2m_we;
            wire [31:0]                l2m_addr;
            wire [L2_BLOCK_BITS-1:0]   l2m_wdata;
            wire [L2_BLOCK_BYTES-1:0]  l2m_be;
            wire [L2_BLOCK_BITS-1:0]   l2m_rdata;
            wire                       l2m_ready;

            l2_cache #(
                .SIZE_BYTES (L2_SIZE_BYTES),
                .BLOCK_BYTES(L2_BLOCK_BYTES),
                .BUS_BYTES  (BLOCK_BYTES),
                .WAYS       (L2_WAYS),
                .HIT_LATENCY(L2_HIT_LATENCY)
            ) u_l2 (
                .clk(clk), .rst(rst),
                .cpu_req(arb_req), .cpu_we(arb_we), .cpu_addr(arb_addr),
                .cpu_wdata(arb_wdata), .cpu_be(arb_be),
                .cpu_rdata(arb_rdata), .cpu_ready(arb_ready),
                .mem_req(l2m_req), .mem_we(l2m_we),
                .mem_addr(l2m_addr), .mem_wdata(l2m_wdata),
                .mem_be(l2m_be),
                .mem_rdata(l2m_rdata), .mem_ready(l2m_ready),
                .hits(l2_hits), .misses(l2_misses)
            );

            main_memory #(
                .SIZE_BYTES (MEM_SIZE_BYTES),
                .BLOCK_BYTES(L2_BLOCK_BYTES),
                .LATENCY    (MEM_LATENCY)
            ) u_mem (
                .clk(clk), .rst(rst),
                .req(l2m_req), .we(l2m_we), .addr(l2m_addr),
                .wdata(l2m_wdata), .be(l2m_be),
                .rdata(l2m_rdata), .ready(l2m_ready),
                .mem_accesses(mem_accesses)
            );
        end else begin : gen_no_l2
            assign l2_hits   = 32'd0;
            assign l2_misses = 32'd0;

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
        end
    endgenerate

    // ------------------------------------------------ Performance counters
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
