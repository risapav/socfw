/**
 * @file gmii_tx_mac.sv
 * @brief AXI-Stream to GMII TX with IFG control and IEEE 802.3 statistics.
 * @param DATA_WIDTH Datapath width (default 8 for GMII byte-mode).
 * @details State machine: ST_IDLE -> ST_DATA -> ST_IFG. s_axis_tready is
 *   deasserted during ST_IDLE and ST_IFG; cfg_tx_enable gates frame start only.
 *   1-cycle registered output: accepted AXI-S beats appear on GMII one cycle later.
 *   cfg_tx_ifg cycles of TXEN=0 enforced between frames (IEEE 802.3 min = 12).
 *   Frame byte map: byte 0 SFD (0xD5), 1-6 DST_MAC, 7-12 SRC_MAC,
 *   13-14 EtherType, 15+ payload, last 4 FCS.
 *   stat_tx_err_underflow: tvalid deasserted before tlast; TXER asserted to PHY.
 *   stat_tx_err_user: tuser set on any accepted byte during frame.
 *   stat_tx_err_oversize: byte count exceeds cfg_tx_max_pkt_len.
 *   status_o[15:0] = tx_frame_cnt_q.
 */
`ifndef GMII_TX_MAC_SV
`define GMII_TX_MAC_SV

`default_nettype none

module gmii_tx_mac #(
  parameter int DATA_WIDTH = 8
) (
  input  wire logic                  clk_i,
  input  wire logic                  rst_ni,

  // AXI-Stream input
  input  wire logic [DATA_WIDTH-1:0] s_axis_tdata,
  input  wire logic                  s_axis_tvalid,
  input  wire logic                  s_axis_tlast,
  input  wire logic                  s_axis_tuser,
  output      logic                  s_axis_tready,

  // GMII outputs
  output      logic                  gmii_tx_en_o,
  output      logic                  gmii_tx_er_o,
  output      logic [DATA_WIDTH-1:0] gmii_txd_o,

  // Configuration
  input  wire logic [15:0]           cfg_tx_max_pkt_len,
  input  wire logic [7:0]            cfg_tx_ifg,
  input  wire logic                  cfg_tx_enable,

  // Aggregated status
  output      logic [31:0]           status_o,

  // Per-event pulses (1-cycle, synchronous to clk_i)
  output      logic                  tx_start_packet,
  output      logic                  stat_tx_byte,
  output      logic [15:0]           stat_tx_pkt_len,
  output      logic                  stat_tx_pkt_ucast,
  output      logic                  stat_tx_pkt_mcast,
  output      logic                  stat_tx_pkt_bcast,
  output      logic                  stat_tx_pkt_vlan,
  output      logic                  stat_tx_pkt_good,
  output      logic                  stat_tx_pkt_bad,
  output      logic                  stat_tx_err_oversize,
  output      logic                  stat_tx_err_user,
  output      logic                  stat_tx_err_underflow
);

  typedef enum logic [2:0] {
    ST_IDLE     = 3'd0,
    ST_PREAMBLE = 3'd1,
    ST_DATA     = 3'd2,
    ST_IFG      = 3'd3
  } state_e;

  state_e      state_q;
  logic [2:0]  preamble_cnt_q;  // 0..6: 7 bytes of 0x55 before SFD
  logic [7:0]  ifg_cnt_q;
  logic [15:0] byte_cnt_q;
  logic [15:0] tx_frame_cnt_q;

  // Per-frame accumulators (reset at frame start in ST_IDLE)
  logic        pkt_bcast_q;
  logic        pkt_mcast_q;
  logic        pkt_vlan_q;
  logic [7:0]  ethertype_msb_q;
  logic        pkt_err_user_q;
  logic        pkt_oversize_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q               <= ST_IDLE;
      preamble_cnt_q        <= 3'd0;
      ifg_cnt_q             <= 8'd0;
      byte_cnt_q            <= '0;
      tx_frame_cnt_q        <= '0;
      pkt_bcast_q           <= 1'b0;
      pkt_mcast_q           <= 1'b0;
      pkt_vlan_q            <= 1'b0;
      ethertype_msb_q       <= 8'h00;
      pkt_err_user_q        <= 1'b0;
      pkt_oversize_q        <= 1'b0;
      s_axis_tready         <= 1'b0;
      gmii_tx_en_o          <= 1'b0;
      gmii_tx_er_o          <= 1'b0;
      gmii_txd_o            <= '0;
      stat_tx_pkt_len       <= '0;
      tx_start_packet       <= 1'b0;
      stat_tx_byte          <= 1'b0;
      stat_tx_pkt_ucast     <= 1'b0;
      stat_tx_pkt_mcast     <= 1'b0;
      stat_tx_pkt_bcast     <= 1'b0;
      stat_tx_pkt_vlan      <= 1'b0;
      stat_tx_pkt_good      <= 1'b0;
      stat_tx_pkt_bad       <= 1'b0;
      stat_tx_err_oversize  <= 1'b0;
      stat_tx_err_user      <= 1'b0;
      stat_tx_err_underflow <= 1'b0;
    end else begin
      // --- Pulse defaults: clear every cycle ---
      tx_start_packet       <= 1'b0;
      stat_tx_byte          <= 1'b0;
      stat_tx_pkt_ucast     <= 1'b0;
      stat_tx_pkt_mcast     <= 1'b0;
      stat_tx_pkt_bcast     <= 1'b0;
      stat_tx_pkt_vlan      <= 1'b0;
      stat_tx_pkt_good      <= 1'b0;
      stat_tx_pkt_bad       <= 1'b0;
      stat_tx_err_oversize  <= 1'b0;
      stat_tx_err_user      <= 1'b0;
      stat_tx_err_underflow <= 1'b0;

      case (state_q)
        // -----------------------------------------------------------------
        // IDLE: wait for frame start
        // -----------------------------------------------------------------
        ST_IDLE: begin
          gmii_tx_en_o <= 1'b0;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= '0;

          if (s_axis_tvalid && cfg_tx_enable) begin
            state_q         <= ST_PREAMBLE;
            preamble_cnt_q  <= 3'd0;
            byte_cnt_q      <= 16'd0;
            pkt_bcast_q     <= 1'b1;
            pkt_mcast_q     <= 1'b0;
            pkt_vlan_q      <= 1'b0;
            ethertype_msb_q <= 8'h00;
            pkt_err_user_q  <= 1'b0;
            pkt_oversize_q  <= 1'b0;
          end
        end

        // -----------------------------------------------------------------
        // PREAMBLE: emit 7 bytes of 0x55; tready stays 0 (FIFO holds SFD)
        // -----------------------------------------------------------------
        ST_PREAMBLE: begin
          gmii_tx_en_o <= 1'b1;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= 8'h55;

          if (preamble_cnt_q == 3'd6) begin
            state_q       <= ST_DATA;
            s_axis_tready <= 1'b1;
          end else begin
            preamble_cnt_q <= preamble_cnt_q + 3'd1;
          end
        end

        // -----------------------------------------------------------------
        // DATA: accept and forward bytes; classify for statistics
        // -----------------------------------------------------------------
        ST_DATA: begin
          if (s_axis_tvalid) begin
            gmii_tx_en_o <= 1'b1;
            gmii_tx_er_o <= s_axis_tuser;
            gmii_txd_o   <= s_axis_tdata;
            stat_tx_byte <= 1'b1;

            if (byte_cnt_q == 16'd0) tx_start_packet <= 1'b1;

            if (s_axis_tuser)                    pkt_err_user_q <= 1'b1;
            if (byte_cnt_q > cfg_tx_max_pkt_len) pkt_oversize_q <= 1'b1;

            case (byte_cnt_q)
              16'd1: begin  // DST_MAC[0]
                pkt_mcast_q <= s_axis_tdata[0];
                pkt_bcast_q <= (s_axis_tdata == 8'hFF);
              end
              16'd2: pkt_bcast_q <= pkt_bcast_q && (s_axis_tdata == 8'hFF);
              16'd3: pkt_bcast_q <= pkt_bcast_q && (s_axis_tdata == 8'hFF);
              16'd4: pkt_bcast_q <= pkt_bcast_q && (s_axis_tdata == 8'hFF);
              16'd5: pkt_bcast_q <= pkt_bcast_q && (s_axis_tdata == 8'hFF);
              16'd6: pkt_bcast_q <= pkt_bcast_q && (s_axis_tdata == 8'hFF);
              16'd13: ethertype_msb_q <= s_axis_tdata;
              16'd14: pkt_vlan_q <= (ethertype_msb_q == 8'h81) && (s_axis_tdata == 8'h00);
              default: ;
            endcase

            byte_cnt_q <= byte_cnt_q + 16'd1;

            if (s_axis_tlast) begin
              state_q       <= ST_IFG;
              s_axis_tready <= 1'b0;
              ifg_cnt_q     <= cfg_tx_ifg - 8'd1;
              tx_frame_cnt_q <= tx_frame_cnt_q + 16'd1;

              stat_tx_pkt_len   <= byte_cnt_q + 16'd1;
              stat_tx_pkt_ucast <= !pkt_mcast_q && !pkt_bcast_q;
              stat_tx_pkt_mcast <= pkt_mcast_q && !pkt_bcast_q;
              stat_tx_pkt_bcast <= pkt_bcast_q;
              stat_tx_pkt_vlan  <= pkt_vlan_q;
              // Inline oversize catches edge case where last byte is the oversize byte
              stat_tx_err_oversize <= pkt_oversize_q || (byte_cnt_q > cfg_tx_max_pkt_len);
              stat_tx_err_user     <= pkt_err_user_q || s_axis_tuser;

              stat_tx_pkt_good <=
                (byte_cnt_q >= 16'd64) &&
                !(pkt_oversize_q || (byte_cnt_q > cfg_tx_max_pkt_len)) &&
                !(pkt_err_user_q || s_axis_tuser);
              stat_tx_pkt_bad  <=
                (byte_cnt_q < 16'd64) ||
                (pkt_oversize_q || (byte_cnt_q > cfg_tx_max_pkt_len)) ||
                (pkt_err_user_q || s_axis_tuser);
            end
          end else begin
            // Underflow: tvalid deasserted before tlast; abort frame
            state_q               <= ST_IFG;
            s_axis_tready         <= 1'b0;
            gmii_tx_en_o          <= 1'b0;
            gmii_tx_er_o          <= 1'b1;
            gmii_txd_o            <= '0;
            ifg_cnt_q             <= cfg_tx_ifg - 8'd1;
            tx_frame_cnt_q        <= tx_frame_cnt_q + 16'd1;
            stat_tx_err_underflow <= 1'b1;
            stat_tx_pkt_bad       <= 1'b1;
          end
        end

        // -----------------------------------------------------------------
        // IFG: inter-frame gap; hold TXEN=0 for cfg_tx_ifg cycles
        // -----------------------------------------------------------------
        ST_IFG: begin
          s_axis_tready <= 1'b0;
          gmii_tx_en_o  <= 1'b0;
          gmii_tx_er_o  <= 1'b0;
          gmii_txd_o    <= '0;

          if (ifg_cnt_q == 8'd0) begin
            state_q <= ST_IDLE;
          end else begin
            ifg_cnt_q <= ifg_cnt_q - 8'd1;
          end
        end

        default: begin
          state_q      <= ST_IDLE;
          s_axis_tready <= 1'b0;
          gmii_tx_en_o  <= 1'b0;
          gmii_tx_er_o  <= 1'b0;
          gmii_txd_o    <= '0;
        end
      endcase
    end
  end

  assign status_o = {16'd0, tx_frame_cnt_q};

endmodule

`endif // GMII_TX_MAC_SV
