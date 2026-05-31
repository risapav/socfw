/**
 * @file echo_path_top.sv
 * @brief Verilator single-clock full UDP echo path wrapper.
 * @details Chains all modules from GMII RX to GMII TX:
 *   gmii_rx_mac -> eth_header_parser -> ipv4_header_parser ->
 *   udp_header_parser -> udp_rx_meta_assembler -> udp_echo_app ->
 *   udp_ipv4_tx_builder -> gmii_tx_mac
 *
 * Single clock domain — suitable for functional verification before CDC.
 * LOCAL_MAC, LOCAL_IP, LOCAL_PORT are compile-time parameters.
 */

`ifndef ECHO_PATH_TOP_SV
`define ECHO_PATH_TOP_SV

`default_nettype none

import eth_pkg::*;

module echo_path_top #(
  parameter logic [47:0] LOCAL_MAC  = 48'h000A3501FEC0,
  parameter logic [31:0] LOCAL_IP   = 32'hC0A80101,
  parameter logic [15:0] LOCAL_PORT = 16'd8080
)(
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // GMII RX input
  input  wire logic [7:0]  gmii_rxd_i,
  input  wire logic        gmii_rx_dv_i,
  input  wire logic        gmii_rx_er_i,

  // GMII TX output
  output      logic [7:0]  gmii_txd_o,
  output      logic        gmii_tx_en_o,
  output      logic        gmii_tx_er_o,

  // Debug: per-layer status
  output      logic        eth_drop_o,
  output      logic        udp_drop_o,
  output      logic        echo_busy_o
);

  // --- MAC -> L2 ---
  logic [7:0] mac_tdata;
  logic       mac_tvalid, mac_tready, mac_tlast, mac_tuser;

  // --- L2 -> L3 ---
  logic [7:0] eth_tdata;
  logic       eth_tvalid, eth_tready, eth_tlast;
  logic [47:0] eth_src_mac, eth_dst_mac;

  // --- L3 -> L4 ---
  logic [7:0] ip_tdata;
  logic       ip_tvalid, ip_tready, ip_tlast;
  logic [31:0] ip_src, ip_dst;

  // --- L4 UDP parser -> echo app ---
  logic [7:0] udp_tdata;
  logic       udp_tvalid, udp_tready, udp_tlast;
  logic [15:0] udp_src_port_pre, udp_dst_port_pre, udp_payload_len_pre;
  logic        udp_hdr_pre_valid;

  // --- Meta assembler -> echo app ---
  logic                          rx_meta_valid, rx_meta_ready;
  udp_packet_meta_t     rx_meta;

  // --- Echo app -> TX builder ---
  logic                          tx_meta_valid, tx_meta_ready;
  udp_packet_meta_t     tx_meta;
  logic [7:0] echo_tdata;
  logic       echo_tvalid, echo_tready, echo_tlast;

  // --- TX builder -> GMII TX MAC ---
  logic [7:0] txb_tdata;
  logic       txb_tvalid, txb_tready, txb_tlast;

  // --- GMII RX MAC ---
  gmii_rx_mac u_mac (
    .clk_i        (clk_i),
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
    .clk_i             (clk_i),
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
    .drop_o            (eth_drop_o),
    .hdr_done_pulse_o  (),
    .hdr_accept_pulse_o(),
    .hdr_drop_pulse_o  (),
    .dbg_dst_mac_o     (),
    .dbg_mac_accept_o  ()
  );

  // --- IPv4 Header Parser (L3) ---
  ipv4_header_parser u_ip (
    .clk_i        (clk_i),
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
    .clk_i                   (clk_i),
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
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .eth_src_mac_i      (eth_src_mac),
    .eth_dst_mac_i      (eth_dst_mac),
    .ip_src_i           (ip_src),
    .ip_dst_i           (ip_dst),
    .udp_src_port_i     (udp_src_port_pre),
    .udp_dst_port_i     (udp_dst_port_pre),
    .udp_payload_len_i  (udp_payload_len_pre),
    .udp_hdr_pre_valid_i(udp_hdr_pre_valid),
    .rx_meta_valid_o (rx_meta_valid),
    .rx_meta_ready_i (rx_meta_ready),
    .rx_meta_o       (rx_meta)
  );

  // --- UDP Echo Application ---
  udp_echo_app u_echo (
    .clk_i          (clk_i),
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

  assign echo_busy_o = (tx_meta_valid || echo_tvalid);

  // --- UDP/IPv4 TX Builder ---
  udp_ipv4_tx_builder u_txb (
    .clk_i          (clk_i),
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

  // --- GMII TX MAC ---
  // tx_start_i fires when tx_meta handshake completes (builder accepts meta).
  // Ethernet header fields come from tx_meta (echo_app has already swapped src/dst).
  gmii_tx_mac u_tx_mac (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tx_dst_mac_i (tx_meta.dst_mac),
    .tx_src_mac_i (tx_meta.src_mac),
    .tx_ethertype_i(16'h0800),
    .tx_start_i   (tx_meta_valid && tx_meta_ready),
    .tx_busy_o    (),
    .tx_done_o    (),
    .s_axis_tdata (txb_tdata),
    .s_axis_tvalid(txb_tvalid),
    .s_axis_tready(txb_tready),
    .s_axis_tlast (txb_tlast),
    .gmii_txd_o   (gmii_txd_o),
    .gmii_tx_en_o (gmii_tx_en_o),
    .gmii_tx_er_o (gmii_tx_er_o)
  );

endmodule

`endif // ECHO_PATH_TOP_SV
