`timescale 1ns/1ps

// Parameterised set-associative L1 data cache.
//   Write-through, write-allocate, 1-entry write-through buffer.
//   Tree pseudo-LRU replacement.
//
// Microarchitecture: combinational tags + block-RAM data (same scheme as
// the I-cache and L2).  Hit detection is combinational; the data line is
// read from / written to a synchronous block RAM, so a hit is serviced
// with one cycle of access latency.  A store hit is a read-modify-write:
// the line is read (1 cycle), the byte-enabled store merged in, the whole
// line written back, and the write-through posted to a 1-entry buffer.
module l1_dcache #(
    parameter integer SIZE_BYTES  = 8192,
    parameter integer BLOCK_BYTES = 32,
    parameter integer WAYS        = 2
) (
    input  wire                       clk,
    input  wire                       rst,

    input  wire                       cpu_req,
    input  wire                       cpu_we,
    input  wire [3:0]                 cpu_be,
    input  wire [31:0]                cpu_addr,
    input  wire [31:0]                cpu_wdata,
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
    output reg  [31:0]                misses,
    output reg  [31:0]                writes_through
);
    localparam integer NUM_BLOCKS  = SIZE_BYTES / BLOCK_BYTES;
    localparam integer NUM_SETS    = NUM_BLOCKS / WAYS;
    localparam integer OFFSET_BITS = $clog2(BLOCK_BYTES);
    localparam integer INDEX_BITS  = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1;
    localparam integer TAG_BITS    = 32 - OFFSET_BITS - INDEX_BITS;
    localparam integer BLOCK_BITS  = BLOCK_BYTES * 8;
    localparam integer WAY_BITS    = (WAYS <= 1) ? 1 : $clog2(WAYS);
    localparam integer DADDR_BITS  = INDEX_BITS + WAY_BITS;

    reg                  valid [0:NUM_SETS-1][0:WAYS-1];
    reg [TAG_BITS-1:0]   tag   [0:NUM_SETS-1][0:WAYS-1];
    reg [2:0]            plru  [0:NUM_SETS-1];
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

    // Merge a byte-enabled 32-bit store into word `word` of a line.
    function [BLOCK_BITS-1:0] merge_word;
        input [BLOCK_BITS-1:0] line;
        input [3:0]            word;
        input [31:0]           wd;
        input [3:0]            be;
        integer k;
        reg [BLOCK_BITS-1:0] r;
        begin
            r = line;
            for (k = 0; k < 4; k = k + 1)
                if (be[k]) r[word*32 + k*8 +: 8] = wd[k*8 +: 8];
            merge_word = r;
        end
    endfunction

    function [BLOCK_BYTES-1:0] block_be_for_word;
        input [3:0] be;
        input [3:0] word;
        integer k;
        reg [BLOCK_BYTES-1:0] r;
        begin
            r = {BLOCK_BYTES{1'b0}};
            for (k = 0; k < 4; k = k + 1) if (be[k]) r[word*4 + k] = 1'b1;
            block_be_for_word = r;
        end
    endfunction

    function [BLOCK_BITS-1:0] block_data_for_word;
        input [31:0] wd;
        input [3:0]  word;
        reg [BLOCK_BITS-1:0] r;
        begin
            r = {BLOCK_BITS{1'b0}};
            r[word*32 +: 32] = wd;
            block_data_for_word = r;
        end
    endfunction

    // Write-through buffer (1 entry).
    reg                  wb_valid;
    reg [31:0]           wb_addr;
    reg [31:0]           wb_wdata;
    reg [3:0]            wb_be;

    // FSM.
    localparam ST_IDLE    = 3'd0;
    localparam ST_HIT_RD  = 3'd1;  // read hit: data_q valid, return word
    localparam ST_HIT_WR  = 3'd2;  // write hit: merge + write back + post wb
    localparam ST_WAIT    = 3'd3;  // miss: block fetch outstanding
    localparam ST_FILL    = 3'd4;  // miss: present fetched word / post alloc wb
    localparam ST_DRAIN   = 3'd5;  // write-through buffer draining
    reg [2:0] state;

    reg [TAG_BITS-1:0]   pending_tag;
    reg [INDEX_BITS-1:0] pending_index;
    reg [3:0]            pending_word_idx;
    reg [31:0]           pending_block_addr;
    reg                  pending_we;
    reg [3:0]            pending_be;
    reg [31:0]           pending_wdata;
    reg [1:0]            active_way_r;   // hit way (for write-back)
    reg [1:0]            victim_way_r;   // fill way
    reg [31:0]           rdata_r;

    // Block written into the way on a (write-allocate) fill.
    wire [BLOCK_BITS-1:0] alloc_block =
        pending_we ? merge_word(mem_rdata, pending_word_idx, pending_wdata, pending_be)
                   : mem_rdata;

    // Data BRAM, addressed {set,way}.  Two write cases (continuous-assign
    // conditions, not a separate combinational reg block):
    //   * write hit (ST_HIT_WR): merge store into the just-read line.
    //   * fill (ST_WAIT & mem_ready): write the fetched/allocated line.
    // Read port: registered (1-cycle latency), write-first forwarded.
    reg  [BLOCK_BITS-1:0] data_q;
    wire [DADDR_BITS-1:0] data_rd_addr = {req_index, hit_way[WAY_BITS-1:0]};
    wire                  hit_wr_we    = (state == ST_HIT_WR);
    wire                  fill_we      = (state == ST_WAIT) && mem_ready;
    wire                  data_we      = hit_wr_we || fill_we;
    wire [DADDR_BITS-1:0] data_wr_addr = hit_wr_we
        ? {pending_index, active_way_r[WAY_BITS-1:0]}
        : {pending_index, victim_way_r[WAY_BITS-1:0]};
    wire [BLOCK_BITS-1:0] data_wr_block = hit_wr_we
        ? merge_word(data_q, pending_word_idx, pending_wdata, pending_be)
        : alloc_block;
    // Plain read-first synchronous RAM (no output bypass) so Vivado infers
    // true block RAM.  data_q is consumed the cycle after it is issued, and
    // a line is only re-read >=1 cycle after a write, so no same-cycle
    // read/write bypass is needed for correctness.
    always @(posedge clk) begin
        data_q <= data_mem[data_rd_addr];
        if (data_we) data_mem[data_wr_addr] <= data_wr_block;
    end

    wire fill_active  = (state == ST_WAIT);
    wire drain_active = (state == ST_DRAIN);
    assign mem_req   = fill_active || drain_active;
    assign mem_we    = drain_active;
    assign mem_addr  = drain_active
                     ? {wb_addr[31:OFFSET_BITS], {OFFSET_BITS{1'b0}}}
                     : pending_block_addr;
    assign mem_wdata = block_data_for_word(wb_wdata, wb_addr[OFFSET_BITS-1:2]);
    assign mem_be    = block_be_for_word(wb_be, wb_addr[OFFSET_BITS-1:2]);

    assign cpu_ready = (state == ST_HIT_RD) || (state == ST_HIT_WR)
                     || (state == ST_FILL);
    assign cpu_rdata = (state == ST_HIT_RD) ? data_q[pending_word_idx*32 +: 32]
                                            : rdata_r;

    integer b;
    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            wb_valid       <= 1'b0;
            hits           <= 32'd0;
            misses         <= 32'd0;
            writes_through <= 32'd0;
            for (si = 0; si < NUM_SETS; si = si + 1) begin
                plru[si] <= 3'b000;
                for (wj = 0; wj < WAYS; wj = wj + 1)
                    valid[si][wj] <= 1'b0;
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    pending_tag        <= req_tag;
                    pending_index      <= req_index;
                    pending_word_idx   <= word_idx;
                    pending_block_addr <= {cpu_addr[31:OFFSET_BITS],
                                           {OFFSET_BITS{1'b0}}};
                    pending_we         <= cpu_we;
                    pending_be         <= cpu_be;
                    pending_wdata      <= cpu_wdata;
                    active_way_r       <= hit_way;
                    if (cpu_req && hit_any && !cpu_we) begin
                        // read hit: BRAM read issued this cycle
                        hits <= hits + 32'd1;
                        plru[req_index] <= plru_update(plru[req_index], hit_way);
                        state <= ST_HIT_RD;
                    end else if (cpu_req && hit_any && cpu_we && !wb_valid) begin
                        // write hit: read line now, merge+writeback next cycle
                        hits <= hits + 32'd1;
                        plru[req_index] <= plru_update(plru[req_index], hit_way);
                        state <= ST_HIT_WR;
                    end else if (wb_valid) begin
                        // buffer busy and pending op needs it (store / miss) or
                        // CPU idle: drain first.
                        state <= ST_DRAIN;
                    end else if (cpu_req && !hit_any) begin
                        misses       <= misses + 32'd1;
                        victim_way_r <= plru_victim(plru[req_index]);
                        state        <= ST_WAIT;
                    end
                end

                ST_HIT_RD: state <= ST_IDLE;

                ST_HIT_WR: begin
                    // data_mem written via the combinational data_we path.
                    wb_valid <= 1'b1;
                    wb_addr  <= pending_block_addr
                              | {{(32-OFFSET_BITS){1'b0}}, pending_word_idx, 2'b00};
                    wb_wdata <= pending_wdata;
                    wb_be    <= pending_be;
                    writes_through <= writes_through + 32'd1;
                    state    <= ST_IDLE;
                end

                ST_WAIT: begin
                    if (mem_ready) begin
                        valid[pending_index][victim_way_r] <= 1'b1;
                        tag  [pending_index][victim_way_r] <= pending_tag;
                        plru [pending_index] <=
                            plru_update(plru[pending_index], victim_way_r);
                        // data_mem[victim] written via combinational data_we.
                        rdata_r <= alloc_block[pending_word_idx*32 +: 32];
                        if (pending_we) begin
                            wb_valid <= 1'b1;
                            wb_addr  <= pending_block_addr
                                      | {{(32-OFFSET_BITS){1'b0}},
                                         pending_word_idx, 2'b00};
                            wb_wdata <= pending_wdata;
                            wb_be    <= pending_be;
                            writes_through <= writes_through + 32'd1;
                        end
                        state <= ST_FILL;
                    end
                end

                ST_FILL: state <= ST_IDLE;

                ST_DRAIN: begin
                    if (mem_ready) begin
                        wb_valid <= 1'b0;
                        state    <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // ----- Simulation-only inspection used by the testbench result check -----
    // synthesis translate_off
    function peek_hit;
        input [31:0] a;
        reg [TAG_BITS-1:0]   f_tag;
        reg [INDEX_BITS-1:0] f_index;
        integer pw;
        begin
            f_tag   = a[31 -: TAG_BITS];
            f_index = (NUM_SETS > 1) ? a[OFFSET_BITS +: INDEX_BITS] : 1'b0;
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
        reg [3:0]            f_word;
        integer pw;
        begin
            f_tag   = a[31 -: TAG_BITS];
            f_index = (NUM_SETS > 1) ? a[OFFSET_BITS +: INDEX_BITS] : 1'b0;
            f_word  = a[OFFSET_BITS-1:2];
            peek_word = 32'hxxxx_xxxx;
            for (pw = 0; pw < WAYS; pw = pw + 1)
                if (valid[f_index][pw] && tag[f_index][pw] == f_tag)
                    peek_word = data_mem[{f_index, pw[WAY_BITS-1:0]}][f_word*32 +: 32];
        end
    endfunction
    // synthesis translate_on
endmodule
