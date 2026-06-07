`timescale 1ns/1ps

// Synthesis-only wrapper around `riscv_cached_soc`.
//
// The simulation SoC embeds a behavioural `main_memory` model that is
// not BRAM-inferrable and previously tripped Vivado's 524288-bit
// dissolve limit.  This wrapper does NOT instantiate `riscv_cached_soc`
// directly because that module contains the main memory.  Instead it
// recreates the core + caches + arbiter (+ optional L2) hierarchy and
// exposes the block-level memory interface as top-level ports — the
// same hardware boundary that would ship to a real FPGA where the
// main memory lives off-chip in DDR.
//
// All configuration knobs (cache sizes, ways, block sizes) match
// `riscv_cached_soc` and default to the docx §3.1 recommended values
// (8 KB L1 / 32 B / 2-way, 64 KB L2 / 64 B / 4-way).
module riscv_cached_soc_synth #(
    parameter integer ICACHE_SIZE_BYTES  = 8192,
    parameter integer ICACHE_WAYS        = 2,
    parameter integer DCACHE_SIZE_BYTES  = 8192,
    parameter integer DCACHE_WAYS        = 2,
    parameter integer BLOCK_BYTES        = 32,
    parameter integer ENABLE_L2          = 0,
    parameter integer L2_SIZE_BYTES      = 65536,
    parameter integer L2_BLOCK_BYTES     = 64,
    parameter integer L2_WAYS            = 4,
    parameter integer L2_HIT_LATENCY     = 10
) (
    input  wire                            clk,
    input  wire                            rst,

    // Block-level memory port.  The width is parameterised by
    // L2_BLOCK_BYTES when L2 is enabled and BLOCK_BYTES otherwise so
    // the wrapper exposes the actual hardware bus the design would
    // drive in either configuration.
    output wire                            mem_req,
    output wire                            mem_we,
    output wire [31:0]                     mem_addr,
    output wire [(ENABLE_L2?L2_BLOCK_BYTES:BLOCK_BYTES)*8-1:0]
                                           mem_wdata,
    output wire [(ENABLE_L2?L2_BLOCK_BYTES:BLOCK_BYTES)-1:0]
                                           mem_be,
    input  wire [(ENABLE_L2?L2_BLOCK_BYTES:BLOCK_BYTES)*8-1:0]
                                           mem_rdata,
    input  wire                            mem_ready,

    // Free-running 32-bit counter for completed memory transactions.
    // Matches what main_memory exports in simulation.
    output reg  [31:0]                     mem_accesses_count,

    // Compressed status (mirrors retire+counter outputs) so the cache
    // hierarchy cannot be optimised away.
    output wire [7:0]                      status
);
    localparam integer BLOCK_BITS = BLOCK_BYTES * 8;

    // ============================================================
    // Internal CPU + cache fabric (manual instantiation rather than
    // reusing riscv_cached_soc because we need to expose the memory
    // port at the wrapper's top level and route mem_accesses out as a
    // top-level counter).
    // ============================================================
    wire        retire_valid;
    wire [31:0] retire_pc;
    wire [31:0] retire_instr;
    wire        debug_imem_stall;
    wire        debug_dmem_stall;
    wire        debug_load_use_stall;
    wire        debug_branch_flush;

    wire [63:0] cycles;
    wire [63:0] instr_retired;
    wire [63:0] imem_stall_cycles;
    wire [63:0] dmem_stall_cycles;
    wire [63:0] load_use_stalls;
    wire [63:0] branch_flushes;

    wire [31:0] icache_hits;
    wire [31:0] icache_misses;
    wire [31:0] dcache_hits;
    wire [31:0] dcache_misses;
    wire [31:0] dcache_writes_through;
    wire [31:0] l2_hits;
    wire [31:0] l2_misses;

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

    // ------------------------------------------------ L1 I-cache
    wire                   i2m_req;
    wire                   i2m_we;
    wire [31:0]            i2m_addr;
    wire [BLOCK_BITS-1:0]  i2m_wdata;
    wire [BLOCK_BYTES-1:0] i2m_be;
    wire [BLOCK_BITS-1:0]  i2m_rdata;
    wire                   i2m_ready;

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

    // ------------------------------------------------ L1 D-cache
    wire                   d2m_req;
    wire                   d2m_we;
    wire [31:0]            d2m_addr;
    wire [BLOCK_BITS-1:0]  d2m_wdata;
    wire [BLOCK_BYTES-1:0] d2m_be;
    wire [BLOCK_BITS-1:0]  d2m_rdata;
    wire                   d2m_ready;

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

    // ------------------------------------------------ Arbiter (32B)
    wire                   arb_req;
    wire                   arb_we;
    wire [31:0]            arb_addr;
    wire [BLOCK_BITS-1:0]  arb_wdata;
    wire [BLOCK_BYTES-1:0] arb_be;
    wire [BLOCK_BITS-1:0]  arb_rdata;
    wire                   arb_ready;

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
    generate
        if (ENABLE_L2) begin : gen_l2
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
                .mem_req(mem_req), .mem_we(mem_we),
                .mem_addr(mem_addr), .mem_wdata(mem_wdata),
                .mem_be(mem_be),
                .mem_rdata(mem_rdata), .mem_ready(mem_ready),
                .hits(l2_hits), .misses(l2_misses)
            );
        end else begin : gen_no_l2
            assign mem_req   = arb_req;
            assign mem_we    = arb_we;
            assign mem_addr  = arb_addr;
            assign mem_wdata = arb_wdata;
            assign mem_be    = arb_be;
            assign arb_rdata = mem_rdata;
            assign arb_ready = mem_ready;
            assign l2_hits   = 32'd0;
            assign l2_misses = 32'd0;
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

    // Count completed main-memory transactions (mirrors what
    // main_memory exports in simulation).
    always @(posedge clk) begin
        if (rst)            mem_accesses_count <= 32'd0;
        else if (mem_ready) mem_accesses_count <= mem_accesses_count + 32'd1;
    end

    assign status = cycles[7:0]
                  ^ instr_retired[7:0]
                  ^ retire_pc[7:0]
                  ^ retire_instr[7:0]
                  ^ icache_hits[7:0]
                  ^ icache_misses[7:0]
                  ^ dcache_hits[7:0]
                  ^ dcache_misses[7:0]
                  ^ dcache_writes_through[7:0]
                  ^ l2_hits[7:0]
                  ^ l2_misses[7:0]
                  ^ imem_stall_cycles[7:0]
                  ^ dmem_stall_cycles[7:0]
                  ^ load_use_stalls[7:0]
                  ^ branch_flushes[7:0]
                  ^ mem_accesses_count[7:0]
                  ^ {3'b0, retire_valid, debug_imem_stall,
                          debug_dmem_stall, debug_load_use_stall,
                          debug_branch_flush};
endmodule
