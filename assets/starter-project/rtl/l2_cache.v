`timescale 1ns/1ps

// Optional unified L2 cache.
//
// The lab spec (实验题目2 §3.1) fixes the L2 line size at 64 bytes while
// the L1 caches are 32 bytes.  The upstream port (toward the L1 arbiter)
// is therefore BUS_BYTES (= L1 block size) wide; the internal data array
// and the downstream port (toward main memory) are BLOCK_BYTES wide.
// cpu_addr[OFFSET_BITS-1:BUS_OFFSET_BITS] is the sub-block selector that
// picks which BUS_BYTES half of a BLOCK_BYTES line is returned (or merged
// on a write).
//
// Microarchitecture (combinational tags + block-RAM data):
//   * valid / dirty / tag / PLRU are small arrays read combinationally, so
//     hit detection is exact in the cycle the request is seen.
//   * the 64 KB data store is a synchronous block RAM (one BLOCK_BITS word
//     per {set,way}); it is read into `data_q` with one cycle of latency
//     and written a whole line at a time.  A write-first read port forwards
//     a same-address write so a line written and read back never goes stale.
//   This split avoids the read-after-write hazard that a fully
//   block-RAM-mapped tag+data lookup suffered from.
//
// Replacement: tree pseudo-LRU.  Write policy: write-back + write-allocate.
// A configurable HIT_LATENCY models the cost of a large-SRAM lookup; the
// request-to-ready latency on a hit is exactly HIT_LATENCY cycles
// (default 10, as in the lab spec).
module l2_cache #(
    parameter integer SIZE_BYTES   = 65536,
    parameter integer BLOCK_BYTES  = 64,
    parameter integer BUS_BYTES    = 32,   // L1 block size = upstream bus width
    parameter integer WAYS         = 4,
    parameter integer HIT_LATENCY  = 10
) (
    input  wire                       clk,
    input  wire                       rst,

    // Upstream port (towards the L1 arbiter, BUS_BYTES wide)
    input  wire                       cpu_req,
    input  wire                       cpu_we,
    input  wire [31:0]                cpu_addr,
    input  wire [BUS_BYTES*8-1:0]     cpu_wdata,
    input  wire [BUS_BYTES-1:0]       cpu_be,
    output wire [BUS_BYTES*8-1:0]     cpu_rdata,
    output wire                       cpu_ready,

    // Downstream port (towards main memory, BLOCK_BYTES wide)
    output reg                        mem_req,
    output reg                        mem_we,
    output reg  [31:0]                mem_addr,
    output reg  [BLOCK_BYTES*8-1:0]   mem_wdata,
    output reg  [BLOCK_BYTES-1:0]     mem_be,
    input  wire [BLOCK_BYTES*8-1:0]   mem_rdata,
    input  wire                       mem_ready,

    output reg  [31:0]                hits,
    output reg  [31:0]                misses
);
    localparam integer NUM_BLOCKS     = SIZE_BYTES / BLOCK_BYTES;
    localparam integer NUM_SETS       = NUM_BLOCKS / WAYS;
    localparam integer OFFSET_BITS    = $clog2(BLOCK_BYTES);     // 6 for 64B
    localparam integer BUS_OFFSET_BITS= $clog2(BUS_BYTES);       // 5 for 32B
    localparam integer SUB_BITS       = OFFSET_BITS - BUS_OFFSET_BITS; // 1
    localparam integer INDEX_BITS     = $clog2(NUM_SETS);
    localparam integer TAG_BITS       = 32 - OFFSET_BITS - INDEX_BITS;
    localparam integer BLOCK_BITS     = BLOCK_BYTES * 8;
    localparam integer BUS_BITS       = BUS_BYTES * 8;
    localparam integer WAY_BITS       = (WAYS <= 1) ? 1 : $clog2(WAYS);
    localparam integer DADDR_BITS     = INDEX_BITS + WAY_BITS;
    // Number of HIT_DELAY-end count so request->ready is exactly HIT_LATENCY.
    localparam integer HIT_TARGET     = (HIT_LATENCY <= 1) ? 1 : (HIT_LATENCY - 1);

    // ---- combinational tag / state arrays ----
    reg                   valid [0:NUM_SETS-1][0:WAYS-1];
    reg                   dirty [0:NUM_SETS-1][0:WAYS-1];
    (* ram_style = "distributed" *)
    reg [TAG_BITS-1:0]    tag   [0:NUM_SETS-1][0:WAYS-1];
    reg [2:0]             plru  [0:NUM_SETS-1];

    // ---- synchronous block-RAM data store, one line per {set,way} ----
    (* ram_style = "block" *)
    reg [BLOCK_BITS-1:0]  data_mem [0:(1<<DADDR_BITS)-1];

    integer si, wj;
    initial begin
        for (si = 0; si < NUM_SETS; si = si + 1) begin
            plru[si] = 3'b000;
            for (wj = 0; wj < WAYS; wj = wj + 1) begin
                valid[si][wj] = 1'b0;
                dirty[si][wj] = 1'b0;
            end
        end
    end

    wire [TAG_BITS-1:0]   req_tag   = cpu_addr[31 -: TAG_BITS];
    wire [INDEX_BITS-1:0] req_index = cpu_addr[OFFSET_BITS +: INDEX_BITS];
    wire [SUB_BITS-1:0]   req_sub   = (SUB_BITS == 0) ? 1'b0
                                    : cpu_addr[BUS_OFFSET_BITS +: SUB_BITS];

    // Combinational hit detection (exact, no read latency).
    reg hit_any;
    reg [1:0] hit_way;
    integer w;
    always @(*) begin
        hit_any = 1'b0;
        hit_way = 2'd0;
        for (w = 0; w < WAYS; w = w + 1) begin
            if (valid[req_index][w] && tag[req_index][w] == req_tag) begin
                hit_any = 1'b1;
                hit_way = w[1:0];
            end
        end
    end

    reg [BUS_BITS-1:0] cpu_rdata_r;
    assign cpu_rdata = cpu_rdata_r;

    function [1:0] plru_victim;
        input [2:0] bits;
        begin
            if (WAYS == 1) plru_victim = 2'd0;
            else if (WAYS == 2) plru_victim = bits[0] ? 2'd0 : 2'd1;
            else begin
                if (bits[0] == 1'b0) plru_victim = bits[1] ? 2'd1 : 2'd0;
                else                 plru_victim = bits[2] ? 2'd3 : 2'd2;
            end
        end
    endfunction

    function [2:0] plru_update;
        input [2:0] bits;
        input [1:0] way;
        reg [2:0] nb;
        begin
            nb = bits;
            if (WAYS == 2) begin
                nb[0] = (way == 2'd0) ? 1'b0 : 1'b1;
            end else if (WAYS == 4) begin
                if (way == 2'd0) begin nb[0]=1'b1; nb[1]=1'b1; end
                else if (way == 2'd1) begin nb[0]=1'b1; nb[1]=1'b0; end
                else if (way == 2'd2) begin nb[0]=1'b0; nb[2]=1'b1; end
                else                  begin nb[0]=1'b0; nb[2]=1'b0; end
            end
            plru_update = nb;
        end
    endfunction

    // Overlay a BUS_BYTES write into the chosen sub-block of a 64B line.
    function [BLOCK_BITS-1:0] merge_sub;
        input [BLOCK_BITS-1:0] line;
        input [SUB_BITS-1:0]   sub;
        input [BUS_BITS-1:0]   wd;
        input [BUS_BYTES-1:0]  be;
        integer k;
        reg [BLOCK_BITS-1:0] r;
        begin
            r = line;
            for (k = 0; k < BUS_BYTES; k = k + 1) begin
                if (be[k])
                    r[(sub*BUS_BYTES + k)*8 +: 8] = wd[k*8 +: 8];
            end
            merge_sub = r;
        end
    endfunction

    // ---------------------------- FSM ----------------------------
    localparam ST_IDLE          = 4'd0;
    localparam ST_HIT_DELAY     = 4'd1;
    localparam ST_HIT_DONE      = 4'd2;
    localparam ST_WB_CAP        = 4'd3;  // capture victim line from data RAM
    localparam ST_WB_WAIT       = 4'd4;
    localparam ST_FETCH_WAIT    = 4'd5;
    localparam ST_FETCH_CAPTURE = 4'd6;
    localparam ST_MISS_DONE     = 4'd7;
    reg [3:0] state;

    assign cpu_ready = (state == ST_HIT_DONE) || (state == ST_MISS_DONE);

    integer hit_cnt;

    reg [TAG_BITS-1:0]    pending_tag;
    reg [INDEX_BITS-1:0]  pending_index;
    reg [SUB_BITS-1:0]    pending_sub;
    reg [31:0]            pending_block_addr;
    reg                   pending_we;
    reg [BUS_BITS-1:0]    pending_wdata;
    reg [BUS_BYTES-1:0]   pending_be;
    reg [1:0]             victim_way_r;
    reg [TAG_BITS-1:0]    victim_tag_r;
    reg                   victim_dirty_r;
    reg [BLOCK_BITS-1:0]  victim_block_r;
    reg                   mem_seen_low;

    // ---- data RAM read/write ports ----
    wire [1:0] sel_victim = plru_victim(plru[req_index]);
    wire [INDEX_BITS-1:0] rd_set = (state == ST_IDLE) ? req_index : pending_index;
    wire [1:0]            rd_way = (state == ST_IDLE)
                                 ? (hit_any ? hit_way : sel_victim)
                                 : victim_way_r;
    wire [DADDR_BITS-1:0] data_rd_addr = {rd_set, rd_way[WAY_BITS-1:0]};

    // Write strobe is asserted for exactly one cycle in HIT_DELAY (store
    // commit) and in FETCH_CAPTURE (fill).
    wire hit_commit = (state == ST_HIT_DELAY) && (hit_cnt >= HIT_TARGET);
    reg  [BLOCK_BITS-1:0] data_q;
    reg  [BLOCK_BITS-1:0] data_wr_block;
    reg                   data_we;
    wire [DADDR_BITS-1:0] data_wr_addr = {pending_index, victim_way_r[WAY_BITS-1:0]};

    always @(*) begin
        data_we       = 1'b0;
        data_wr_block = {BLOCK_BITS{1'b0}};
        if (hit_commit && pending_we) begin
            data_we       = 1'b1;
            data_wr_block = merge_sub(data_q, pending_sub, pending_wdata, pending_be);
        end else if (state == ST_FETCH_CAPTURE) begin
            data_we       = 1'b1;
            data_wr_block = pending_we
                          ? merge_sub(mem_rdata, pending_sub, pending_wdata, pending_be)
                          : mem_rdata;
        end
    end

    // Plain read-first synchronous RAM (no output bypass) so Vivado infers
    // the 64 KB L2 data store as block RAM.  Hit detection is on the
    // combinational tags; data_q is consumed in a later state, and a line is
    // never read back in the same cycle it is written, so no bypass needed.
    always @(posedge clk) begin
        data_q <= data_mem[data_rd_addr];
        if (data_we)
            data_mem[data_wr_addr] <= data_wr_block;
    end

    // ---------------- testbench inspection (sim only) ----------------
    function peek_hit;
        input [31:0] a;
        reg [TAG_BITS-1:0]   f_tag;
        reg [INDEX_BITS-1:0] f_index;
        integer pw;
        begin
            f_tag   = a[31 -: TAG_BITS];
            f_index = a[OFFSET_BITS +: INDEX_BITS];
            peek_hit = 1'b0;
            for (pw = 0; pw < WAYS; pw = pw + 1)
                if (valid[f_index][pw] && tag[f_index][pw] == f_tag)
                    peek_hit = 1'b1;
        end
    endfunction

    function [31:0] peek_word;
        input [31:0] a;
        reg [TAG_BITS-1:0]   f_tag;
        reg [INDEX_BITS-1:0] f_index;
        reg [OFFSET_BITS-3:0] f_word;
        integer pw;
        begin
            f_tag   = a[31 -: TAG_BITS];
            f_index = a[OFFSET_BITS +: INDEX_BITS];
            f_word  = a[OFFSET_BITS-1:2];
            peek_word = 32'hxxxx_xxxx;
            for (pw = 0; pw < WAYS; pw = pw + 1)
                if (valid[f_index][pw] && tag[f_index][pw] == f_tag)
                    peek_word = data_mem[{f_index, pw[WAY_BITS-1:0]}][f_word*32 +: 32];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state    <= ST_IDLE;
            mem_req  <= 1'b0;
            mem_we   <= 1'b0;
            mem_addr <= 32'd0;
            mem_wdata<= {BLOCK_BITS{1'b0}};
            mem_be   <= {BLOCK_BYTES{1'b0}};
            hits     <= 32'd0;
            misses   <= 32'd0;
            hit_cnt  <= 0;
            mem_seen_low <= 1'b0;
            cpu_rdata_r <= {BUS_BITS{1'b0}};
            for (si = 0; si < NUM_SETS; si = si + 1) begin
                plru[si] <= 3'b000;
                for (wj = 0; wj < WAYS; wj = wj + 1) begin
                    valid[si][wj] <= 1'b0;
                    dirty[si][wj] <= 1'b0;
                end
            end
        end else begin
            mem_req <= 1'b0;
            mem_we  <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (cpu_req) begin
                        pending_tag        <= req_tag;
                        pending_index      <= req_index;
                        pending_sub        <= req_sub;
                        pending_block_addr <= {cpu_addr[31:OFFSET_BITS],
                                               {OFFSET_BITS{1'b0}}};
                        pending_we         <= cpu_we;
                        pending_wdata      <= cpu_wdata;
                        pending_be         <= cpu_be;
                        if (hit_any) begin
                            hits <= hits + 32'd1;
                            plru[req_index] <= plru_update(plru[req_index], hit_way);
                            victim_way_r    <= hit_way;
                            hit_cnt         <= 1;
                            state           <= ST_HIT_DELAY;
                        end else begin
                            misses         <= misses + 32'd1;
                            victim_way_r   <= sel_victim;
                            victim_tag_r   <= tag  [req_index][sel_victim];
                            victim_dirty_r <= dirty[req_index][sel_victim]
                                              && valid[req_index][sel_victim];
                            // data_q gets the victim line next cycle (rd_addr
                            // = {req_index, sel_victim} this cycle).
                            state          <= ST_WB_CAP;
                        end
                    end
                end

                ST_HIT_DELAY: begin
                    if (hit_cnt >= HIT_TARGET) begin
                        if (pending_we)
                            dirty[pending_index][victim_way_r] <= 1'b1;
                        // Return the requested sub-block.  (On a write the
                        // L1 ignores the read data; the line itself is
                        // updated through the data_we path.)
                        cpu_rdata_r <= data_q[pending_sub*BUS_BITS +: BUS_BITS];
                        state       <= ST_HIT_DONE;
                    end else begin
                        hit_cnt <= hit_cnt + 1;
                    end
                end

                ST_HIT_DONE: state <= ST_IDLE;

                ST_WB_CAP: begin
                    // data_q now holds the victim line.
                    victim_block_r <= data_q;
                    if (victim_dirty_r) begin
                        mem_seen_low <= 1'b0;
                        state        <= ST_WB_WAIT;
                    end else begin
                        mem_seen_low <= 1'b0;
                        state        <= ST_FETCH_WAIT;
                    end
                end

                ST_WB_WAIT: begin
                    mem_req   <= 1'b1;
                    mem_we    <= 1'b1;
                    mem_addr  <= {victim_tag_r, pending_index, {OFFSET_BITS{1'b0}}};
                    mem_wdata <= victim_block_r;
                    mem_be    <= {BLOCK_BYTES{1'b1}};
                    if (!mem_ready) mem_seen_low <= 1'b1;
                    if (mem_ready && mem_seen_low) begin
                        mem_req      <= 1'b0;
                        mem_we       <= 1'b0;
                        mem_seen_low <= 1'b0;
                        state        <= ST_FETCH_WAIT;
                    end
                end

                ST_FETCH_WAIT: begin
                    mem_req  <= 1'b1;
                    mem_we   <= 1'b0;
                    mem_addr <= pending_block_addr;
                    if (!mem_ready) mem_seen_low <= 1'b1;
                    if (mem_ready && mem_seen_low) begin
                        mem_req <= 1'b0;
                        state   <= ST_FETCH_CAPTURE;
                    end
                end

                ST_FETCH_CAPTURE: begin
                    // data_mem write handled by the combinational data_we path.
                    valid[pending_index][victim_way_r] <= 1'b1;
                    tag  [pending_index][victim_way_r] <= pending_tag;
                    dirty[pending_index][victim_way_r] <= pending_we ? 1'b1 : 1'b0;
                    plru[pending_index] <= plru_update(plru[pending_index],
                                                       victim_way_r);
                    cpu_rdata_r <= mem_rdata[pending_sub*BUS_BITS +: BUS_BITS];
                    state       <= ST_MISS_DONE;
                end

                ST_MISS_DONE: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
