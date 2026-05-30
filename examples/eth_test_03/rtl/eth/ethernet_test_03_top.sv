/**
 * @file ethernet_test_03_top.sv
 * @brief Top-level module for UDP Echo test.
 * @details Integrates GMII MAC, L2/L3/L4 parsers and the Echo application.
 */

`ifndef ETHERNET_TEST_03_TOP_SV
`define ETHERNET_TEST_03_TOP_SV

`default_nettype none

module ethernet_test_03_top #(
  parameter logic [47:0] LOCAL_MAC = 48'h000A3501FEC0,
  parameter logic [31:0] LOCAL_IP  = 32'hC0A81432,
  parameter logic [15:0] UDP_PORT  = 16'd8080
)(
  input  wire logic        sys_clk_i,
  input  wire logic        eth_rx_clk_i,
  input  wire logic        eth_tx_clk_i,
  input  wire logic        rst_ni,

  // GMII Physical Interface
  input  wire logic [7:0]  eth_rxd_i,
  input  wire logic        eth_rxdv_i,
  input  wire logic        eth_rxer_i,
  output      logic [7:0]  eth_txd_o,
  output      logic        eth_txen_o,
  output      logic        eth_txer_o,
  output      logic        eth_gtx_clk_o,

  output      logic [5:0]  led_o
);

  // Interné AXI-Stream signály (zjednodušené prepojenia)
  logic [7:0] rx_axis_tdata, eth_axis_tdata, ip_axis_tdata, udp_axis_tdata;
  logic       rx_axis_tvalid, eth_axis_tvalid, ip_axis_tvalid, udp_axis_tvalid;
  logic       rx_axis_tready, eth_axis_tready, ip_axis_tready, udp_axis_tready;
  logic       rx_axis_tlast, eth_axis_tlast, ip_axis_tlast, udp_axis_tlast;

  // Clock a reset
  assign eth_gtx_clk_o = eth_tx_clk_i;

  // 1. GMII RX
  gmii_rx_mac u_rx_mac (
    .clk_i(eth_rx_clk_i), .rst_ni,
    .gmii_rxd_i(eth_rxd_i), .gmii_rx_dv_i(eth_rxdv_i), .gmii_rx_er_i(eth_rxer_i),
    .m_axis_tdata(rx_axis_tdata), .m_axis_tvalid(rx_axis_tvalid),
    .m_axis_tready(rx_axis_tready), .m_axis_tlast(rx_axis_tlast),
    .m_axis_tuser(1'b0), .frame_done_o()
  );

  // 2. Ethernet Parser (L2)
  eth_header_parser u_eth_parser (
    .clk_i(eth_rx_clk_i), .rst_ni,
    .local_mac_i(LOCAL_MAC), .accept_broadcast_i(1'b1), .promiscuous_i(1'b0),
    .s_axis_tdata(rx_axis_tdata), .s_axis_tvalid(rx_axis_tvalid), .s_axis_tready(rx_axis_tready),
    .s_axis_tlast(rx_axis_tlast), .s_axis_tuser(1'b0),
    .m_axis_tdata(eth_axis_tdata), .m_axis_tvalid(eth_axis_tvalid), .m_axis_tready(eth_axis_tready),
    .m_axis_tlast(eth_axis_tlast), .m_axis_tuser(),
    .rx_dst_mac_o(), .rx_src_mac_o(), .rx_ethertype_o(), .hdr_valid_o(), .drop_o()
  );

  // 3. IPv4 Parser (L3)
  ipv4_header_parser u_ip_parser (
    .clk_i(eth_rx_clk_i), .rst_ni,
    .local_ip_i(LOCAL_IP),
    .s_axis_tdata(eth_axis_tdata), .s_axis_tvalid(eth_axis_tvalid), .s_axis_tready(eth_axis_tready),
    .s_axis_tlast(eth_axis_tlast),
    .m_axis_tdata(ip_axis_tdata), .m_axis_tvalid(ip_axis_tvalid), .m_axis_tready(ip_axis_tready),
    .m_axis_tlast(ip_axis_tlast),
    .src_ip_o(), .dst_ip_o(), .protocol_o(), .hdr_valid_o()
  );

  // 4. UDP Echo App (Aplikácia) - Tu by bolo napojenie na parsery
  // ... implementácia UDP parsera a Echo App ...

  // 5. Debug LEDs
  eth_debug_leds u_leds (
    .sys_clk_i, .rst_ni,
    .phy_reset_done_i(1'b1), .rx_dv_seen_i(eth_rxdv_i),
    .rx_frame_ok_i(1'b0), .rx_frame_drop_i(1'b0),
    .tx_start_i(1'b0), .tx_en_seen_i(eth_txen_o),
    .led_o(led_o)
  );

endmodule

`endif // ETHERNET_TEST_03_TOP_SV
