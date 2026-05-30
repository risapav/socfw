/**
 * @file rx_path_top.sv
 * @brief Verilator integration wrapper: gmii_rx_mac → eth_header_parser →
 *   ipv4_header_parser → udp_header_parser chained in series.
 * @details Exposes GMII input and UDP payload AXI-Stream output plus
 *   per-layer status signals for testbench verification.
 *   LOCAL_MAC, LOCAL_IP, LOCAL_PORT are compile-time parameters.
 */

`ifndef RX_PATH_TOP_SV
`define RX_PATH_TOP_SV

`default_nettype none

module rx_path_top #(
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

  // UDP payload AXI-Stream output
  output      logic [7:0]  udp_tdata_o,
  output      logic        udp_tvalid_o,
  input  wire logic        udp_tready_i,
  output      logic        udp_tlast_o,

  // Per-layer status (for testbench assertions)
  output      logic        eth_hdr_valid_o,
  output      logic        eth_drop_o,
  output      logic        ip_hdr_valid_o,
  output      logic        udp_hdr_valid_o,
  output      logic        udp_drop_o,
  output      logic [15:0] udp_src_port_o,
  output      logic [15:0] udp_dst_port_o,
  output      logic [15:0] udp_payload_len_o
);

  // MAC → L2 signals
  logic [7:0] mac_tdata;
  logic       mac_tvalid, mac_tready, mac_tlast, mac_tuser;

  // L2 → L3 signals
  logic [7:0] eth_tdata;
  logic       eth_tvalid, eth_tready, eth_tlast;

  // L3 → L4 signals
  logic [7:0] ip_tdata;
  logic       ip_tvalid, ip_tready, ip_tlast;

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
    .accept_broadcast_i(1'b1),
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
    .rx_dst_mac_o      (),
    .rx_src_mac_o      (),
    .rx_ethertype_o    (),
    .hdr_valid_o       (eth_hdr_valid_o),
    .drop_o            (eth_drop_o)
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
    .src_ip_o     (),
    .dst_ip_o     (),
    .protocol_o   (),
    .hdr_valid_o  (ip_hdr_valid_o)
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
    .m_axis_tdata            (udp_tdata_o),
    .m_axis_tvalid           (udp_tvalid_o),
    .m_axis_tready           (udp_tready_i),
    .m_axis_tlast            (udp_tlast_o),
    .m_axis_tuser            (),
    .src_port_o              (udp_src_port_o),
    .dst_port_o              (udp_dst_port_o),
    .udp_len_o               (),
    .payload_len_o           (udp_payload_len_o),
    .hdr_valid_o             (udp_hdr_valid_o),
    .hdr_pre_valid_o         (),
    .src_port_pre_o          (),
    .dst_port_pre_o          (),
    .payload_len_pre_o       (),
    .drop_o                  (udp_drop_o),
    .udp_checksum_zero_o     (),
    .udp_checksum_unchecked_o()
  );

endmodule

`endif // RX_PATH_TOP_SV
