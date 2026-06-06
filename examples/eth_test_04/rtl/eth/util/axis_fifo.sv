/**
 * @file axis_fifo.sv
 * @brief Synchronous AXI-Stream FIFO with power-of-two depth.
 * @param DATA_WIDTH Datapath width.
 * @param DEPTH_LOG2 Log2 of entry count; depth = 2**DEPTH_LOG2.
 * @details Extra-MSB pointer scheme: full when pointers differ only in MSB,
 *   empty when pointers are equal. Single-clock only -- not CDC-safe.
 *   For cross-domain use, replace with async_fifo (Gray-code CDC).
 *   Flat ENTRY_W array + separate no-reset always_ff block for M9K inference.
 *   Asynchronous read (unregistered M9K output port).
 */
`ifndef AXIS_FIFO_SV
`define AXIS_FIFO_SV

`default_nettype none

module axis_fifo #(
  parameter int DATA_WIDTH = 8,
  parameter int DEPTH_LOG2 = 4
) (
  input  wire logic                  clk_i,
  input  wire logic                  rst_ni,
  input  wire logic [DATA_WIDTH-1:0] s_axis_tdata,
  input  wire logic                  s_axis_tvalid,
  input  wire logic                  s_axis_tlast,
  input  wire logic                  s_axis_tuser,
  output      logic                  s_axis_tready,
  output      logic [DATA_WIDTH-1:0] m_axis_tdata,
  output      logic                  m_axis_tvalid,
  output      logic                  m_axis_tlast,
  output      logic                  m_axis_tuser,
  input  wire logic                  m_axis_tready
);

  localparam int DEPTH   = 1 << DEPTH_LOG2;
  localparam int ENTRY_W = DATA_WIDTH + 2;  // tdata + tlast + tuser

  // Flat array: inferred as M9K block RAM (no reset block, separate write always_ff)
  logic [ENTRY_W-1:0]  mem [DEPTH-1:0];
  logic [DEPTH_LOG2:0] wr_ptr_q;
  logic [DEPTH_LOG2:0] rd_ptr_q;

  logic full_w;
  logic empty_w;
  logic wr_en_w;
  logic rd_en_w;

  assign full_w  = (wr_ptr_q[DEPTH_LOG2]   != rd_ptr_q[DEPTH_LOG2]) &&
                   (wr_ptr_q[DEPTH_LOG2-1:0] == rd_ptr_q[DEPTH_LOG2-1:0]);
  assign empty_w = (wr_ptr_q == rd_ptr_q);

  assign wr_en_w = s_axis_tvalid && !full_w;
  assign rd_en_w = !empty_w && m_axis_tready;

  assign s_axis_tready = !full_w;
  assign m_axis_tvalid = !empty_w;

  // Asynchronous read (unregistered output -- M9K "read during write" = old data)
  assign m_axis_tdata  = mem[rd_ptr_q[DEPTH_LOG2-1:0]][DATA_WIDTH-1:0];
  assign m_axis_tlast  = mem[rd_ptr_q[DEPTH_LOG2-1:0]][DATA_WIDTH];
  assign m_axis_tuser  = mem[rd_ptr_q[DEPTH_LOG2-1:0]][DATA_WIDTH+1];

  // Memory write: no reset to allow M9K block RAM inference
  always_ff @(posedge clk_i) begin
    if (wr_en_w) begin
      mem[wr_ptr_q[DEPTH_LOG2-1:0]] <= {s_axis_tuser, s_axis_tlast, s_axis_tdata};
    end
  end

  // Pointer control with async reset
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
    end else begin
      if (wr_en_w) wr_ptr_q <= wr_ptr_q + 1'b1;
      if (rd_en_w) rd_ptr_q <= rd_ptr_q + 1'b1;
    end
  end

endmodule

`endif // AXIS_FIFO_SV
