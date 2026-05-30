/**
 * @file gmii_rx_mac.sv
 * @brief GMII RX MAC: strips preamble/SFD and passes Ethernet payload to AXI-Stream.
 * @details Preamble detection starts on first 0x55 byte with DV asserted. SFD (0xD5)
 * is consumed in RX_SFD state and NOT forwarded downstream. First data byte is the
 * first byte of the Ethernet header (dst_mac[47:40]). tlast fires on the last cycle
 * where dv_q=1 and gmii_rx_dv_i has just deasserted. No AXI-Stream backpressure —
 * assumes downstream can always accept data at line rate.
 * @param EXPECT_PREAMBLE   1 = require preamble/SFD before data (default); 0 = raw data
 * @param ALLOW_NO_PREAMBLE Reserved for future use
 */

`ifndef GMII_RX_MAC_SV
`define GMII_RX_MAC_SV

`default_nettype none

module gmii_rx_mac #(
  parameter bit EXPECT_PREAMBLE    = 1'b1,
  parameter bit ALLOW_NO_PREAMBLE  = 1'b1
)(
  input  wire logic        clk_i,
  input  wire logic        rst_ni,
  input  wire logic [7:0]  gmii_rxd_i,
  input  wire logic        gmii_rx_dv_i,
  input  wire logic        gmii_rx_er_i,

  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  input  wire logic        m_axis_tready,
  output      logic        m_axis_tlast,
  output      logic        m_axis_tuser,
  output      logic        frame_done_o
);

  // RX_SFD: one-cycle sink for the 0xD5 SFD byte so it is never forwarded downstream.
  typedef enum logic [1:0] {
    RX_IDLE = 2'd0,
    RX_PRE  = 2'd1,
    RX_SFD  = 2'd2,
    RX_DATA = 2'd3
  } rx_state_e;

  rx_state_e state_q, state_d;

  logic [7:0] rxd_q;
  logic       dv_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= RX_IDLE;
      rxd_q   <= 8'h00;
      dv_q    <= 1'b0;
    end else begin
      state_q <= state_d;
      rxd_q   <= gmii_rxd_i;
      dv_q    <= gmii_rx_dv_i;
    end
  end

  always_comb begin
    state_d = state_q;
    case (state_q)
      RX_IDLE: begin
        if (gmii_rx_dv_i) begin
          if (EXPECT_PREAMBLE && gmii_rxd_i == 8'h55) state_d = RX_PRE;
          else if (!EXPECT_PREAMBLE)                  state_d = RX_DATA;
        end
      end

      RX_PRE: begin
        if      (!gmii_rx_dv_i)              state_d = RX_IDLE;
        else if (gmii_rxd_i == 8'hD5)        state_d = RX_SFD;
      end

      // One cycle to discard SFD; rxd_q holds 0xD5 here (not forwarded)
      RX_SFD: begin
        if (!gmii_rx_dv_i) state_d = RX_IDLE;
        else               state_d = RX_DATA;
      end

      RX_DATA: begin
        if (!gmii_rx_dv_i) state_d = RX_IDLE;
      end

      default: state_d = RX_IDLE;
    endcase
  end

  // Data is valid one cycle after state enters RX_DATA (dv_q tracks last dv).
  assign m_axis_tvalid = (state_q == RX_DATA) && dv_q;
  assign m_axis_tdata  = rxd_q;
  // tlast: last registered byte with dv_q=1 while current dv=0 (end of frame)
  assign m_axis_tlast  = (state_q == RX_DATA) && dv_q && !gmii_rx_dv_i;
  assign m_axis_tuser  = gmii_rx_er_i;
  assign frame_done_o  = m_axis_tlast;

endmodule

`endif // GMII_RX_MAC_SV
