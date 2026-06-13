/**
 * @file udp_xfcp_server.sv
 * @brief UDP XFCP server: bridges IPv4/UDP L4 stream to xfcp_arbiter_2to1 port 1.
 * @param XFCP_PORT     UDP destination port for XFCP traffic (default 50000).
 * @param MAX_PKT_BYTES Buffer depth per direction in bytes (default 128).
 * @details
 *   RX path (no upstream backpressure on L4 stream):
 *     L4 stream -> parse 8-byte UDP header -> buffer payload -> xfcp_rx_* (arbiter.s1).
 *   TX path:
 *     xfcp_tx_* (arbiter.m1) -> buffer response -> UDP hdr + payload -> m_meta/m_axis.
 *
 *   Byte 0 of the L4 stream arrives simultaneously with s_ip_hdr_valid_i (ipv4_rx
 *   convention).  Drops new RX frames while rx_buf is busy (single frame in flight).
 *   One request-response cycle at a time.  m_meta/m_axis connects to an ipv4_tx
 *   instance in the top-level.
 */

`ifndef UDP_XFCP_SERVER_SV
`define UDP_XFCP_SERVER_SV

`default_nettype none

module udp_xfcp_server #(
  parameter logic [15:0] XFCP_PORT    = 16'd50000,
  parameter int          MAX_PKT_BYTES = 128
)(
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // L4 payload stream from ipv4_rx (no backpressure)
  input  wire logic        s_ip_hdr_valid_i,
  input  wire logic [7:0]  s_ip_proto_i,
  input  wire logic [31:0] s_ip_src_ip_i,
  input  wire logic        s_ip_accept_i,
  input  wire logic [47:0] s_eth_src_mac_i,
  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  input  wire logic        s_axis_tlast,
  input  wire logic        s_axis_tuser,

  // XFCP RX to arbiter.s1
  output      logic        xfcp_rx_valid_o,
  input  wire logic        xfcp_rx_ready_i,
  output      logic [7:0]  xfcp_rx_data_o,
  output      logic        xfcp_rx_last_o,

  // XFCP TX from arbiter.m1
  input  wire logic        xfcp_tx_valid_i,
  output      logic        xfcp_tx_ready_o,
  input  wire logic [7:0]  xfcp_tx_data_i,
  input  wire logic        xfcp_tx_last_i,

  // IPv4 TX meta (to ipv4_tx instance in top-level)
  output      logic        m_meta_valid_o,
  input  wire logic        m_meta_ready_i,
  output      logic [7:0]  m_meta_proto_o,
  output      logic [31:0] m_meta_dst_ip_o,
  output      logic [47:0] m_meta_dst_mac_o,
  output      logic [15:0] m_meta_payload_len_o,

  // IPv4 TX payload stream (to ipv4_tx instance in top-level)
  output      logic [7:0]  m_axis_tdata_o,
  output      logic        m_axis_tvalid_o,
  input  wire logic        m_axis_tready_i,
  output      logic        m_axis_tlast_o,
  output      logic        m_axis_tuser_o
);

  localparam int BW   = $clog2(MAX_PKT_BYTES);
  localparam int MAXB = MAX_PKT_BYTES;

  // =========================================================================
  // RX FSM: L4 stream -> rx_buf (no backpressure upstream)
  // =========================================================================
  typedef enum logic [1:0] {
    RX_IDLE  = 2'd0,
    RX_HDR   = 2'd1,
    RX_DATA  = 2'd2,
    RX_DRAIN = 2'd3
  } rx_state_e;

  rx_state_e rx_state_q;

  logic [2:0]  rx_byte_cnt_q;
  logic [7:0]  src_p0_q, src_p1_q;  // saved src_port bytes (for UDP reply)
  logic        port_ok_q;
  logic [31:0] src_ip_q;
  logic [47:0] src_mac_q;
  logic [7:0]  dst_p_h_q;

  (* ramstyle = "M9K"   *) logic [7:0]  rx_buf [0:MAX_PKT_BYTES-1];
  logic [BW:0] rx_len_q;     // bytes buffered in rx_buf
  logic        rx_complete_q;

  // OUT FSM: rx_buf -> xfcp_rx_*
  typedef enum logic { OUT_IDLE = 1'b0, OUT_SEND = 1'b1 } out_state_e;

  out_state_e  out_state_q;
  logic [BW:0] out_rd_q;
  logic [BW:0] out_len_q;

  // Pre-registered rx_buf read: breaks out_rd_q -> rx_buf (LUT_RAM) -> skid path.
  // Prefetches the next address so out_rx_data_r is already stable when OUT_SEND fires.
  // Mirrors the resp_buf/tx_data_r pattern used on the TX side.
  logic [BW-1:0] out_rd_next_w;
  always_comb begin
    if (out_state_q == OUT_IDLE && rx_complete_q)
      out_rd_next_w = {BW{1'b0}};
    else if (out_state_q == OUT_SEND && xfcp_rx_ready_i &&
             out_len_q != '0 && out_rd_q != out_len_q - 1'b1)
      out_rd_next_w = out_rd_q[BW-1:0] + 1'b1;
    else
      out_rd_next_w = out_rd_q[BW-1:0];
  end

  logic [7:0] out_rx_data_r;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) out_rx_data_r <= '0;
    else         out_rx_data_r <= rx_buf[out_rd_next_w];
  end

  // =========================================================================
  // RESP buffer: xfcp_tx_* (arbiter.m1) -> resp_buf
  // =========================================================================
  (* ramstyle = "M9K" *)   logic [7:0]  resp_buf [0:MAX_PKT_BYTES-1];
  logic [BW:0] resp_len_q;
  logic        resp_complete_q;

  // TX FSM: resp_buf -> IPv4 TX output
  typedef enum logic [2:0] {
    TX_IDLE = 3'd0,
    TX_META = 3'd1,
    TX_HDR  = 3'd2,
    TX_DATA = 3'd3
  } tx_state_e;

  tx_state_e tx_state_q;
  logic [2:0]  tx_hdr_cnt_q;
  logic [BW:0] tx_rd_q;
  logic [BW:0] tx_resp_len_q;   // snapshot of resp_len_q at TX start
  logic [15:0] tx_payload_len_q; // UDP len = 8 + resp_len
  logic [47:0] tx_dst_mac_q;
  logic [31:0] tx_dst_ip_q;
  logic [7:0]  tx_dst_p0_q, tx_dst_p1_q;  // reply dst port = sender src port

  logic tx_fire_w;
  assign tx_fire_w = m_axis_tvalid_o && m_axis_tready_i;

  // 8-byte UDP reply header
  logic [7:0] tx_hdr_byte_w;
  always_comb begin
    case (tx_hdr_cnt_q)
      3'd0:    tx_hdr_byte_w = XFCP_PORT[15:8];
      3'd1:    tx_hdr_byte_w = XFCP_PORT[7:0];
      3'd2:    tx_hdr_byte_w = tx_dst_p0_q;
      3'd3:    tx_hdr_byte_w = tx_dst_p1_q;
      3'd4:    tx_hdr_byte_w = tx_payload_len_q[15:8];
      3'd5:    tx_hdr_byte_w = tx_payload_len_q[7:0];
      3'd6:    tx_hdr_byte_w = 8'h00;
      3'd7:    tx_hdr_byte_w = 8'h00;
      default: tx_hdr_byte_w = 8'h00;
    endcase
  end

  // Register m_axis_tready_i to break the critical path:
  //   grant_q (eth_tx_arb FF) -> arbiter logic -> tready_i -> resp_buf -> tx_data_r.
  // Safe: eth_tx_arb uses frame-level arbitration so tready_i is held 1 continuously
  // throughout TX_DATA (no mid-frame preemption from higher-priority ports).
  logic m_tready_r;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) m_tready_r <= 1'b0;
    else         m_tready_r <= m_axis_tready_i;
  end

  // Pre-registered resp_buf read: breaks tx_rd_q -> resp_buf -> m_axis_tdata path.
  // Uses m_tready_r (not live tready) for address pre-fetch — no long path from
  // grant_q to resp_buf. State machine still uses tx_fire_w (live tready).
  // resp_buf is M9K block RAM: registered read matches this always_ff pattern,
  // reducing the critical-path data delay from ~9 ns (LUT-RAM) to ~3-4 ns.
  wire  [BW-1:0] tx_rd_next_w = (tx_state_q == TX_DATA && m_axis_tvalid_o && m_tready_r)
                                 ? tx_rd_q[BW-1:0] + 1'b1 : tx_rd_q[BW-1:0];
  logic [7:0] tx_data_r;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) tx_data_r <= '0;
    else         tx_data_r <= resp_buf[tx_rd_next_w];
  end

  logic server_busy_w;
  assign server_busy_w = rx_complete_q || resp_complete_q ||
                         (out_state_q != OUT_IDLE) || (tx_state_q != TX_IDLE);

  // =========================================================================
  // Sequential logic
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_state_q       <= RX_IDLE;
      rx_byte_cnt_q    <= 3'd0;
      src_p0_q         <= 8'h0;  src_p1_q      <= 8'h0;
      port_ok_q        <= 1'b0;
      src_ip_q         <= '0;    src_mac_q     <= '0;
      dst_p_h_q        <= 8'h0;
      rx_len_q         <= '0;
      rx_complete_q    <= 1'b0;
      out_state_q      <= OUT_IDLE;
      out_rd_q         <= '0;    out_len_q     <= '0;
      resp_len_q       <= '0;
      resp_complete_q  <= 1'b0;
      tx_state_q       <= TX_IDLE;
      tx_hdr_cnt_q     <= 3'd0;
      tx_rd_q          <= '0;    tx_resp_len_q <= '0;
      tx_payload_len_q <= 16'd0;
      tx_dst_mac_q     <= '0;    tx_dst_ip_q   <= '0;
      tx_dst_p0_q      <= 8'h0;  tx_dst_p1_q   <= 8'h0;
    end else begin

      // ====================================================================
      // RX FSM
      // ====================================================================
      case (rx_state_q)

        RX_IDLE: begin
          if (s_ip_hdr_valid_i && (s_ip_proto_i == 8'h11) &&
              s_ip_accept_i && !server_busy_w && s_axis_tvalid) begin
            src_ip_q      <= s_ip_src_ip_i;
            src_mac_q     <= s_eth_src_mac_i;
            src_p0_q      <= s_axis_tdata;
            port_ok_q     <= 1'b1;
            rx_len_q      <= '0;
            rx_byte_cnt_q <= 3'd1;
            if (!s_axis_tlast) rx_state_q <= RX_HDR;
          end
        end

        RX_HDR: begin
          if (s_axis_tvalid) begin
            case (rx_byte_cnt_q)
              3'd1: src_p1_q  <= s_axis_tdata;
              3'd2: dst_p_h_q <= s_axis_tdata;
              3'd3: port_ok_q <= (port_ok_q && ({dst_p_h_q, s_axis_tdata} == XFCP_PORT));
              default: ;
            endcase
            if (s_axis_tuser) port_ok_q <= 1'b0;
            if ((rx_byte_cnt_q == 3'd7) || s_axis_tlast) begin
              rx_byte_cnt_q <= 3'd0;
              if (s_axis_tlast)
                rx_state_q <= RX_IDLE;
              else if (port_ok_q && !s_axis_tuser)
                rx_state_q <= RX_DATA;
              else
                rx_state_q <= RX_DRAIN;
            end else begin
              rx_byte_cnt_q <= rx_byte_cnt_q + 3'd1;
            end
          end
        end

        RX_DATA: begin
          if (s_axis_tvalid) begin
            if (int'(rx_len_q) < MAXB) begin
              rx_buf[rx_len_q[BW-1:0]] <= s_axis_tdata;
              rx_len_q <= rx_len_q + 1'b1;
            end
            if (s_axis_tlast) begin
              if (int'(rx_len_q) < MAXB) rx_complete_q <= 1'b1;
              rx_state_q <= RX_IDLE;
            end else if (int'(rx_len_q) >= MAXB) begin
              rx_state_q <= RX_DRAIN;
            end
          end
        end

        RX_DRAIN: begin
          if (s_axis_tvalid && s_axis_tlast) rx_state_q <= RX_IDLE;
        end

        default: rx_state_q <= RX_IDLE;
      endcase

      // ====================================================================
      // OUT FSM: rx_buf -> xfcp_rx_*
      // ====================================================================
      case (out_state_q)

        OUT_IDLE: begin
          if (rx_complete_q) begin
            out_rd_q    <= '0;
            out_len_q   <= rx_len_q;
            out_state_q <= OUT_SEND;
          end
        end

        OUT_SEND: begin
          if (xfcp_rx_valid_o && xfcp_rx_ready_i) begin
            if (xfcp_rx_last_o) begin
              rx_complete_q <= 1'b0;
              out_state_q   <= OUT_IDLE;
            end else begin
              out_rd_q <= out_rd_q + 1'b1;
            end
          end
        end

        default: out_state_q <= OUT_IDLE;
      endcase

      // ====================================================================
      // RESP buffer: arbiter.m1 -> resp_buf
      // ====================================================================
      if (xfcp_tx_valid_i && !resp_complete_q) begin
        if (int'(resp_len_q) < MAXB)
          resp_buf[resp_len_q[BW-1:0]] <= xfcp_tx_data_i;
        if (int'(resp_len_q) < MAXB) resp_len_q <= resp_len_q + 1'b1;
        if (xfcp_tx_last_i) resp_complete_q <= 1'b1;
      end

      // ====================================================================
      // TX FSM: resp_buf -> IPv4 TX
      // ====================================================================
      case (tx_state_q)

        TX_IDLE: begin
          if (resp_complete_q) begin
            tx_dst_mac_q     <= src_mac_q;
            tx_dst_ip_q      <= src_ip_q;
            tx_dst_p0_q      <= src_p0_q;
            tx_dst_p1_q      <= src_p1_q;
            tx_resp_len_q    <= resp_len_q;
            tx_payload_len_q <= 16'd8 + 16'(resp_len_q);
            tx_hdr_cnt_q     <= 3'd0;
            tx_rd_q          <= '0;
            tx_state_q       <= TX_META;
          end
        end

        TX_META: begin
          if (m_meta_valid_o && m_meta_ready_i) tx_state_q <= TX_HDR;
        end

        TX_HDR: begin
          if (tx_fire_w) begin
            if (tx_hdr_cnt_q == 3'd7) begin
              if (tx_resp_len_q == '0) begin
                resp_complete_q <= 1'b0;
                resp_len_q      <= '0;
                tx_state_q      <= TX_IDLE;
              end else begin
                tx_state_q <= TX_DATA;
              end
            end else begin
              tx_hdr_cnt_q <= tx_hdr_cnt_q + 3'd1;
            end
          end
        end

        TX_DATA: begin
          if (tx_fire_w) begin
            if (tx_rd_q == tx_resp_len_q - 1'b1) begin
              resp_complete_q <= 1'b0;
              resp_len_q      <= '0;
              tx_state_q      <= TX_IDLE;
            end else begin
              tx_rd_q <= tx_rd_q + 1'b1;
            end
          end
        end

        default: tx_state_q <= TX_IDLE;
      endcase

    end
  end

  // =========================================================================
  // Output assignments
  // =========================================================================

  assign xfcp_rx_valid_o = (out_state_q == OUT_SEND);
  assign xfcp_rx_data_o  = out_rx_data_r;
  assign xfcp_rx_last_o  = (out_state_q == OUT_SEND) &&
                           (out_len_q != '0) &&
                           (out_rd_q == out_len_q - 1'b1);

  assign xfcp_tx_ready_o = !resp_complete_q;

  assign m_meta_valid_o       = (tx_state_q == TX_META);
  assign m_meta_proto_o       = 8'h11;
  assign m_meta_dst_ip_o      = tx_dst_ip_q;
  assign m_meta_dst_mac_o     = tx_dst_mac_q;
  assign m_meta_payload_len_o = tx_payload_len_q;

  assign m_axis_tvalid_o = (tx_state_q == TX_HDR) || (tx_state_q == TX_DATA);
  assign m_axis_tdata_o  = (tx_state_q == TX_HDR) ? tx_hdr_byte_w : tx_data_r;
  assign m_axis_tlast_o  = ((tx_state_q == TX_HDR) &&
                             (tx_hdr_cnt_q == 3'd7) && (tx_resp_len_q == '0)) ||
                           ((tx_state_q == TX_DATA) &&
                             (tx_rd_q == tx_resp_len_q - 1'b1));
  assign m_axis_tuser_o  = 1'b0;

endmodule

`default_nettype wire

`endif // UDP_XFCP_SERVER_SV
