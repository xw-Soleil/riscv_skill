`timescale 1ns/1ps

// Behavioural main memory.
//
// One-block-wide port driven by the cache hierarchy.  Each transaction
// takes `LATENCY` cycles to complete.  Writes are byte-enable masked so
// the same port handles both whole-block fills (BE=all-ones) and L1
// write-through word writes (BE=4 bits set within the block).
//
// Reads return the full block at `addr` (lower bits of `addr` are
// truncated to the block boundary).  `ready` pulses for one cycle when
// the burst completes.
module main_memory #(
    parameter integer SIZE_BYTES  = 1 << 16,
    parameter integer BLOCK_BYTES = 64,
    parameter integer LATENCY     = 100
) (
    input  wire                            clk,
    input  wire                            rst,

    input  wire                            req,
    input  wire                            we,
    input  wire [31:0]                     addr,
    input  wire [BLOCK_BYTES*8-1:0]        wdata,
    input  wire [BLOCK_BYTES-1:0]          be,
    output reg  [BLOCK_BYTES*8-1:0]        rdata,
    output reg                             ready,

    // Number of completed main-memory transactions (one per `ready` pulse).
    // Required by experiment 2, §3.3.
    output reg  [31:0]                     mem_accesses
);
    reg [7:0] mem [0:SIZE_BYTES-1];

    integer i;
    initial begin
        for (i = 0; i < SIZE_BYTES; i = i + 1) mem[i] = 8'd0;
    end

    integer cycle_cnt;
    reg     busy;
    reg     pending_we;
    reg [31:0] pending_addr;
    reg [BLOCK_BYTES*8-1:0] pending_wdata;
    reg [BLOCK_BYTES-1:0]   pending_be;

    integer base;
    integer b;

    always @(posedge clk) begin
        if (rst) begin
            busy         <= 1'b0;
            ready        <= 1'b0;
            cycle_cnt    <= 0;
            rdata        <= {BLOCK_BYTES*8{1'b0}};
            mem_accesses <= 32'd0;
        end else begin
            // One-cycle dead time after a completed transaction so the
            // lingering req from the upstream cache is not latched as a
            // duplicate request.  The cache deasserts its req via FSM
            // state change in the cycle following `ready`.
            if (!busy && !ready) begin
                if (req) begin
`ifdef DEBUG_L2
                    $display("MEM_REQ t=%0t addr=%08x we=%0d", $time, addr, we);
`endif
                    busy          <= 1'b1;
                    cycle_cnt     <= 1;
                    pending_we    <= we;
                    pending_addr  <= addr;
                    pending_wdata <= wdata;
                    pending_be    <= be;
                end
            end
            ready <= 1'b0;
            if (busy) begin
                cycle_cnt <= cycle_cnt + 1;
                if (cycle_cnt >= LATENCY) begin
                    busy         <= 1'b0;
                    ready        <= 1'b1;
                    mem_accesses <= mem_accesses + 32'd1;
                    base         = pending_addr - (pending_addr % BLOCK_BYTES);
`ifdef DEBUG_L2
                    $display("MEM_DONE t=%0t addr=%08x base=%08x r0=%02x%02x%02x%02x",
                             $time, pending_addr, base,
                             mem[base+3], mem[base+2], mem[base+1], mem[base]);
`endif
                    if (pending_we) begin
                        for (b = 0; b < BLOCK_BYTES; b = b + 1) begin
                            if (pending_be[b])
                                mem[base + b] <= pending_wdata[b*8 +: 8];
                        end
                    end
                    for (b = 0; b < BLOCK_BYTES; b = b + 1) begin
                        rdata[b*8 +: 8] <= pending_we ? pending_wdata[b*8 +: 8]
                                                     : mem[base + b];
                    end
                end
            end
        end
    end

    function [31:0] peek_word;
        input [31:0] a;
        reg [31:0] aw;
        begin
            aw = a & 32'hffff_fffc;
            peek_word = {mem[aw+3], mem[aw+2], mem[aw+1], mem[aw]};
        end
    endfunction
endmodule
