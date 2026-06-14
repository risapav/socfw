/**
 * @file  axis_byte_register_slice.sv
 * @brief 1-beat AXI-Stream register slice (8-bit data + tlast).
 *
 * @details
 *   Breaks combinatorial path between upstream FIFO (fall-through) and
 *   downstream FIFO RAM input. Skratio WNS na loopback -> xfcp_axis_adapter ceste.
 *
 *   Ready-valid: s_tready = !valid_q || m_tready  (bubble-free backpressure)
 *
 * @param clk    System clock (posedge)
 * @param rst_n  Asynchronous active-low reset
 */

`ifndef AXIS_BYTE_REGISTER_SLICE_SV
`define AXIS_BYTE_REGISTER_SLICE_SV

`default_nettype none

module axis_byte_register_slice (
  input  wire logic       clk,
  input  wire logic       rst_n,

  input  wire logic [7:0] s_tdata,
  input  wire logic       s_tvalid,
  output      logic       s_tready,
  input  wire logic       s_tlast,

  output      logic [7:0] m_tdata,
  output      logic       m_tvalid,
  input  wire logic       m_tready,
  output      logic       m_tlast
);

  logic [7:0] data_q;
  logic       last_q;
  logic       valid_q;

  assign s_tready = !valid_q || m_tready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      data_q  <= '0;
      last_q  <= 1'b0;
    end else if (s_tready) begin
      valid_q <= s_tvalid;
      if (s_tvalid) begin
        data_q <= s_tdata;
        last_q <= s_tlast;
      end
    end
  end

  assign m_tdata  = data_q;
  assign m_tvalid = valid_q;
  assign m_tlast  = last_q;

endmodule

`endif // AXIS_BYTE_REGISTER_SLICE_SV
