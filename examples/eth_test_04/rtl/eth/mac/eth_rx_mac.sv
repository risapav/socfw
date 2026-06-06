/**
 * @file eth_rx_mac.sv
 * @brief Clean Ethernet RX MAC: GMII -> payload AXI-Stream + frame metadata.
 * @param LOCAL_MAC      48-bit FPGA MAC address for unicast filter.
 * @param ACCEPT_BROADCAST  Accept frames with DST=FF:FF:FF:FF:FF:FF.
 * @param MAX_FRAME_LEN  Maximum accepted frame size including FCS (bytes).
 * @details Strips preamble, SFD, Ethernet header (14 B) and FCS (4 B).
 *   Emits payload-only AXI-Stream.
 *
 *   FCS strip: 5-byte shift window. win_q[4]=oldest (emitted as payload);
 *   win_q[0..3]=most recent 4 bytes (= FCS when RXDV deasserts).
 *   CRC updated with header bytes (ST_HEADER) and each byte leaving win_q[4].
 *   fcs_ok is combinatorial: ~crc_next_w == {win[0],win[1],win[2],win[3]}.
 *
 *   Metadata (dst_mac, src_mac, eth_type, fcs_ok) is output alongside m_axis_tlast.
 *   fcs_ok=0 if: FCS mismatch, RXER seen, runt frame, or DST MAC not accepted.
 *   All frames (even bad) produce a tlast beat so the downstream FIFO can be drained.
 *
 *   1-cycle pipeline on GMII inputs for IOE timing margin.
 */
`ifndef ETH_RX_MAC_SV
`define ETH_RX_MAC_SV

`default_nettype none

module eth_rx_mac #(
  parameter logic [47:0] LOCAL_MAC        = 48'h000A3501FEC0,
  parameter bit          ACCEPT_BROADCAST = 1'b1,
  parameter bit          ACCEPT_MULTICAST = 1'b0,
  parameter int          MAX_FRAME_LEN    = 1518
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // GMII inputs
  input  wire logic        gmii_rx_dv_i,
  input  wire logic        gmii_rx_er_i,
  input  wire logic [7:0]  gmii_rxd_i,

  // AXI-Stream payload output (no header, no FCS)
  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  input  wire logic        m_axis_tready,  // not backpressured; overflow flag if 0
  output      logic        m_axis_tlast,
  output      logic        m_axis_tuser,   // 1 = error (FCS fail / runt)

  // Metadata valid in same cycle as m_axis_tlast
  output      logic        m_meta_valid,
  input  wire logic        m_meta_ready,
  output      logic [47:0] m_meta_dst_mac,
  output      logic [47:0] m_meta_src_mac,
  output      logic [15:0] m_meta_eth_type,
  output      logic        m_meta_fcs_ok,   // fcs_ok && no_rxer && mac_match (accept gate)
  output      logic        m_meta_mac_ok,   // diagnostic: DST MAC matched filter

  // Diagnostics
  output      logic        stat_overflow,
  output      logic [15:0] stat_rx_frames,
  output      logic [15:0] stat_rx_drop
);

  // -------------------------------------------------------------------------
  // GMII pipeline register
  // -------------------------------------------------------------------------
  logic [7:0] rxd_q;
  logic       rxdv_q;
  logic       rxer_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rxd_q  <= 8'h00;
      rxdv_q <= 1'b0;
      rxer_q <= 1'b0;
    end else begin
      rxd_q  <= gmii_rxd_i;
      rxdv_q <= gmii_rx_dv_i;
      rxer_q <= gmii_rx_er_i;
    end
  end

  // -------------------------------------------------------------------------
  // CRC32 (combinatorial)
  // -------------------------------------------------------------------------
  // crc_data_w mux: header bytes while in ST_HEADER, win_q[4] in ST_PAYLOAD.
  logic [7:0]  crc_data_w;
  logic [31:0] crc_state_q;
  logic [31:0] crc_next_w;

  eth_crc32_8 u_crc (
    .data_i (crc_data_w),
    .crc_i  (crc_state_q),
    .crc_o  (crc_next_w)
  );

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE     = 3'd0,
    ST_PREAMBLE = 3'd1,
    ST_HEADER   = 3'd2,
    ST_PAYLOAD  = 3'd3
  } state_e;

  state_e state_q;

  logic [3:0]  hdr_cnt_q;
  logic [47:0] dst_mac_q;
  logic [47:0] src_mac_q;
  logic [15:0] eth_type_q;

  // 5-byte shift window: [0]=newest, [4]=oldest
  logic [7:0]  win_q [0:4];
  logic [2:0]  win_cnt_q;

  // Per-frame flags
  logic        pkt_bcast_q;
  logic        pkt_mcast_q;
  logic        mac_match_q;
  logic        rx_er_acc_q;

  // Output registers
  logic [7:0]  axis_data_q;
  logic        axis_valid_q;
  logic        axis_last_q;
  logic        axis_user_q;

  // Meta output registers (held until m_meta_ready)
  logic        meta_valid_q;
  logic [47:0] meta_dst_q;
  logic [47:0] meta_src_q;
  logic [15:0] meta_type_q;
  logic        meta_fcs_ok_q;
  logic        meta_mac_ok_q;

  // Counters
  logic [15:0] rx_frames_q;
  logic [15:0] rx_drop_q;
  logic        overflow_q;

  // -------------------------------------------------------------------------
  // CRC data mux (combinatorial)
  // -------------------------------------------------------------------------
  always_comb begin
    case (state_q)
      ST_HEADER:  crc_data_w = rxd_q;
      ST_PAYLOAD: crc_data_w = win_q[4];
      default:    crc_data_w = 8'h00;
    endcase
  end

  // -------------------------------------------------------------------------
  // Combinatorial FCS check (used at end-of-frame in ST_PAYLOAD)
  // fcs_rx: wire bytes arrive LSB-first: win[3]=F0, win[2]=F1, win[1]=F2, win[0]=F3
  // as 32-bit: {F3,F2,F1,F0} = {win[0],win[1],win[2],win[3]} = FCS[31:0]
  // -------------------------------------------------------------------------
  logic [31:0] fcs_rx_w;
  logic        fcs_ok_w;

  always_comb begin
    fcs_rx_w = {win_q[0], win_q[1], win_q[2], win_q[3]};
    fcs_ok_w = (fcs_rx_w == ~crc_next_w);  // crc_next_w includes win_q[4]
  end

  // -------------------------------------------------------------------------
  // Sequential FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_IDLE;
      hdr_cnt_q    <= 4'd0;
      win_cnt_q    <= 3'd0;
      crc_state_q  <= 32'hFFFF_FFFF;
      dst_mac_q    <= '0;
      src_mac_q    <= '0;
      eth_type_q   <= '0;
      pkt_bcast_q  <= 1'b0;
      pkt_mcast_q  <= 1'b0;
      mac_match_q  <= 1'b0;
      rx_er_acc_q  <= 1'b0;
      axis_data_q  <= 8'h00;
      axis_valid_q <= 1'b0;
      axis_last_q  <= 1'b0;
      axis_user_q  <= 1'b0;
      meta_valid_q  <= 1'b0;
      meta_dst_q    <= '0;
      meta_src_q    <= '0;
      meta_type_q   <= '0;
      meta_fcs_ok_q <= 1'b0;
      meta_mac_ok_q <= 1'b0;
      rx_frames_q  <= '0;
      rx_drop_q    <= '0;
      overflow_q   <= 1'b0;
      for (int i = 0; i < 5; i++) win_q[i] <= 8'h00;
    end else begin
      // Overflow detection
      if (axis_valid_q && !m_axis_tready)
        overflow_q <= 1'b1;

      // Default: de-assert one-cycle outputs
      axis_valid_q <= 1'b0;
      axis_last_q  <= 1'b0;
      axis_user_q  <= 1'b0;

      // Meta handshake: clear when consumed
      if (meta_valid_q && m_meta_ready)
        meta_valid_q <= 1'b0;

      case (state_q)

        // -------------------------------------------------------------------
        ST_IDLE: begin
          win_cnt_q   <= 3'd0;
          rx_er_acc_q <= 1'b0;
          if (rxdv_q) begin
            if (rxd_q == 8'hD5) begin
              // RTL8211EG asserts RXDV starting at SFD — jump directly to header
              state_q     <= ST_HEADER;
              hdr_cnt_q   <= 4'd0;
              crc_state_q <= 32'hFFFF_FFFF;
              pkt_bcast_q <= 1'b1;
              pkt_mcast_q <= 1'b0;
              mac_match_q <= 1'b0;
              rx_er_acc_q <= rxer_q;
              win_cnt_q   <= 3'd0;
              dst_mac_q   <= '0;
              src_mac_q   <= '0;
              eth_type_q  <= '0;
            end else begin
              state_q <= ST_PREAMBLE;
            end
          end
        end

        // -------------------------------------------------------------------
        ST_PREAMBLE: begin
          if (!rxdv_q) begin
            state_q <= ST_IDLE;
          end else if (rxd_q == 8'hD5) begin
            state_q     <= ST_HEADER;
            hdr_cnt_q   <= 4'd0;
            crc_state_q <= 32'hFFFF_FFFF;
            pkt_bcast_q <= 1'b1;
            pkt_mcast_q <= 1'b0;
            mac_match_q <= 1'b0;
            rx_er_acc_q <= rxer_q;
            win_cnt_q   <= 3'd0;
            dst_mac_q   <= '0;
            src_mac_q   <= '0;
            eth_type_q  <= '0;
          end else if (rxd_q != 8'h55) begin
            state_q <= ST_IDLE;  // bad preamble byte
          end
        end

        // -------------------------------------------------------------------
        ST_HEADER: begin
          if (!rxdv_q) begin
            // Frame ended before 14 bytes
            rx_drop_q <= rx_drop_q + 16'd1;
            state_q   <= ST_IDLE;
          end else begin
            if (rxer_q) rx_er_acc_q <= 1'b1;
            crc_state_q <= crc_next_w;  // update CRC with rxd_q

            case (hdr_cnt_q)
              4'd0: begin
                dst_mac_q[47:40] <= rxd_q;
                pkt_mcast_q      <= rxd_q[0];
                pkt_bcast_q      <= (rxd_q == 8'hFF);
              end
              4'd1: begin
                dst_mac_q[39:32] <= rxd_q;
                pkt_bcast_q <= pkt_bcast_q && (rxd_q == 8'hFF);
              end
              4'd2: begin
                dst_mac_q[31:24] <= rxd_q;
                pkt_bcast_q <= pkt_bcast_q && (rxd_q == 8'hFF);
              end
              4'd3: begin
                dst_mac_q[23:16] <= rxd_q;
                pkt_bcast_q <= pkt_bcast_q && (rxd_q == 8'hFF);
              end
              4'd4: begin
                dst_mac_q[15:8] <= rxd_q;
                pkt_bcast_q <= pkt_bcast_q && (rxd_q == 8'hFF);
              end
              4'd5: begin
                dst_mac_q[7:0]  <= rxd_q;
                pkt_bcast_q <= pkt_bcast_q && (rxd_q == 8'hFF);
              end
              4'd6:  src_mac_q[47:40] <= rxd_q;
              4'd7:  src_mac_q[39:32] <= rxd_q;
              4'd8:  src_mac_q[31:24] <= rxd_q;
              4'd9:  src_mac_q[23:16] <= rxd_q;
              4'd10: src_mac_q[15:8]  <= rxd_q;
              4'd11: src_mac_q[7:0]   <= rxd_q;
              4'd12: eth_type_q[15:8] <= rxd_q;
              4'd13: begin
                eth_type_q[7:0] <= rxd_q;
                // Evaluate MAC match after DST bytes (captured by byte 5)
                // mac_match_q is set based on dst_mac_q which is complete after byte 5
                // but pkt_bcast_q is updated through byte 5; use combinatorial result
                mac_match_q <= (dst_mac_q == LOCAL_MAC) ||
                               (ACCEPT_BROADCAST && pkt_bcast_q) ||
                               (ACCEPT_MULTICAST && pkt_mcast_q);
              end
              default: ;
            endcase

            if (hdr_cnt_q == 4'd13) begin
              state_q   <= ST_PAYLOAD;
              win_cnt_q <= 3'd0;
            end else begin
              hdr_cnt_q <= hdr_cnt_q + 4'd1;
            end
          end
        end

        // -------------------------------------------------------------------
        // 5-byte shift window + FCS strip + CRC update
        // -------------------------------------------------------------------
        ST_PAYLOAD: begin
          if (!rxdv_q) begin
            // End of frame
            if (win_cnt_q == 3'd5) begin
              // Emit last payload byte (win_q[4]) with tlast
              // crc_data_w=win_q[4], fcs_ok_w is combinatorial
              axis_data_q  <= win_q[4];
              axis_valid_q <= 1'b1;
              axis_last_q  <= 1'b1;
              axis_user_q  <= !(fcs_ok_w && !rx_er_acc_q && mac_match_q);

              crc_state_q <= crc_next_w;  // update CRC with last payload byte

              // Latch metadata (wait if consumer not ready)
              if (!meta_valid_q || m_meta_ready) begin
                meta_valid_q  <= 1'b1;
                meta_dst_q    <= dst_mac_q;
                meta_src_q    <= src_mac_q;
                meta_type_q   <= eth_type_q;
                meta_fcs_ok_q <= fcs_ok_w && !rx_er_acc_q && mac_match_q;
                meta_mac_ok_q <= mac_match_q;
              end

              rx_frames_q <= rx_frames_q + 16'd1;
              if (!mac_match_q || !fcs_ok_w)
                rx_drop_q <= rx_drop_q + 16'd1;

            end else begin
              // Runt frame: emit 1 error byte so downstream can drain
              if (win_cnt_q > 3'd0) begin
                axis_data_q  <= 8'h00;
                axis_valid_q <= 1'b1;
                axis_last_q  <= 1'b1;
                axis_user_q  <= 1'b1;

                if (!meta_valid_q || m_meta_ready) begin
                  meta_valid_q  <= 1'b1;
                  meta_dst_q    <= dst_mac_q;
                  meta_src_q    <= src_mac_q;
                  meta_type_q   <= eth_type_q;
                  meta_fcs_ok_q <= 1'b0;
                  meta_mac_ok_q <= 1'b0;
                end
              end
              rx_drop_q <= rx_drop_q + 16'd1;
            end

            state_q <= ST_IDLE;

          end else begin
            // RXDV high: accumulate payload
            if (rxer_q) rx_er_acc_q <= 1'b1;

            if (win_cnt_q < 3'd5) begin
              // Window still filling
              win_q[0] <= rxd_q;
              if (win_cnt_q > 3'd0) win_q[1] <= win_q[0];
              if (win_cnt_q > 3'd1) win_q[2] <= win_q[1];
              if (win_cnt_q > 3'd2) win_q[3] <= win_q[2];
              if (win_cnt_q > 3'd3) win_q[4] <= win_q[3];
              win_cnt_q <= win_cnt_q + 3'd1;
            end else begin
              // Window full: emit win_q[4] and shift
              axis_data_q  <= win_q[4];
              axis_valid_q <= 1'b1;
              // CRC with win_q[4] (crc_data_w = win_q[4] when ST_PAYLOAD)
              crc_state_q  <= crc_next_w;
              // Shift window
              win_q[4] <= win_q[3];
              win_q[3] <= win_q[2];
              win_q[2] <= win_q[1];
              win_q[1] <= win_q[0];
              win_q[0] <= rxd_q;
            end
          end
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Output wiring
  // -------------------------------------------------------------------------
  assign m_axis_tdata    = axis_data_q;
  assign m_axis_tvalid   = axis_valid_q;
  assign m_axis_tlast    = axis_last_q;
  assign m_axis_tuser    = axis_user_q;

  assign m_meta_valid    = meta_valid_q;
  assign m_meta_dst_mac  = meta_dst_q;
  assign m_meta_src_mac  = meta_src_q;
  assign m_meta_eth_type = meta_type_q;
  assign m_meta_fcs_ok   = meta_fcs_ok_q;
  assign m_meta_mac_ok   = meta_mac_ok_q;

  assign stat_overflow   = overflow_q;
  assign stat_rx_frames  = rx_frames_q;
  assign stat_rx_drop    = rx_drop_q;

endmodule

`endif // ETH_RX_MAC_SV
