`default_nettype none

import video_pkg::*;

// Synchronous stream FIFO with SOF/EOL/EOF metadata.
// Push and pop can happen simultaneously when FIFO is full (bypass count).
module video_stream_fifo_sync #(
  parameter int DEPTH = 16
)(
  input  logic clk_i,
  input  logic rst_ni,

  // Upstream (write) port
  input  rgb565_t s_axis_data_i,
  input  logic    s_axis_valid_i,
  output logic    s_axis_ready_o,
  input  logic    s_axis_sof_i,
  input  logic    s_axis_eol_i,
  input  logic    s_axis_eof_i,

  // Downstream (read) port
  output rgb565_t m_axis_data_o,
  output logic    m_axis_valid_o,
  input  logic    m_axis_ready_i,
  output logic    m_axis_sof_o,
  output logic    m_axis_eol_o,
  output logic    m_axis_eof_o,

  output logic [$clog2(DEPTH+1)-1:0] fill_o
);

  localparam int AW = $clog2(DEPTH);

  rgb565_t data_mem [0:DEPTH-1];
  logic    sof_mem  [0:DEPTH-1];
  logic    eol_mem  [0:DEPTH-1];
  logic    eof_mem  [0:DEPTH-1];

  logic [AW-1:0] wr_ptr;
  logic [AW-1:0] rd_ptr;
  logic [$clog2(DEPTH+1)-1:0] count;

  // Correct wrap for arbitrary (non-power-of-two) DEPTH
  function automatic logic [AW-1:0] ptr_next(input logic [AW-1:0] ptr);
    return (ptr == AW'(DEPTH - 1)) ? '0 : ptr + 1'b1;
  endfunction

  wire push = s_axis_valid_i && s_axis_ready_o;
  wire pop  = m_axis_valid_o  && m_axis_ready_i;

  // Allow push when there is space OR when simultaneously popping (no net increase)
  assign s_axis_ready_o = (count < DEPTH) || pop;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (push) begin
        data_mem[wr_ptr] <= s_axis_data_i;
        sof_mem [wr_ptr] <= s_axis_sof_i;
        eol_mem [wr_ptr] <= s_axis_eol_i;
        eof_mem [wr_ptr] <= s_axis_eof_i;
        wr_ptr <= ptr_next(wr_ptr);
      end
      if (pop)
        rd_ptr <= ptr_next(rd_ptr);

      unique case ({push, pop})
        2'b10:   count <= count + 1;
        2'b01:   count <= count - 1;
        default: count <= count;
      endcase
    end
  end

  assign m_axis_valid_o = (count > 0);
  assign m_axis_data_o  = data_mem[rd_ptr];
  assign m_axis_sof_o   = sof_mem[rd_ptr];
  assign m_axis_eol_o   = eol_mem[rd_ptr];
  assign m_axis_eof_o   = eof_mem[rd_ptr];
  assign fill_o         = count;

endmodule
