`timescale 1ns/1ps

// Two-input fixed-priority memory arbiter.
//   Port A wins over port B when both raise a request in the same cycle.
//   Once a request is granted the arbiter latches the transaction and
//   drives the downstream port from registers until `m_ready` completes it.
//   The registered downstream side breaks long cache-to-cache timing paths.
module mem_arbiter #(
    parameter integer BLOCK_BYTES = 32
) (
    input  wire                       clk,
    input  wire                       rst,

    // Port A (data cache - higher priority)
    input  wire                       a_req,
    input  wire                       a_we,
    input  wire [31:0]                a_addr,
    input  wire [BLOCK_BYTES*8-1:0]   a_wdata,
    input  wire [BLOCK_BYTES-1:0]     a_be,
    output wire [BLOCK_BYTES*8-1:0]   a_rdata,
    output wire                       a_ready,

    // Port B (instruction cache - lower priority)
    input  wire                       b_req,
    input  wire                       b_we,
    input  wire [31:0]                b_addr,
    input  wire [BLOCK_BYTES*8-1:0]   b_wdata,
    input  wire [BLOCK_BYTES-1:0]     b_be,
    output wire [BLOCK_BYTES*8-1:0]   b_rdata,
    output wire                       b_ready,

    // Downstream (next-level memory)
    output reg                        m_req,
    output reg                        m_we,
    output reg  [31:0]                m_addr,
    output reg  [BLOCK_BYTES*8-1:0]   m_wdata,
    output reg  [BLOCK_BYTES-1:0]     m_be,
    input  wire [BLOCK_BYTES*8-1:0]   m_rdata,
    input  wire                       m_ready
);
    localparam G_NONE = 2'd0;
    localparam G_A    = 2'd1;
    localparam G_B    = 2'd2;

    reg [1:0] grant;

    assign a_rdata = m_rdata;
    assign b_rdata = m_rdata;
    assign a_ready = (grant == G_A) && m_req && m_ready;
    assign b_ready = (grant == G_B) && m_req && m_ready;

    always @(posedge clk) begin
        if (rst) begin
            grant   <= G_NONE;
            m_req   <= 1'b0;
            m_we    <= 1'b0;
            m_addr  <= 32'd0;
            m_wdata <= {BLOCK_BYTES*8{1'b0}};
            m_be    <= {BLOCK_BYTES{1'b0}};
        end else begin
            case (grant)
                G_NONE: begin
                    m_req <= 1'b0;
                    if (a_req) begin
                        grant <= G_A;
                    end else if (b_req) begin
                        grant <= G_B;
                    end
                end
                default: begin
                    if (!m_req) begin
                        m_req <= 1'b1;
                        if (grant == G_A) begin
                            m_we    <= a_we;
                            m_addr  <= a_addr;
                            m_wdata <= a_wdata;
                            m_be    <= a_be;
                        end else begin
                            m_we    <= b_we;
                            m_addr  <= b_addr;
                            m_wdata <= b_wdata;
                            m_be    <= b_be;
                        end
                    end else if (m_ready) begin
                        grant <= G_NONE;
                        m_req <= 1'b0;
                    end
                end
            endcase
        end
    end
endmodule
