`timescale 1ns/1ps

// Parameterised set-associative L1 instruction cache.
//   Read-only from the CPU.  Tree pseudo-LRU replacement.
//
// Microarchitecture: combinational tags + block-RAM data.
//   * valid / tag / PLRU are small combinational arrays, so hit detection
//     is exact in the cycle the address is presented.
//   * the 8 KB data store is a synchronous block RAM (one line per
//     {set,way}); a hit reads it with one cycle of latency.  So a hit is
//     serviced with 1 cycle of access latency (`cpu_ready` the cycle after
//     the request) — the docx "L1 hit = 1 cycle" modelled with a
//     synthesisable BRAM-backed data array (a purely combinational
//     same-cycle data read does not fit the target FPGA at 8 KB).
module l1_icache #(
    parameter integer SIZE_BYTES  = 8192,
    parameter integer BLOCK_BYTES = 32,
    parameter integer WAYS        = 2
) (
    input  wire                       clk,
    input  wire                       rst,

    input  wire                       cpu_req,
    input  wire [31:0]                cpu_addr,
    output wire [31:0]                cpu_rdata,
    output wire                       cpu_ready,

    output wire                       mem_req,
    output wire                       mem_we,
    output wire [31:0]                mem_addr,
    output wire [BLOCK_BYTES*8-1:0]   mem_wdata,
    output wire [BLOCK_BYTES-1:0]     mem_be,
    input  wire [BLOCK_BYTES*8-1:0]   mem_rdata,
    input  wire                       mem_ready,

    output reg  [31:0]                hits,
    output reg  [31:0]                misses
);
    localparam integer NUM_BLOCKS  = SIZE_BYTES / BLOCK_BYTES;
    localparam integer NUM_SETS    = NUM_BLOCKS / WAYS;
    localparam integer OFFSET_BITS = $clog2(BLOCK_BYTES);
    localparam integer INDEX_BITS  = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1;
    localparam integer TAG_BITS    = 32 - OFFSET_BITS - INDEX_BITS;
    localparam integer BLOCK_BITS  = BLOCK_BYTES * 8;
    localparam integer WAY_BITS    = (WAYS <= 1) ? 1 : $clog2(WAYS);
    localparam integer DADDR_BITS  = INDEX_BITS + WAY_BITS;

    // Combinational tag / state arrays.
    reg                  valid [0:NUM_SETS-1][0:WAYS-1];
    reg [TAG_BITS-1:0]   tag   [0:NUM_SETS-1][0:WAYS-1];
    reg [2:0]            plru  [0:NUM_SETS-1];
    // Synchronous block-RAM data store, one line per {set,way}.
    (* ram_style = "block" *)
    reg [BLOCK_BITS-1:0] data_mem [0:(1<<DADDR_BITS)-1];

    integer si, wj;
    initial begin
        for (si = 0; si < NUM_SETS; si = si + 1) begin
            plru[si] = 3'b000;
            for (wj = 0; wj < WAYS; wj = wj + 1) begin
                valid[si][wj] = 1'b0;
                tag  [si][wj] = {TAG_BITS{1'b0}};
            end
        end
    end

    wire [TAG_BITS-1:0]    req_tag    = cpu_addr[31 -: TAG_BITS];
    wire [INDEX_BITS-1:0]  req_index  = (NUM_SETS > 1)
                                      ? cpu_addr[OFFSET_BITS +: INDEX_BITS]
                                      : 1'b0;
    wire [3:0]             word_idx   = cpu_addr[OFFSET_BITS-1:2];

    // Combinational hit detection on the small tag arrays.
    reg hit_any;
    reg [1:0] hit_way;
    integer w;
    always @(*) begin
        hit_any = 1'b0;
        hit_way = 2'd0;
        for (w = 0; w < WAYS; w = w + 1)
            if (valid[req_index][w] && tag[req_index][w] == req_tag) begin
                hit_any = 1'b1;
                hit_way = w[1:0];
            end
    end

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

    // FSM: hit = IDLE (issue BRAM read) -> HIT (return next cycle).
    localparam ST_IDLE = 2'd0;
    localparam ST_HIT  = 2'd1;  // data_q valid this cycle, return it
    localparam ST_WAIT = 2'd2;  // miss: block fetch outstanding
    localparam ST_FILL = 2'd3;  // miss: fetched word ready, return it
    reg [1:0] state;

    reg [TAG_BITS-1:0]   pending_tag;
    reg [INDEX_BITS-1:0] pending_index;
    reg [3:0]            pending_word_idx;
    reg [31:0]           pending_block_addr;
    reg [1:0]            victim_way_r;
    reg [31:0]           fill_word_r;

    // Count each fetched address once even if the PC is held during an
    // unrelated stall (the I-cache request address would otherwise repeat).
    reg                  serviced_valid;
    reg [31:0]           serviced_addr;
    wire fresh = !serviced_valid || (cpu_addr != serviced_addr);

    // Data BRAM, addressed {set,way}.  Write port: block fill on mem_ready.
    // Read port: registered (1-cycle latency), write-first forwarded.
    wire [DADDR_BITS-1:0] data_rd_addr = {req_index, hit_way[WAY_BITS-1:0]};
    wire [DADDR_BITS-1:0] fill_addr    = {pending_index, victim_way_r[WAY_BITS-1:0]};
    wire                  fill_we      = (state == ST_WAIT) && mem_ready;
    // Plain read-first synchronous RAM (no output bypass) so Vivado infers
    // true block RAM.  A line is only read >=1 cycle after it is filled, so
    // no same-cycle read/write bypass is needed for correctness.
    reg  [BLOCK_BITS-1:0] data_q;
    always @(posedge clk) begin
        data_q <= data_mem[data_rd_addr];
        if (fill_we) data_mem[fill_addr] <= mem_rdata;
    end

    assign mem_req   = (state == ST_WAIT);
    assign mem_we    = 1'b0;
    assign mem_addr  = pending_block_addr;
    assign mem_wdata = {BLOCK_BITS{1'b0}};
    assign mem_be    = {BLOCK_BYTES{1'b0}};

    // The PC can change between issuing the BRAM read (ST_IDLE) and the
    // result cycle (ST_HIT/ST_FILL) — e.g. a branch redirect.  Only assert
    // ready when the current request still matches the issued address;
    // otherwise the FSM falls back to ST_IDLE and re-issues for the new PC.
    wire req_match = cpu_req && (req_tag == pending_tag)
                             && (req_index == pending_index)
                             && (word_idx == pending_word_idx);
    assign cpu_ready = ((state == ST_HIT) || (state == ST_FILL)) && req_match;
    assign cpu_rdata = (state == ST_HIT) ? data_q[pending_word_idx*32 +: 32]
                                         : fill_word_r;

    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            hits           <= 32'd0;
            misses         <= 32'd0;
            serviced_valid <= 1'b0;
            serviced_addr  <= 32'd0;
            for (si = 0; si < NUM_SETS; si = si + 1) begin
                plru[si] <= 3'b000;
                for (wj = 0; wj < WAYS; wj = wj + 1)
                    valid[si][wj] <= 1'b0;
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    if (cpu_req) begin
                        pending_tag        <= req_tag;
                        pending_index      <= req_index;
                        pending_word_idx   <= word_idx;
                        pending_block_addr <= {cpu_addr[31:OFFSET_BITS],
                                               {OFFSET_BITS{1'b0}}};
                        if (hit_any) begin
                            // BRAM read of {req_index,hit_way} issued this
                            // cycle; data_q valid next cycle in ST_HIT.
                            if (fresh) begin
                                hits <= hits + 32'd1;
                                plru[req_index] <= plru_update(plru[req_index],
                                                               hit_way);
                                serviced_valid  <= 1'b1;
                                serviced_addr   <= cpu_addr;
                            end
                            state <= ST_HIT;
                        end else if (fresh) begin
                            misses       <= misses + 32'd1;
                            victim_way_r <= plru_victim(plru[req_index]);
                            serviced_valid <= 1'b1;
                            serviced_addr  <= cpu_addr;
                            state        <= ST_WAIT;
                        end
                    end
                end

                ST_HIT: state <= ST_IDLE;

                ST_WAIT: begin
                    if (mem_ready) begin
                        valid[pending_index][victim_way_r] <= 1'b1;
                        tag  [pending_index][victim_way_r] <= pending_tag;
                        plru [pending_index] <=
                            plru_update(plru[pending_index], victim_way_r);
                        fill_word_r <= mem_rdata[pending_word_idx*32 +: 32];
                        state       <= ST_FILL;
                    end
                end

                ST_FILL: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
