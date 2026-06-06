/**
 * @file eth_tx_mac.sv
 * @brief Clean Ethernet TX MAC: metadata + payload AXI-Stream -> GMII.
 * @param IFG_CYCLES  Inter-frame gap in TX clock cycles (IEEE 802.3 minimum = 12).
 * @details Generates: preamble (7x0x55), SFD (0xD5), Ethernet header from
 *   tx_meta, payload, zero-padding to minimum 46 payload bytes, CRC32 FCS, IFG.
 *
 *   CRC32 covers: header (14 B) + payload + padding. Initialized to 0xFFFFFFFF.
 *   FCS emitted LSB byte first (IEEE 802.3 wire order).
 *   All outputs are registered (1-cycle pipeline latency from data to GMII pin).
 *
 *   s_meta accepted in ST_IDLE (s_meta_ready = state==IDLE).
 *   s_axis consumed in ST_PAYLOAD (s_axis_tready = state==PAYLOAD).
 *   Underflow (tvalid=0 in ST_PAYLOAD): assert TXER, abort to ST_IFG.
 *   fire_w = tvalid && tready (explicit AXI-S handshake, per navrhy_04).
 */
`ifndef ETH_TX_MAC_SV
`define ETH_TX_MAC_SV

`default_nettype none

module eth_tx_mac #(
  parameter int IFG_CYCLES = 12
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // Metadata: one entry per frame
  input  wire logic        s_meta_valid_i,
  output      logic        s_meta_ready_o,
  input  wire logic [47:0] s_meta_dst_mac_i,
  input  wire logic [47:0] s_meta_src_mac_i,
  input  wire logic [15:0] s_meta_eth_type_i,

  // Payload AXI-Stream (payload only, no header/FCS)
  input  wire logic [7:0]  s_axis_tdata_i,
  input  wire logic        s_axis_tvalid_i,
  output      logic        s_axis_tready_o,
  input  wire logic        s_axis_tlast_i,
  input  wire logic        s_axis_tuser_i,

  // GMII TX outputs
  output      logic [7:0]  gmii_txd_o,
  output      logic        gmii_tx_en_o,
  output      logic        gmii_tx_er_o,

  // Statistics
  output      logic [15:0] stat_tx_frames,
  output      logic [15:0] stat_tx_underflow
);

  // -------------------------------------------------------------------------
  // CRC32 (combinatorial)
  // -------------------------------------------------------------------------
  logic [7:0]  crc_data_w;
  logic [31:0] crc_state_q;
  logic [31:0] crc_next_w;

  eth_crc32_8 u_crc (
    .data_i (crc_data_w),
    .crc_i  (crc_state_q),
    .crc_o  (crc_next_w)
  );

  // -------------------------------------------------------------------------
  // FSM states
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE     = 3'd0,
    ST_PREAMBLE = 3'd1,
    ST_SFD      = 3'd2,
    ST_HEADER   = 3'd3,
    ST_PAYLOAD  = 3'd4,
    ST_PAD      = 3'd5,
    ST_FCS      = 3'd6,
    ST_IFG      = 3'd7
  } state_e;

  state_e state_q;

  logic [2:0]   preamble_cnt_q;
  logic [3:0]   hdr_cnt_q;
  logic [1:0]   fcs_cnt_q;
  logic [5:0]   payload_cnt_q;  // counts bytes consumed in ST_PAYLOAD (saturates at 63)
  logic [5:0]   pad_cnt_q;
  logic [7:0]   ifg_cnt_q;

  logic [111:0] hdr_shift_q;    // {dst_mac[47:0], src_mac[47:0], eth_type[15:0]}
  logic [31:0]  fcs_shift_q;

  logic [15:0]  tx_frames_q;
  logic [15:0]  tx_underflow_q;

  // Explicit AXI-S handshake (fire on tvalid && tready)
  logic fire_w;
  assign fire_w = s_axis_tvalid_i && s_axis_tready_o;

  logic meta_fire_w;
  assign meta_fire_w = s_meta_valid_i && s_meta_ready_o;

  // -------------------------------------------------------------------------
  // CRC data mux (combinatorial)
  // -------------------------------------------------------------------------
  always_comb begin
    case (state_q)
      ST_HEADER:  crc_data_w = hdr_shift_q[111:104];
      ST_PAYLOAD: crc_data_w = s_axis_tdata_i;
      ST_PAD:     crc_data_w = 8'h00;
      default:    crc_data_w = 8'h00;
    endcase
  end

  // -------------------------------------------------------------------------
  // Sequential FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= ST_IDLE;
      preamble_cnt_q <= 3'd0;
      hdr_cnt_q      <= 4'd0;
      fcs_cnt_q      <= 2'd0;
      payload_cnt_q  <= 6'd0;
      pad_cnt_q      <= 6'd0;
      ifg_cnt_q      <= 8'd0;
      hdr_shift_q    <= '0;
      fcs_shift_q    <= '0;
      crc_state_q    <= 32'hFFFF_FFFF;
      gmii_txd_o     <= 8'h00;
      gmii_tx_en_o   <= 1'b0;
      gmii_tx_er_o   <= 1'b0;
      tx_frames_q    <= '0;
      tx_underflow_q <= '0;
    end else begin
      case (state_q)

        // -------------------------------------------------------------------
        ST_IDLE: begin
          gmii_tx_en_o <= 1'b0;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= 8'h00;
          if (meta_fire_w) begin
            hdr_shift_q    <= {s_meta_dst_mac_i, s_meta_src_mac_i, s_meta_eth_type_i};
            crc_state_q    <= 32'hFFFF_FFFF;
            payload_cnt_q  <= 6'd0;
            preamble_cnt_q <= 3'd0;
            state_q        <= ST_PREAMBLE;
          end
        end

        // -------------------------------------------------------------------
        ST_PREAMBLE: begin
          gmii_tx_en_o <= 1'b1;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= 8'h55;
          if (preamble_cnt_q == 3'd6) begin
            state_q <= ST_SFD;
          end else begin
            preamble_cnt_q <= preamble_cnt_q + 3'd1;
          end
        end

        // -------------------------------------------------------------------
        ST_SFD: begin
          gmii_tx_en_o <= 1'b1;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= 8'hD5;
          hdr_cnt_q    <= 4'd0;
          state_q      <= ST_HEADER;
        end

        // -------------------------------------------------------------------
        // Emit 14-byte header from hdr_shift_q MSB-first; update CRC
        // -------------------------------------------------------------------
        ST_HEADER: begin
          gmii_tx_en_o <= 1'b1;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= hdr_shift_q[111:104];
          crc_state_q  <= crc_next_w;               // crc_data_w = hdr_shift_q[111:104]
          hdr_shift_q  <= {hdr_shift_q[103:0], 8'h00};
          if (hdr_cnt_q == 4'd13) begin
            state_q <= ST_PAYLOAD;
          end else begin
            hdr_cnt_q <= hdr_cnt_q + 4'd1;
          end
        end

        // -------------------------------------------------------------------
        // Consume payload AXI-S; update CRC; detect tlast for pad/FCS
        // -------------------------------------------------------------------
        ST_PAYLOAD: begin
          if (!fire_w) begin
            // Underflow: assert TXER with TXEN=1 (IEEE 802.3 frame error, 1 error byte)
            gmii_tx_en_o   <= 1'b1;
            gmii_tx_er_o   <= 1'b1;
            gmii_txd_o     <= 8'h00;
            tx_underflow_q <= tx_underflow_q + 16'd1;
            ifg_cnt_q      <= 8'(IFG_CYCLES - 1);
            state_q        <= ST_IFG;
          end else begin
            // fire_w = 1 here (tvalid && tready, tready=1 when in ST_PAYLOAD)
            gmii_tx_en_o  <= 1'b1;
            gmii_tx_er_o  <= 1'b0;
            gmii_txd_o    <= s_axis_tdata_i;
            crc_state_q   <= crc_next_w;             // crc_data_w = s_axis_tdata_i

            if (payload_cnt_q < 6'd63)
              payload_cnt_q <= payload_cnt_q + 6'd1;

            if (s_axis_tlast_i) begin
              if (payload_cnt_q < 6'd45) begin
                // Payload too short; need padding
                pad_cnt_q <= 6'd45 - payload_cnt_q;
                state_q   <= ST_PAD;
              end else begin
                // No padding; capture FCS immediately
                fcs_shift_q <= ~crc_next_w;
                fcs_cnt_q   <= 2'd0;
                state_q     <= ST_FCS;
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // Emit zero padding to reach minimum 46 payload bytes; update CRC
        // -------------------------------------------------------------------
        ST_PAD: begin
          gmii_tx_en_o <= 1'b1;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= 8'h00;
          crc_state_q  <= crc_next_w;                // crc_data_w = 0x00

          if (pad_cnt_q == 6'd1) begin
            // Last pad byte; capture final CRC as FCS
            fcs_shift_q <= ~crc_next_w;
            fcs_cnt_q   <= 2'd0;
            state_q     <= ST_FCS;
          end else begin
            pad_cnt_q <= pad_cnt_q - 6'd1;
          end
        end

        // -------------------------------------------------------------------
        // Emit 4 FCS bytes LSB-first (IEEE 802.3 wire order)
        // Registered output: byte set at edge N appears on wire at cycle N+1.
        // -------------------------------------------------------------------
        ST_FCS: begin
          gmii_tx_en_o <= 1'b1;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= fcs_shift_q[7:0];
          fcs_shift_q  <= {8'h00, fcs_shift_q[31:8]};  // shift right for next byte

          if (fcs_cnt_q == 2'd3) begin
            // 4th FCS byte queued; transition to IFG
            tx_frames_q <= tx_frames_q + 16'd1;
            ifg_cnt_q   <= 8'(IFG_CYCLES - 1);
            state_q     <= ST_IFG;
          end else begin
            fcs_cnt_q <= fcs_cnt_q + 2'd1;
          end
        end

        // -------------------------------------------------------------------
        ST_IFG: begin
          gmii_tx_en_o <= 1'b0;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= 8'h00;
          if (ifg_cnt_q == 8'd0) begin
            state_q <= ST_IDLE;
          end else begin
            ifg_cnt_q <= ifg_cnt_q - 8'd1;
          end
        end

        default: begin
          state_q      <= ST_IDLE;
          gmii_tx_en_o <= 1'b0;
          gmii_tx_er_o <= 1'b0;
          gmii_txd_o   <= 8'h00;
        end

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Combinatorial outputs
  // -------------------------------------------------------------------------
  assign s_meta_ready_o  = (state_q == ST_IDLE);
  assign s_axis_tready_o = (state_q == ST_PAYLOAD);

  assign stat_tx_frames    = tx_frames_q;
  assign stat_tx_underflow = tx_underflow_q;

endmodule

`endif // ETH_TX_MAC_SV
