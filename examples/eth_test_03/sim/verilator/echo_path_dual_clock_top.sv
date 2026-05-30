/**
 * @file echo_path_dual_clock_top.sv
 * @brief Dual-clock UDP echo path: RX domain -> async FIFO CDC -> TX domain.
 * @details All modules from gmii_rx_mac through udp_ipv4_tx_builder run in the
 *   RX clock domain. gmii_tx_mac runs in the TX clock domain. Two async FIFOs
 *   bridge the domains:
 *     pkt_fifo  (9-bit, 2048 deep): {tlast, tdata} stream from tx_builder.
 *     meta_fifo (96-bit, 4 deep):   {dst_mac, src_mac} written after last byte.
 *
 *   The TX controller (tx_clk domain) waits for meta_fifo to be non-empty,
 *   then starts gmii_tx_mac and streams from pkt_fifo.
 *
 *   meta_fifo is written only after the complete packet is in pkt_fifo, so the
 *   TX controller can start immediately without underrun risk.
 */

`ifndef ECHO_PATH_DUAL_CLOCK_TOP_SV
`define ECHO_PATH_DUAL_CLOCK_TOP_SV

`default_nettype none

import eth_pkg::*;

module echo_path_dual_clock_top #(
  parameter logic [47:0] LOCAL_MAC  = 48'h000A3501FEC0,
  parameter logic [31:0] LOCAL_IP   = 32'hC0A80101,
  parameter logic [15:0] LOCAL_PORT = 16'd8080
)(
  input  wire logic        rx_clk_i,
  input  wire logic        tx_clk_i,
  input  wire logic        rst_ni,

  input  wire logic [7:0]  gmii_rxd_i,
  input  wire logic        gmii_rx_dv_i,
  input  wire logic        gmii_rx_er_i,

  output      logic [7:0]  gmii_txd_o,
  output      logic        gmii_tx_en_o,
  output      logic        gmii_tx_er_o,

  output      logic        eth_drop_o,
  output      logic        udp_drop_o
);

  // =========================================================================
  // RX CLOCK DOMAIN
  // =========================================================================

  // --- MAC -> L2 ---
  logic [7:0]  mac_tdata;
  logic        mac_tvalid, mac_tready, mac_tlast, mac_tuser;

  // --- L2 -> L3 ---
  logic [7:0]  eth_tdata;
  logic        eth_tvalid, eth_tready, eth_tlast;
  logic [47:0] eth_src_mac, eth_dst_mac;

  // --- L3 -> L4 ---
  logic [7:0]  ip_tdata;
  logic        ip_tvalid, ip_tready, ip_tlast;
  logic [31:0] ip_src, ip_dst;

  // --- L4 UDP parser -> echo app ---
  logic [7:0]  udp_tdata;
  logic        udp_tvalid, udp_tready, udp_tlast;
  logic [15:0] udp_src_port_pre, udp_dst_port_pre, udp_payload_len_pre;
  logic        udp_hdr_pre_valid;

  // --- Meta assembler -> echo app ---
  logic                      rx_meta_valid, rx_meta_ready;
  udp_packet_meta_t rx_meta;

  // --- Echo app -> TX builder ---
  logic                      tx_meta_valid, tx_meta_ready;
  udp_packet_meta_t tx_meta;
  logic [7:0]  echo_tdata;
  logic        echo_tvalid, echo_tready, echo_tlast;

  // --- TX builder -> pkt FIFO ---
  logic [7:0]  txb_tdata;
  logic        txb_tvalid, txb_tready, txb_tlast;

  // --- GMII RX MAC ---
  gmii_rx_mac u_mac (
    .clk_i        (rx_clk_i),
    .rst_ni       (rst_ni),
    .gmii_rxd_i   (gmii_rxd_i),
    .gmii_rx_dv_i (gmii_rx_dv_i),
    .gmii_rx_er_i (gmii_rx_er_i),
    .m_axis_tdata (mac_tdata),
    .m_axis_tvalid(mac_tvalid),
    .m_axis_tready(mac_tready),
    .m_axis_tlast (mac_tlast),
    .m_axis_tuser (mac_tuser),
    .frame_done_o ()
  );

  // --- Ethernet Header Parser (L2) ---
  eth_header_parser u_eth (
    .clk_i             (rx_clk_i),
    .rst_ni            (rst_ni),
    .local_mac_i       (LOCAL_MAC),
    .accept_broadcast_i(1'b0),
    .promiscuous_i     (1'b0),
    .s_axis_tdata      (mac_tdata),
    .s_axis_tvalid     (mac_tvalid),
    .s_axis_tready     (mac_tready),
    .s_axis_tlast      (mac_tlast),
    .s_axis_tuser      (mac_tuser),
    .m_axis_tdata      (eth_tdata),
    .m_axis_tvalid     (eth_tvalid),
    .m_axis_tready     (eth_tready),
    .m_axis_tlast      (eth_tlast),
    .m_axis_tuser      (),
    .rx_dst_mac_o      (eth_dst_mac),
    .rx_src_mac_o      (eth_src_mac),
    .rx_ethertype_o    (),
    .hdr_valid_o       (),
    .drop_o            (eth_drop_o)
  );

  // --- IPv4 Header Parser (L3) ---
  ipv4_header_parser u_ip (
    .clk_i        (rx_clk_i),
    .rst_ni       (rst_ni),
    .local_ip_i   (LOCAL_IP),
    .s_axis_tdata (eth_tdata),
    .s_axis_tvalid(eth_tvalid),
    .s_axis_tready(eth_tready),
    .s_axis_tlast (eth_tlast),
    .m_axis_tdata (ip_tdata),
    .m_axis_tvalid(ip_tvalid),
    .m_axis_tready(ip_tready),
    .m_axis_tlast (ip_tlast),
    .src_ip_o     (ip_src),
    .dst_ip_o     (ip_dst),
    .protocol_o   (),
    .hdr_valid_o  ()
  );

  // --- UDP Header Parser (L4) ---
  udp_header_parser #(.DROP_NONZERO_CHECKSUM(1'b0)) u_udp (
    .clk_i                   (rx_clk_i),
    .rst_ni                  (rst_ni),
    .local_port_i            (LOCAL_PORT),
    .promiscuous_i           (1'b0),
    .s_axis_tdata            (ip_tdata),
    .s_axis_tvalid           (ip_tvalid),
    .s_axis_tready           (ip_tready),
    .s_axis_tlast            (ip_tlast),
    .s_axis_tuser            (1'b0),
    .m_axis_tdata            (udp_tdata),
    .m_axis_tvalid           (udp_tvalid),
    .m_axis_tready           (udp_tready),
    .m_axis_tlast            (udp_tlast),
    .m_axis_tuser            (),
    .src_port_o              (),
    .dst_port_o              (),
    .udp_len_o               (),
    .payload_len_o           (),
    .hdr_valid_o             (),
    .hdr_pre_valid_o         (udp_hdr_pre_valid),
    .src_port_pre_o          (udp_src_port_pre),
    .dst_port_pre_o          (udp_dst_port_pre),
    .payload_len_pre_o       (udp_payload_len_pre),
    .drop_o                  (udp_drop_o),
    .udp_checksum_zero_o     (),
    .udp_checksum_unchecked_o()
  );

  // --- RX Metadata Assembler ---
  udp_rx_meta_assembler u_meta (
    .clk_i              (rx_clk_i),
    .rst_ni             (rst_ni),
    .eth_src_mac_i      (eth_src_mac),
    .eth_dst_mac_i      (eth_dst_mac),
    .ip_src_i           (ip_src),
    .ip_dst_i           (ip_dst),
    .udp_src_port_i     (udp_src_port_pre),
    .udp_dst_port_i     (udp_dst_port_pre),
    .udp_payload_len_i  (udp_payload_len_pre),
    .udp_hdr_pre_valid_i(udp_hdr_pre_valid),
    .rx_meta_valid_o    (rx_meta_valid),
    .rx_meta_ready_i    (rx_meta_ready),
    .rx_meta_o          (rx_meta)
  );

  // --- UDP Echo Application ---
  udp_echo_app u_echo (
    .clk_i          (rx_clk_i),
    .rst_ni         (rst_ni),
    .rx_meta_valid_i(rx_meta_valid),
    .rx_meta_ready_o(rx_meta_ready),
    .rx_meta_i      (rx_meta),
    .s_axis_tdata   (udp_tdata),
    .s_axis_tvalid  (udp_tvalid),
    .s_axis_tready  (udp_tready),
    .s_axis_tlast   (udp_tlast),
    .tx_meta_valid_o(tx_meta_valid),
    .tx_meta_ready_i(tx_meta_ready),
    .tx_meta_o      (tx_meta),
    .m_axis_tdata   (echo_tdata),
    .m_axis_tvalid  (echo_tvalid),
    .m_axis_tready  (echo_tready),
    .m_axis_tlast   (echo_tlast)
  );

  // --- UDP/IPv4 TX Builder ---
  udp_ipv4_tx_builder u_txb (
    .clk_i          (rx_clk_i),
    .rst_ni         (rst_ni),
    .tx_meta_valid_i(tx_meta_valid),
    .tx_meta_ready_o(tx_meta_ready),
    .tx_meta_i      (tx_meta),
    .s_axis_tdata   (echo_tdata),
    .s_axis_tvalid  (echo_tvalid),
    .s_axis_tready  (echo_tready),
    .s_axis_tlast   (echo_tlast),
    .m_axis_tdata   (txb_tdata),
    .m_axis_tvalid  (txb_tvalid),
    .m_axis_tready  (txb_tready),
    .m_axis_tlast   (txb_tlast),
    .ipv4_total_len_o()
  );

  // =========================================================================
  // CDC: packet FIFO (9-bit stream: {tlast, tdata}, 2048 entries)
  // =========================================================================
  // Written in rx_clk domain as tx_builder emits bytes.
  // Read  in tx_clk domain by TX controller -> gmii_tx_mac.

  logic       pkt_wr_ready;
  logic [8:0] pkt_rd_data;
  logic       pkt_rd_valid, pkt_rd_ready;

  assign txb_tready = pkt_wr_ready;

  async_fifo #(
    .DATA_WIDTH(9),
    .DEPTH     (2048)
  ) u_pkt_fifo (
    .wr_clk_i  (rx_clk_i),
    .wr_rst_ni (rst_ni),
    .wr_data_i ({txb_tlast, txb_tdata}),
    .wr_valid_i(txb_tvalid),
    .wr_ready_o(pkt_wr_ready),

    .rd_clk_i  (tx_clk_i),
    .rd_rst_ni (rst_ni),
    .rd_data_o (pkt_rd_data),
    .rd_valid_o(pkt_rd_valid),
    .rd_ready_i(pkt_rd_ready)
  );

  // =========================================================================
  // CDC: meta FIFO (96-bit: {dst_mac[47:0], src_mac[47:0]}, 4 entries)
  // Written after the last packet byte enters pkt_fifo.
  // =========================================================================

  // Latch tx_meta when tx_builder accepts it (handshake in rx_clk domain).
  logic [47:0] meta_latch_dst_q, meta_latch_src_q;

  always_ff @(posedge rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      meta_latch_dst_q <= '0;
      meta_latch_src_q <= '0;
    end else if (tx_meta_valid && tx_meta_ready) begin
      meta_latch_dst_q <= tx_meta.dst_mac;
      meta_latch_src_q <= tx_meta.src_mac;
    end
  end

  // Write meta FIFO when the last tx_builder byte is accepted into pkt_fifo.
  logic meta_wr_valid;
  logic meta_wr_ready;
  assign meta_wr_valid = txb_tvalid && pkt_wr_ready && txb_tlast;

  logic [95:0] meta_rd_data;
  logic        meta_rd_valid, meta_rd_ready;

  async_fifo #(
    .DATA_WIDTH(96),
    .DEPTH     (4)
  ) u_meta_fifo (
    .wr_clk_i  (rx_clk_i),
    .wr_rst_ni (rst_ni),
    .wr_data_i ({meta_latch_dst_q, meta_latch_src_q}),
    .wr_valid_i(meta_wr_valid),
    .wr_ready_o(meta_wr_ready),

    .rd_clk_i  (tx_clk_i),
    .rd_rst_ni (rst_ni),
    .rd_data_o (meta_rd_data),
    .rd_valid_o(meta_rd_valid),
    .rd_ready_i(meta_rd_ready)
  );

  // =========================================================================
  // TX CLOCK DOMAIN — TX controller + gmii_tx_mac
  // =========================================================================

  typedef enum logic [1:0] {
    TXC_IDLE  = 2'd0,
    TXC_START = 2'd1,
    TXC_DATA  = 2'd2
  } txc_state_e;

  txc_state_e txc_state_q;
  logic [47:0] txc_dst_mac_q, txc_src_mac_q;

  // gmii_tx_mac busy and backpressure signals.
  logic txmac_s_tready, tx_mac_busy_w;

  always_ff @(posedge tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      txc_state_q   <= TXC_IDLE;
      txc_dst_mac_q <= '0;
      txc_src_mac_q <= '0;
    end else begin
      case (txc_state_q)
        TXC_IDLE: begin
          // Wait for MAC to be idle (IFG finished) before starting next frame.
          if (meta_rd_valid && !tx_mac_busy_w) begin
            // Pop meta FIFO and latch MACs (meta_rd_ready fires this cycle).
            txc_dst_mac_q <= meta_rd_data[95:48];
            txc_src_mac_q <= meta_rd_data[47:0];
            txc_state_q   <= TXC_START;
          end
        end
        TXC_START: begin
          // tx_start_i pulsed combinatorially; MACs are now latched.
          txc_state_q <= TXC_DATA;
        end
        TXC_DATA: begin
          // Stream until tlast byte consumed.
          if (pkt_rd_valid && txmac_s_tready && pkt_rd_data[8])
            txc_state_q <= TXC_IDLE;
        end
        default: txc_state_q <= TXC_IDLE;
      endcase
    end
  end

  // Pop meta FIFO only when MAC is free (same condition as TXC_IDLE transition).
  assign meta_rd_ready = (txc_state_q == TXC_IDLE) && meta_rd_valid && !tx_mac_busy_w;

  // Connect pkt FIFO to gmii_tx_mac s_axis.
  assign pkt_rd_ready = (txc_state_q == TXC_DATA) && txmac_s_tready;

  logic [7:0] txmac_s_tdata;
  logic       txmac_s_tvalid, txmac_s_tlast;
  assign txmac_s_tdata  = pkt_rd_data[7:0];
  assign txmac_s_tlast  = pkt_rd_data[8];
  assign txmac_s_tvalid = pkt_rd_valid && (txc_state_q == TXC_DATA);

  // --- GMII TX MAC ---
  gmii_tx_mac u_tx_mac (
    .clk_i         (tx_clk_i),
    .rst_ni        (rst_ni),
    .tx_dst_mac_i  (txc_dst_mac_q),
    .tx_src_mac_i  (txc_src_mac_q),
    .tx_ethertype_i(16'h0800),
    .tx_start_i    (txc_state_q == TXC_START),
    .tx_busy_o     (tx_mac_busy_w),
    .tx_done_o     (),
    .s_axis_tdata  (txmac_s_tdata),
    .s_axis_tvalid (txmac_s_tvalid),
    .s_axis_tready (txmac_s_tready),
    .s_axis_tlast  (txmac_s_tlast),
    .gmii_txd_o    (gmii_txd_o),
    .gmii_tx_en_o  (gmii_tx_en_o),
    .gmii_tx_er_o  (gmii_tx_er_o)
  );

endmodule

`endif // ECHO_PATH_DUAL_CLOCK_TOP_SV
