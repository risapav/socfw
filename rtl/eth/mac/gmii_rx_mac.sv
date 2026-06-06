/**
 * @file gmii_rx_mac.sv
 * @brief GMII RX to AXI-Stream converter with IEEE 802.3 statistics.
 * @param DATA_WIDTH Datapath width (default 8 for GMII byte-mode).
 * @details 1-cycle input pipeline: rxd/rxdv/rxer are registered, then forwarded.
 *   m_axis_tlast fires on the cycle where rx_dv_q=1 && !gmii_rx_dv_i (DV falling),
 *   concurrent with the last valid byte on m_axis_tdata.
 *   Statistics tracked on raw GMII input (not delayed AXI-S output).
 *   Frame format received from RTL8211EG PHY (RXDV asserted from SFD onward):
 *     byte 0: SFD (0xD5), bytes 1-6: DST_MAC, bytes 7-12: SRC_MAC,
 *     bytes 13-14: EtherType, bytes 15+: payload, last 4: FCS.
 *   stat_rx_err_bad_fcs: stub 0 -- requires CRC32 integration (future work).
 */
`ifndef GMII_RX_MAC_SV
`define GMII_RX_MAC_SV

`default_nettype none

module gmii_rx_mac #(
  parameter int DATA_WIDTH = 8
) (
  input  wire logic                  clk_i,
  input  wire logic                  rst_ni,

  // GMII inputs
  input  wire logic                  gmii_rx_dv_i,
  input  wire logic                  gmii_rx_er_i,
  input  wire logic [DATA_WIDTH-1:0] gmii_rxd_i,

  // AXI-Stream output
  output      logic [DATA_WIDTH-1:0] m_axis_tdata,
  output      logic                  m_axis_tvalid,
  output      logic                  m_axis_tlast,
  output      logic                  m_axis_tuser,

  // Configuration
  input  wire logic [15:0]           cfg_rx_max_pkt_len,
  input  wire logic                  cfg_rx_enable,

  // Aggregated status
  output      logic [31:0]           status_o,

  // Per-event pulses (1-cycle, fired synchronous to clk_i)
  output      logic                  rx_start_packet,
  output      logic                  stat_rx_byte,
  output      logic [15:0]           stat_rx_pkt_len,
  output      logic                  stat_rx_pkt_fragment,
  output      logic                  stat_rx_pkt_jabber,
  output      logic                  stat_rx_pkt_ucast,
  output      logic                  stat_rx_pkt_mcast,
  output      logic                  stat_rx_pkt_bcast,
  output      logic                  stat_rx_pkt_vlan,
  output      logic                  stat_rx_pkt_good,
  output      logic                  stat_rx_pkt_bad,
  output      logic                  stat_rx_err_oversize,
  output      logic                  stat_rx_err_bad_fcs,
  output      logic                  stat_rx_err_bad_block,
  output      logic                  stat_rx_err_framing,
  output      logic                  stat_rx_err_preamble
);

  // --- AXI-S pipeline registers ---
  logic [DATA_WIDTH-1:0] rxd_q;
  logic                  rx_dv_q;
  logic                  rx_er_q;

  // --- Frame tracking ---
  logic [15:0] byte_cnt_q;     // current byte position in frame (set at frame start)
  logic [15:0] frame_cnt_q;
  logic [15:0] error_cnt_q;

  // --- Per-frame accumulators (reset at frame start) ---
  logic        pkt_bcast_q;         // all 6 DST bytes seen as 0xFF
  logic        pkt_mcast_q;         // DST_MAC[0] bit 0 = 1
  logic        pkt_vlan_q;          // EtherType = 0x8100
  logic [7:0]  ethertype_msb_q;     // capture EtherType MSB before LSB arrives
  logic        pkt_err_preamble_q;  // SFD != 0xD5
  logic        pkt_err_block_q;     // RXER seen during frame
  logic        pkt_oversize_q;      // byte_cnt > cfg_rx_max_pkt_len

  // --------------------------------------------------------------------------
  // AXI-S output pipeline + statistics
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rxd_q               <= '0;
      rx_dv_q             <= 1'b0;
      rx_er_q             <= 1'b0;
      m_axis_tdata        <= '0;
      m_axis_tvalid       <= 1'b0;
      m_axis_tlast        <= 1'b0;
      m_axis_tuser        <= 1'b0;
      byte_cnt_q          <= '0;
      frame_cnt_q         <= '0;
      error_cnt_q         <= '0;
      pkt_bcast_q         <= 1'b0;
      pkt_mcast_q         <= 1'b0;
      pkt_vlan_q          <= 1'b0;
      ethertype_msb_q     <= 8'h00;
      pkt_err_preamble_q  <= 1'b0;
      pkt_err_block_q     <= 1'b0;
      pkt_oversize_q      <= 1'b0;
      stat_rx_pkt_len     <= '0;
      rx_start_packet     <= 1'b0;
      stat_rx_byte        <= 1'b0;
      stat_rx_pkt_fragment  <= 1'b0;
      stat_rx_pkt_jabber    <= 1'b0;
      stat_rx_pkt_ucast     <= 1'b0;
      stat_rx_pkt_mcast     <= 1'b0;
      stat_rx_pkt_bcast     <= 1'b0;
      stat_rx_pkt_vlan      <= 1'b0;
      stat_rx_pkt_good      <= 1'b0;
      stat_rx_pkt_bad       <= 1'b0;
      stat_rx_err_oversize  <= 1'b0;
      stat_rx_err_bad_fcs   <= 1'b0;
      stat_rx_err_bad_block <= 1'b0;
      stat_rx_err_framing   <= 1'b0;
      stat_rx_err_preamble  <= 1'b0;
    end else begin
      // --- AXI-S pipeline (1-cycle delay) ---
      rxd_q   <= gmii_rxd_i;
      rx_dv_q <= gmii_rx_dv_i;
      rx_er_q <= gmii_rx_er_i;

      m_axis_tdata  <= rxd_q;
      m_axis_tvalid <= rx_dv_q && cfg_rx_enable;
      m_axis_tuser  <= rx_er_q;
      m_axis_tlast  <= rx_dv_q && !gmii_rx_dv_i;

      // --- Pulse defaults: clear every cycle ---
      rx_start_packet       <= 1'b0;
      stat_rx_byte          <= 1'b0;
      stat_rx_pkt_fragment  <= 1'b0;
      stat_rx_pkt_jabber    <= 1'b0;
      stat_rx_pkt_ucast     <= 1'b0;
      stat_rx_pkt_mcast     <= 1'b0;
      stat_rx_pkt_bcast     <= 1'b0;
      stat_rx_pkt_vlan      <= 1'b0;
      stat_rx_pkt_good      <= 1'b0;
      stat_rx_pkt_bad       <= 1'b0;
      stat_rx_err_oversize  <= 1'b0;
      stat_rx_err_bad_fcs   <= 1'b0;
      stat_rx_err_bad_block <= 1'b0;
      stat_rx_err_framing   <= 1'b0;
      stat_rx_err_preamble  <= 1'b0;

      // --- Frame START: first byte = SFD ---
      if (!rx_dv_q && gmii_rx_dv_i) begin
        rx_start_packet    <= 1'b1;
        stat_rx_byte       <= 1'b1;
        byte_cnt_q         <= 16'd1;  // next byte will be at position 1
        pkt_err_preamble_q <= (gmii_rxd_i != 8'hD5);
        pkt_bcast_q        <= 1'b1;   // assume bcast; cleared if any DST byte != FF
        pkt_mcast_q        <= 1'b0;
        pkt_vlan_q         <= 1'b0;
        pkt_oversize_q     <= 1'b0;
        ethertype_msb_q    <= 8'h00;
        pkt_err_block_q    <= gmii_rx_er_i;

      // --- Frame BODY: subsequent bytes ---
      end else if (gmii_rx_dv_i && rx_dv_q) begin
        stat_rx_byte <= 1'b1;
        byte_cnt_q   <= byte_cnt_q + 16'd1;

        if (gmii_rx_er_i) pkt_err_block_q <= 1'b1;

        if (byte_cnt_q > cfg_rx_max_pkt_len) pkt_oversize_q <= 1'b1;

        // Capture DST_MAC bytes and EtherType (byte_cnt_q = current position)
        case (byte_cnt_q)
          16'd1: begin  // DST_MAC[0]
            pkt_mcast_q <= gmii_rxd_i[0];
            pkt_bcast_q <= (gmii_rxd_i == 8'hFF);
          end
          16'd2: pkt_bcast_q <= pkt_bcast_q && (gmii_rxd_i == 8'hFF);
          16'd3: pkt_bcast_q <= pkt_bcast_q && (gmii_rxd_i == 8'hFF);
          16'd4: pkt_bcast_q <= pkt_bcast_q && (gmii_rxd_i == 8'hFF);
          16'd5: pkt_bcast_q <= pkt_bcast_q && (gmii_rxd_i == 8'hFF);
          16'd6: pkt_bcast_q <= pkt_bcast_q && (gmii_rxd_i == 8'hFF);
          16'd13: ethertype_msb_q <= gmii_rxd_i;
          16'd14: pkt_vlan_q <= (ethertype_msb_q == 8'h81) && (gmii_rxd_i == 8'h00);
          default: ;
        endcase

      // --- Frame END: RXDV falling ---
      end else if (rx_dv_q && !gmii_rx_dv_i) begin
        stat_rx_pkt_len      <= byte_cnt_q;
        stat_rx_pkt_ucast    <= !pkt_mcast_q && !pkt_bcast_q;
        stat_rx_pkt_mcast    <= pkt_mcast_q && !pkt_bcast_q;
        stat_rx_pkt_bcast    <= pkt_bcast_q;
        stat_rx_pkt_vlan     <= pkt_vlan_q;
        stat_rx_err_preamble <= pkt_err_preamble_q;
        stat_rx_err_bad_block <= pkt_err_block_q;
        stat_rx_err_bad_fcs  <= 1'b0;  // requires CRC32 -- not yet implemented
        // framing: RXER asserted as RXDV falls (PHY error indication)
        stat_rx_err_framing  <= gmii_rx_er_i;
        stat_rx_err_oversize <= pkt_oversize_q;
        // fragment: < 65 bytes (SFD + min 64-byte Ethernet frame)
        stat_rx_pkt_fragment <= (byte_cnt_q < 16'd65) && !pkt_oversize_q;
        stat_rx_pkt_jabber   <= pkt_oversize_q;

        // good: correct size + no errors
        stat_rx_pkt_good <=  (byte_cnt_q >= 16'd65) && !pkt_oversize_q &&
                             !pkt_err_preamble_q && !pkt_err_block_q && !gmii_rx_er_i;
        stat_rx_pkt_bad  <= !(byte_cnt_q >= 16'd65) || pkt_oversize_q ||
                              pkt_err_preamble_q || pkt_err_block_q || gmii_rx_er_i;

        frame_cnt_q <= frame_cnt_q + 16'd1;
        if (pkt_err_block_q || pkt_err_preamble_q || pkt_oversize_q)
          error_cnt_q <= error_cnt_q + 16'd1;
      end
    end
  end

  assign status_o = {error_cnt_q, frame_cnt_q};

endmodule

`endif // GMII_RX_MAC_SV
