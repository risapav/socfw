/**
 * @file gmii_tx_mac.sv
 * @brief GMII MAC TX layer: preamble, header, payload, padding, FCS, IFG.
 * @details AXI-Stream payload input. tvalid must be continuously asserted during
 * ST_PAYLOAD — GMII TX_EN cannot be de-asserted mid-frame. Padding fills to
 * MIN_FRAME_NO_FCS bytes (header + payload + padding). FCS is CRC32 over header,
 * payload, and padding (LSB-first, IEEE 802.3). IFG = 12 idle bytes after FCS.
 * @param MIN_FRAME_NO_FCS Minimum frame size without FCS (default 60 bytes)
 */

`ifndef GMII_TX_MAC_SV
`define GMII_TX_MAC_SV

`default_nettype none

module gmii_tx_mac #(
  parameter int MIN_FRAME_NO_FCS = 60
)(
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic [47:0] tx_dst_mac_i,
  input  wire logic [47:0] tx_src_mac_i,
  input  wire logic [15:0] tx_ethertype_i,

  input  wire logic        tx_start_i,
  output      logic        tx_busy_o,
  output      logic        tx_done_o,

  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  output      logic        s_axis_tready,
  input  wire logic        s_axis_tlast,

  output      logic [7:0]  gmii_txd_o,
  output      logic        gmii_tx_en_o,
  output      logic        gmii_tx_er_o
);

  localparam int ETH_HDR_BYTES  = 14;
  localparam int MIN_PAYLOAD    = MIN_FRAME_NO_FCS - ETH_HDR_BYTES; // 46
  localparam int PREAMBLE_BYTES = 7;
  localparam int FCS_BYTES      = 4;
  localparam int IFG_BYTES      = 12;

  typedef enum logic [3:0] {
    ST_IDLE, ST_PREAMBLE, ST_SFD, ST_ETH_HEADER,
    ST_PAYLOAD, ST_PADDING, ST_FCS, ST_IFG
  } state_e;

  state_e state_q, state_d;

  // Independent per-phase counters; each resets in the preceding state.
  logic [2:0]  preamble_cnt_q;  // PREAMBLE_BYTES-1 = 6 max
  logic [3:0]  header_idx_q;    // ETH_HDR_BYTES-1  = 13 max
  logic [10:0] payload_cnt_q;   // cumulative payload bytes; not reset on transition
  logic [5:0]  pad_cnt_q;       // padding bytes in current frame
  logic [1:0]  fcs_cnt_q;       // FCS bytes 0-3
  logic [3:0]  ifg_cnt_q;       // IFG bytes 0-11

  logic [31:0] fcs_val;
  logic        fcs_clear, fcs_en;
  logic [7:0]  header_byte;

  eth_header_builder u_hdr_builder (
    .dst_mac_i(tx_dst_mac_i), .src_mac_i(tx_src_mac_i),
    .ethertype_i(tx_ethertype_i), .byte_idx_i(header_idx_q), .byte_o(header_byte)
  );

  crc32_eth u_crc (
    .clk_i, .rst_ni,
    .clear_i(fcs_clear), .en_i(fcs_en),
    .data_i(gmii_txd_o),
    .crc_state_o(), .crc_next_o(), .fcs_o(fcs_val)
  );

  always_comb begin
    state_d       = state_q;
    s_axis_tready = 1'b0;
    fcs_clear     = (state_q == ST_IDLE);
    fcs_en        = (state_q == ST_ETH_HEADER) || (state_q == ST_PAYLOAD) ||
                    (state_q == ST_PADDING);
    gmii_tx_en_o  = (state_q != ST_IDLE) && (state_q != ST_IFG);
    gmii_txd_o    = 8'h00;

    case (state_q)
      ST_IDLE: begin
        if (tx_start_i) state_d = ST_PREAMBLE;
      end

      ST_PREAMBLE: begin
        gmii_txd_o = 8'h55;
        if (preamble_cnt_q == 3'(PREAMBLE_BYTES - 1)) state_d = ST_SFD;
      end

      ST_SFD: begin
        gmii_txd_o = 8'hD5;
        state_d    = ST_ETH_HEADER;
      end

      ST_ETH_HEADER: begin
        gmii_txd_o = header_byte;
        if (header_idx_q == 4'(ETH_HDR_BYTES - 1)) state_d = ST_PAYLOAD;
      end

      ST_PAYLOAD: begin
        gmii_txd_o    = s_axis_tdata;
        s_axis_tready = 1'b1;
        if (s_axis_tvalid && s_axis_tlast)
          state_d = (payload_cnt_q < 11'(MIN_PAYLOAD - 1)) ? ST_PADDING : ST_FCS;
      end

      ST_PADDING: begin
        gmii_txd_o = 8'h00;
        // Exit when total payload+pad bytes reach MIN_PAYLOAD.
        // payload_cnt_q holds final count (updated last payload cycle).
        // pad_cnt_q counts 0..K-1 where K = MIN_PAYLOAD - payload_cnt_q.
        if (pad_cnt_q == (6'(MIN_PAYLOAD - 1) - 6'(payload_cnt_q)))
          state_d = ST_FCS;
      end

      ST_FCS: begin
        unique case (fcs_cnt_q)
          2'd0: gmii_txd_o = fcs_val[7:0];
          2'd1: gmii_txd_o = fcs_val[15:8];
          2'd2: gmii_txd_o = fcs_val[23:16];
          2'd3: gmii_txd_o = fcs_val[31:24];
        endcase
        if (fcs_cnt_q == 2'(FCS_BYTES - 1)) state_d = ST_IFG;
      end

      ST_IFG: begin
        if (ifg_cnt_q == 4'(IFG_BYTES - 1)) state_d = ST_IDLE;
      end

      default: state_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= ST_IDLE;
      preamble_cnt_q <= '0;
      header_idx_q   <= '0;
      payload_cnt_q  <= '0;
      pad_cnt_q      <= '0;
      fcs_cnt_q      <= '0;
      ifg_cnt_q      <= '0;
    end else begin
      state_q <= state_d;
      case (state_q)
        ST_IDLE: begin
          preamble_cnt_q <= '0;
          payload_cnt_q  <= '0;
          pad_cnt_q      <= '0;
          fcs_cnt_q      <= '0;
          ifg_cnt_q      <= '0;
        end
        ST_PREAMBLE:   preamble_cnt_q <= preamble_cnt_q + 1'b1;
        ST_SFD:        header_idx_q   <= '0;
        ST_ETH_HEADER: header_idx_q   <= header_idx_q + 1'b1;
        ST_PAYLOAD: begin
          if (s_axis_tvalid) payload_cnt_q <= payload_cnt_q + 1'b1;
        end
        ST_PADDING:    pad_cnt_q  <= pad_cnt_q  + 1'b1;
        ST_FCS:        fcs_cnt_q  <= fcs_cnt_q  + 1'b1;
        ST_IFG:        ifg_cnt_q  <= ifg_cnt_q  + 1'b1;
        default: ;
      endcase
    end
  end

  assign gmii_tx_er_o = 1'b0;
  assign tx_busy_o    = (state_q != ST_IDLE);
  assign tx_done_o    = (state_q == ST_IFG) && (ifg_cnt_q == 4'(IFG_BYTES - 1));

endmodule

`endif // GMII_TX_MAC_SV
