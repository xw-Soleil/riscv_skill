`timescale 1ns/1ps

// Word-to-block "no-cache" adapter used by the baseline SoC.  Forwards
// every CPU request to the next-level memory port - each fetch / load /
// store therefore pays MEM_LATENCY cycles.  Used to compute the speedup
// of the cached configurations.
module bypass_port #(
    parameter integer BLOCK_BYTES = 32,
    parameter integer IS_DCACHE   = 0
) (
    input  wire                       clk,
    input  wire                       rst,

    // CPU port
    input  wire                       cpu_req,
    input  wire                       cpu_we,
    input  wire [3:0]                 cpu_be,
    input  wire [31:0]                cpu_addr,
    input  wire [31:0]                cpu_wdata,
    output wire [31:0]                cpu_rdata,
    output wire                       cpu_ready,

    // Memory port (block wide)
    output reg                        mem_req,
    output reg                        mem_we,
    output reg  [31:0]                mem_addr,
    output reg  [BLOCK_BYTES*8-1:0]   mem_wdata,
    output reg  [BLOCK_BYTES-1:0]     mem_be,
    input  wire [BLOCK_BYTES*8-1:0]   mem_rdata,
    input  wire                       mem_ready,

    output reg  [31:0]                accesses
);
    localparam integer OFFSET_BITS = $clog2(BLOCK_BYTES);
    localparam integer BLOCK_BITS  = BLOCK_BYTES * 8;

    localparam ST_IDLE = 2'd0;
    localparam ST_WAIT = 2'd1;
    reg [1:0] state;

    reg [31:0] saved_addr;
    reg [3:0]  saved_word_idx;
    reg [BLOCK_BITS-1:0] saved_rdata;

    wire [3:0] req_word_idx = cpu_addr[OFFSET_BITS-1:2];
    wire current_block_matches =
        ({cpu_addr[31:OFFSET_BITS], {OFFSET_BITS{1'b0}}} ==
         {saved_addr[31:OFFSET_BITS], {OFFSET_BITS{1'b0}}});
    assign cpu_ready = (state == ST_WAIT) && mem_ready && current_block_matches;

    function [BLOCK_BYTES-1:0] block_be_for_word;
        input [3:0] be;
        input [3:0] word;
        integer k;
        reg [BLOCK_BYTES-1:0] r;
        begin
            r = {BLOCK_BYTES{1'b0}};
            for (k = 0; k < 4; k = k + 1) begin
                if (be[k]) r[word*4 + k] = 1'b1;
            end
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

    assign cpu_rdata = mem_rdata[req_word_idx*32 +: 32];

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_IDLE;
            mem_req   <= 1'b0;
            mem_we    <= 1'b0;
            accesses  <= 32'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    mem_req <= 1'b0;
                    mem_we  <= 1'b0;
                    if (cpu_req) begin
                        mem_req   <= 1'b1;
                        mem_we    <= IS_DCACHE ? cpu_we : 1'b0;
                        mem_addr  <= {cpu_addr[31:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                        mem_wdata <= IS_DCACHE
                                       ? block_data_for_word(cpu_wdata, req_word_idx)
                                       : {BLOCK_BITS{1'b0}};
                        mem_be    <= IS_DCACHE
                                       ? block_be_for_word(cpu_be, req_word_idx)
                                       : {BLOCK_BYTES{1'b0}};
                        saved_addr     <= cpu_addr;
                        saved_word_idx <= req_word_idx;
                        accesses       <= accesses + 32'd1;
                        state          <= ST_WAIT;
                    end
                end
                ST_WAIT: begin
                    if (mem_ready) begin
                        mem_req <= 1'b0;
                        mem_we  <= 1'b0;
                        state   <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
