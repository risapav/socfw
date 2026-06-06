/**
 * @file eth_echo_app.sv
 * @brief Ethernet echo application: swaps MACs and forwards clean frames to TX MAC.
 * @param LOCAL_MAC  48-bit source MAC used in echoed frames.
 * @details Consumes metadata + payload from two async FIFOs (CDC from eth_rx_clk domain).
 *   Frames with fcs_ok=0 are discarded (payload drained silently). Good frames:
 *   tx_dst = rx_src, tx_src = LOCAL_MAC, eth_type preserved, payload forwarded verbatim.
 *   Runs entirely in clk_i (eth_tx_clk) domain.
 *
 *   Meta is emitted by eth_rx_mac at frame end (cut-through: all payload bytes are
 *   already in the payload FIFO when meta_valid asserts, so no ordering hazard).
 *
 *   FSM: ST_IDLE -> ST_TX_META -> ST_FORWARD (good) / ST_DISCARD (bad FCS).
 */
`ifndef ETH_ECHO_APP_SV
`define ETH_ECHO_APP_SV

`default_nettype none

module eth_echo_app #(
  parameter logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // Metadata from RX domain (via meta async FIFO, CDC)
  input  wire logic        s_meta_valid_i,
  output      logic        s_meta_ready_o,
  input  wire logic        s_meta_fcs_ok_i,
  input  wire logic [47:0] s_meta_dst_mac_i,
  input  wire logic [47:0] s_meta_src_mac_i,
  input  wire logic [15:0] s_meta_eth_type_i,

  // Payload AXI-Stream from RX domain (via payload async FIFO, CDC)
  input  wire logic [7:0]  s_axis_tdata_i,
  input  wire logic        s_axis_tvalid_i,
  output      logic        s_axis_tready_o,
  input  wire logic        s_axis_tlast_i,
  input  wire logic        s_axis_tuser_i,

  // Metadata to eth_tx_mac
  output      logic        m_meta_valid_o,
  input  wire logic        m_meta_ready_i,
  output      logic [47:0] m_meta_dst_mac_o,
  output      logic [47:0] m_meta_src_mac_o,
  output      logic [15:0] m_meta_eth_type_o,

  // Payload AXI-Stream to eth_tx_mac
  output      logic [7:0]  m_axis_tdata_o,
  output      logic        m_axis_tvalid_o,
  input  wire logic        m_axis_tready_i,
  output      logic        m_axis_tlast_o,
  output      logic        m_axis_tuser_o,

  // Statistics (in clk_i domain)
  output      logic [15:0] stat_echo_frames,
  output      logic [15:0] stat_discard_frames
);

  typedef enum logic [1:0] {
    ST_IDLE    = 2'd0,
    ST_TX_META = 2'd1,
    ST_FORWARD = 2'd2,
    ST_DISCARD = 2'd3
  } state_e;

  state_e      state_q;
  logic [47:0] latch_src_mac_q;
  logic [15:0] latch_eth_type_q;
  logic [15:0] echo_cnt_q;
  logic [15:0] discard_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= ST_IDLE;
      latch_src_mac_q  <= '0;
      latch_eth_type_q <= '0;
      echo_cnt_q       <= '0;
      discard_cnt_q    <= '0;
    end else begin
      case (state_q)

        ST_IDLE: begin
          if (s_meta_valid_i) begin
            latch_src_mac_q  <= s_meta_src_mac_i;
            latch_eth_type_q <= s_meta_eth_type_i;
            if (s_meta_fcs_ok_i) begin
              state_q <= ST_TX_META;
            end else begin
              state_q <= ST_DISCARD;
            end
          end
        end

        ST_TX_META: begin
          if (m_meta_ready_i) begin
            state_q <= ST_FORWARD;
          end
        end

        ST_FORWARD: begin
          if (s_axis_tvalid_i && m_axis_tready_i && s_axis_tlast_i) begin
            echo_cnt_q <= echo_cnt_q + 16'd1;
            state_q    <= ST_IDLE;
          end
        end

        ST_DISCARD: begin
          if (s_axis_tvalid_i && s_axis_tlast_i) begin
            discard_cnt_q <= discard_cnt_q + 16'd1;
            state_q       <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Combinatorial outputs
  // -------------------------------------------------------------------------
  assign s_meta_ready_o = (state_q == ST_IDLE);

  assign m_meta_valid_o    = (state_q == ST_TX_META);
  assign m_meta_dst_mac_o  = latch_src_mac_q;
  assign m_meta_src_mac_o  = LOCAL_MAC;
  assign m_meta_eth_type_o = latch_eth_type_q;

  assign m_axis_tdata_o  = s_axis_tdata_i;
  assign m_axis_tvalid_o = s_axis_tvalid_i && (state_q == ST_FORWARD);
  assign m_axis_tlast_o  = s_axis_tlast_i;
  assign m_axis_tuser_o  = s_axis_tuser_i;

  assign s_axis_tready_o = (state_q == ST_FORWARD) ? m_axis_tready_i :
                           (state_q == ST_DISCARD);

  assign stat_echo_frames    = echo_cnt_q;
  assign stat_discard_frames = discard_cnt_q;

endmodule

`endif // ETH_ECHO_APP_SV
