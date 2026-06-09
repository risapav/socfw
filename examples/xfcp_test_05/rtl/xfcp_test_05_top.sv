/**
 * @file xfcp_test_05_top.sv
 * @brief XFCP switch s dvoma nezavislymi vstupmi: UART a ETH-UDP.
 * @param LOCAL_MAC  48-bit FPGA MAC adresa.
 * @param LOCAL_IP   32-bit FPGA IP adresa.
 * @param XFCP_PORT  UDP port pre XFCP komunikaciu (default 50000).
 * @param CLOCK_HZ   Frekvencia systemoveho taktu clk_i (125 MHz).
 * @param UART_DEFAULT_BAUD_DIV  Predvolena hodnota baud prescalera.
 * @details
 *   Systemovy takt: clk_i = 125 MHz (z PLL, inclk0=50MHz, c0=125MHz).
 *   ETH RX domena: eth_rx_clk_i (125 MHz z PHY, asynchronna k clk_i).
 *
 *   Architektura:
 *     ETH RX (eth_rx_clk):
 *       gmii_rx -> altddio_in -> eth_rx_mac -> [async FIFO] ->
 *     ETH TX (clk_i):
 *       -> TX dispatcher -> eth_type_demux
 *          ARP:  arp_rx -> arp_tx -> arb0 -> eth_tx_mac
 *          IPv4: ipv4_rx -> icmp_echo -> ipv4_tx -> arb1 -> eth_tx_mac
 *                        -> udp_xfcp (Faza B) -> arb2 -> eth_tx_mac
 *     UART (clk_i):
 *       axis_uart_rx -> xfcp_fifo -> xfcp_arbiter_2to1.s0
 *       xfcp_arbiter_2to1.m0 -> axis_skid -> axis_uart_tx
 *     ETH-UDP XFCP (clk_i, Faza B):
 *       udp_xfcp_server -> xfcp_arbiter_2to1.s1
 *       xfcp_arbiter_2to1.m1 -> udp_tx -> ipv4_tx
 *     XFCP switch (clk_i):
 *       xfcp_arbiter_2to1.m -> xfcp_fabric_endpoint -> AXI-Lite slaves
 *
 *   AXI-Lite mapa (stride 0x10000):
 *     Slot 0 @ 0xFF000000 : axil_sys_ctrl    (ID "SYSC")
 *     Slot 1 @ 0xFF010000 : axil_uart_adapter (ID "UART")
 *     Slot 2 @ 0xFF020000 : axil_regs / LED onboard 6-bit
 *     Slot 3 @ 0xFF030000 : axil_regs / PMOD J10 8-bit
 *     Slot 4 @ 0xFF040000 : axil_regs / PMOD J11 8-bit
 *     Slot 5 @ 0xFF050000 : axil_seven_seg_adapter
 *     Slot 6 @ 0xFF060000 : axil_diag_ctrl
 */

`ifndef XFCP_TEST_05_TOP_SV
`define XFCP_TEST_05_TOP_SV

`default_nettype none

import axi_pkg::*;
import uart_pkg::*;
import xfcp_pkg::*;

module xfcp_test_05_top #(
  parameter logic [47:0] LOCAL_MAC             = 48'h00_0A_35_01_FE_C5,
  parameter logic [31:0] LOCAL_IP              = 32'hC0A8_0005,
  parameter logic [15:0] XFCP_PORT             = 16'd50000,
  parameter int          CLOCK_HZ              = 125_000_000,
  parameter int          UART_DEFAULT_BAUD_DIV = 1085  // 125 MHz / 115200
)(
  input  wire logic        clk_i,         // 125 MHz z PLL
  input  wire logic        rst_ni,

  // GMII RX (125 MHz z PHY, asynchronne k clk_i)
  input  wire logic        eth_rx_clk_i,
  input  wire logic        eth_rxdv_i,
  input  wire logic        eth_rxer_i,
  input  wire logic [7:0]  eth_rxd_i,

  // GMII TX (clk_i domain, GTX_CLK ako DDR output)
  output      logic        eth_gtx_clk_o,
  output      logic        eth_txen_o,
  output      logic        eth_txer_o,
  output      logic [7:0]  eth_txd_o,

  // PHY management
  output      logic        eth_phyrstb_o,
  output      logic        eth_mdc_o,
  inout       wire  logic  eth_mdio_io,

  // UART (clk_i domain)
  input  wire logic        uart_rx_i,
  output      logic        uart_tx_o,

  // Onboard a PMOD periferals
  output      logic [5:0]  led_o,
  output      logic [7:0]  pmod_j10_o,
  output      logic [7:0]  pmod_j11_o,
  output      logic [7:0]  seg_o,
  output      logic [2:0]  dig_o,
  input  wire logic [3:0]  btn_i
);

  // ===== Reset kombinácia: HW reset + tlačidlo btn_i[3] =====================
  logic rst_w;
  assign rst_w = rst_ni && btn_i[3];

  // ===== TX domain reset sync (async assert, sync deassert) =================
  logic [1:0] rst_tx_sync_q;
  logic       rst_tx_w;
  always_ff @(posedge clk_i or negedge rst_w) begin
    if (!rst_w) rst_tx_sync_q <= 2'b00;
    else        rst_tx_sync_q <= {rst_tx_sync_q[0], 1'b1};
  end
  assign rst_tx_w = rst_tx_sync_q[1];

  // ===== PHY reset: 25-bit counter @ 125 MHz => ~268 ms =====================
  logic [24:0] phy_rst_cnt_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) phy_rst_cnt_q <= '0;
    else if (!(&phy_rst_cnt_q)) phy_rst_cnt_q <= phy_rst_cnt_q + 25'd1;
  end
  assign eth_phyrstb_o = &phy_rst_cnt_q;
  assign eth_mdc_o     = 1'b0;
  assign eth_mdio_io   = 1'bz;

  // ===== GTX_CLK: altddio_out, invert_output="ON" ===========================
`ifdef SYNTHESIS
  altddio_out #(
    .extend_oe_disable      ("OFF"),
    .intended_device_family ("Cyclone IV E"),
    .invert_output          ("ON"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_out"),
    .oe_reg                 ("UNREGISTERED"),
    .power_up_high          ("OFF"),
    .width                  (1)
  ) u_gtx_ddr (
    .datain_h   (1'b1),
    .datain_l   (1'b0),
    .outclock   (clk_i),
    .dataout    (eth_gtx_clk_o),
    .aclr       (1'b0), .aset (1'b0),
    .oe         (1'b1), .oe_out (),
    .outclocken (1'b1), .sclr  (1'b0), .sset (1'b0)
  );
`else
  assign eth_gtx_clk_o = clk_i;
`endif

  // ===== GMII RX: altddio_in, invert_input_clocks="ON" ======================
  logic [7:0] rxd_s_w;
  logic       rxdv_s_w;
  logic       rxer_s_w;

`ifdef SYNTHESIS
  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_in"),
    .width                  (8)
  ) u_rxd_ddr (
    .datain    (eth_rxd_i),  .inclock   (eth_rx_clk_i),
    .dataout_h (rxd_s_w),    .dataout_l (),
    .aclr (1'b0), .aset (1'b0), .inclocken (1'b1), .sclr (1'b0), .sset (1'b0)
  );
  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_in"),
    .width                  (1)
  ) u_rxdv_ddr (
    .datain    (eth_rxdv_i), .inclock   (eth_rx_clk_i),
    .dataout_h (rxdv_s_w),   .dataout_l (),
    .aclr (1'b0), .aset (1'b0), .inclocken (1'b1), .sclr (1'b0), .sset (1'b0)
  );
  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_in"),
    .width                  (1)
  ) u_rxer_ddr (
    .datain    (eth_rxer_i), .inclock   (eth_rx_clk_i),
    .dataout_h (rxer_s_w),   .dataout_l (),
    .aclr (1'b0), .aset (1'b0), .inclocken (1'b1), .sclr (1'b0), .sset (1'b0)
  );
`else
  assign rxd_s_w  = eth_rxd_i;
  assign rxdv_s_w = eth_rxdv_i;
  assign rxer_s_w = eth_rxer_i;
`endif

  // =========================================================================
  // ETH RX MAC (eth_rx_clk_i domain)
  // =========================================================================
  logic [7:0]  rx_tdata_w;
  logic        rx_tvalid_w, rx_tready_w, rx_tlast_w, rx_tuser_w;
  logic        rx_meta_valid_w, rx_meta_ready_w;
  logic [47:0] rx_meta_dst_mac_w, rx_meta_src_mac_w;
  logic [15:0] rx_meta_eth_type_w, rx_stat_frames_w;
  logic        rx_meta_fcs_ok_w, rx_meta_mac_ok_w;

  eth_rx_mac #(
    .LOCAL_MAC       (LOCAL_MAC),
    .ACCEPT_BROADCAST(1'b1),
    .ACCEPT_MULTICAST(1'b0),
    .MAX_FRAME_LEN   (1518)
  ) u_rx_mac (
    .clk_i           (eth_rx_clk_i),
    .rst_ni          (rst_w),
    .gmii_rx_dv_i    (rxdv_s_w),
    .gmii_rx_er_i    (rxer_s_w),
    .gmii_rxd_i      (rxd_s_w),
    .m_axis_tdata    (rx_tdata_w),
    .m_axis_tvalid   (rx_tvalid_w),
    .m_axis_tready   (rx_tready_w),
    .m_axis_tlast    (rx_tlast_w),
    .m_axis_tuser    (rx_tuser_w),
    .m_hdr_valid_o   (), .m_hdr_dst_mac_o (), .m_hdr_src_mac_o (),
    .m_hdr_eth_type_o(), .m_hdr_mac_ok_o  (),
    .m_meta_valid    (rx_meta_valid_w),
    .m_meta_ready    (rx_meta_ready_w),
    .m_meta_dst_mac  (rx_meta_dst_mac_w),
    .m_meta_src_mac  (rx_meta_src_mac_w),
    .m_meta_eth_type (rx_meta_eth_type_w),
    .m_meta_fcs_ok   (rx_meta_fcs_ok_w),
    .m_meta_mac_ok   (rx_meta_mac_ok_w),
    .stat_overflow   (),
    .stat_rx_frames  (rx_stat_frames_w),
    .stat_rx_drop    ()
  );

  // =========================================================================
  // Async FIFOs: eth_rx_clk_i -> clk_i (125 MHz PHY -> 125 MHz PLL)
  // Hoci obe su 125 MHz, su asynchronne (rozne PLL).
  // =========================================================================
  localparam int PAYLOAD_W = 10;  // {tuser[1], tlast[1], tdata[8]}
  localparam int META_W    = 113; // {fcs_ok[1], dst_mac[48], src_mac[48], eth_type[16]}

  logic [PAYLOAD_W-1:0] pfifo_wr_w, pfifo_rd_w;
  logic                 pfifo_wr_ready_w, pfifo_rd_valid_w, pfifo_rd_ready_w;
  logic [7:0]  pfifo_tdata_w;
  logic        pfifo_tlast_w, pfifo_tuser_w;

  assign pfifo_wr_w = {rx_tuser_w, rx_tlast_w, rx_tdata_w};
  assign {pfifo_tuser_w, pfifo_tlast_w, pfifo_tdata_w} = pfifo_rd_w;
  assign rx_tready_w = pfifo_wr_ready_w;

  logic [META_W-1:0] mfifo_wr_w, mfifo_rd_w;
  logic              mfifo_wr_ready_w, mfifo_rd_valid_w, mfifo_rd_ready_w;
  logic        meta_fcs_ok_w;
  logic [47:0] meta_dst_mac_w, meta_src_mac_w;
  logic [15:0] meta_eth_type_w;

  assign mfifo_wr_w = {rx_meta_fcs_ok_w, rx_meta_dst_mac_w,
                       rx_meta_src_mac_w, rx_meta_eth_type_w};
  assign rx_meta_ready_w = mfifo_wr_ready_w;
  assign {meta_fcs_ok_w, meta_dst_mac_w,
          meta_src_mac_w, meta_eth_type_w} = mfifo_rd_w;

  async_fifo #(.DATA_WIDTH(PAYLOAD_W), .DEPTH(2048)) u_payload_fifo (
    .wr_clk_i  (eth_rx_clk_i), .wr_rst_ni (rst_w),
    .wr_data_i (pfifo_wr_w),   .wr_valid_i(rx_tvalid_w),
    .wr_ready_o(pfifo_wr_ready_w),
    .rd_clk_i  (clk_i),        .rd_rst_ni (rst_tx_w),
    .rd_data_o (pfifo_rd_w),   .rd_valid_o(pfifo_rd_valid_w),
    .rd_ready_i(pfifo_rd_ready_w)
  );

  async_fifo #(.DATA_WIDTH(META_W), .DEPTH(8)) u_meta_fifo (
    .wr_clk_i  (eth_rx_clk_i), .wr_rst_ni (rst_w),
    .wr_data_i (mfifo_wr_w),   .wr_valid_i(rx_meta_valid_w),
    .wr_ready_o(mfifo_wr_ready_w),
    .rd_clk_i  (clk_i),        .rd_rst_ni (rst_tx_w),
    .rd_data_o (mfifo_rd_w),   .rd_valid_o(mfifo_rd_valid_w),
    .rd_ready_i(mfifo_rd_ready_w)
  );

  // =========================================================================
  // TX dispatcher FSM (clk_i domain)
  // =========================================================================
  typedef enum logic [1:0] {
    D_IDLE   = 2'd0,
    D_ROUTE  = 2'd1,
    D_STREAM = 2'd2
  } disp_state_e;

  disp_state_e disp_state_q;

  always_ff @(posedge clk_i or negedge rst_tx_w) begin
    if (!rst_tx_w) disp_state_q <= D_IDLE;
    else begin
      case (disp_state_q)
        D_IDLE:   if (mfifo_rd_valid_w) disp_state_q <= D_ROUTE;
        D_ROUTE:  disp_state_q <= D_STREAM;
        D_STREAM: if (pfifo_rd_valid_w && pfifo_tlast_w) disp_state_q <= D_IDLE;
        default:  disp_state_q <= D_IDLE;
      endcase
    end
  end

  assign mfifo_rd_ready_w = (disp_state_q == D_ROUTE);
  assign pfifo_rd_ready_w = (disp_state_q == D_STREAM);

  logic        demux_hdr_valid_w;
  logic [47:0] demux_hdr_dst_mac_w, demux_hdr_src_mac_w;
  logic [15:0] demux_hdr_eth_type_w;
  logic        demux_hdr_mac_ok_w;
  logic [7:0]  demux_tdata_w;
  logic        demux_tvalid_w, demux_tlast_w, demux_tuser_w;

  assign demux_hdr_valid_w    = (disp_state_q == D_ROUTE);
  assign demux_hdr_dst_mac_w  = meta_dst_mac_w;
  assign demux_hdr_src_mac_w  = meta_src_mac_w;
  assign demux_hdr_eth_type_w = meta_eth_type_w;
  assign demux_hdr_mac_ok_w   = meta_fcs_ok_w;
  assign demux_tdata_w        = pfifo_tdata_w;
  assign demux_tvalid_w       = pfifo_rd_valid_w && (disp_state_q == D_STREAM);
  assign demux_tlast_w        = pfifo_tlast_w;
  assign demux_tuser_w        = pfifo_tuser_w;

  // =========================================================================
  // eth_type_demux: ARP (port0) + IPv4 (port1)
  // =========================================================================
  logic [7:0]  arp0_tdata_w;
  logic        arp0_tvalid_w, arp0_tlast_w, arp0_tuser_w;
  logic [7:0]  ip1_tdata_w;
  logic        ip1_tvalid_w, ip1_tlast_w, ip1_tuser_w;
  logic        ip1_hdr_valid_w;
  logic [47:0] ip1_hdr_src_mac_w;

  eth_type_demux #(.ETH_TYPE_0(16'h0806), .ETH_TYPE_1(16'h0800)) u_demux (
    .clk_i            (clk_i),
    .rst_ni           (rst_tx_w),
    .s_hdr_valid_i    (demux_hdr_valid_w),
    .s_hdr_dst_mac_i  (demux_hdr_dst_mac_w),
    .s_hdr_src_mac_i  (demux_hdr_src_mac_w),
    .s_hdr_eth_type_i (demux_hdr_eth_type_w),
    .s_hdr_mac_ok_i   (demux_hdr_mac_ok_w),
    .s_axis_tdata     (demux_tdata_w),
    .s_axis_tvalid    (demux_tvalid_w),
    .s_axis_tlast     (demux_tlast_w),
    .s_axis_tuser     (demux_tuser_w),
    .m0_axis_tdata    (arp0_tdata_w),
    .m0_axis_tvalid   (arp0_tvalid_w),
    .m0_axis_tlast    (arp0_tlast_w),
    .m0_axis_tuser    (arp0_tuser_w),
    .m0_hdr_valid     (), .m0_hdr_dst_mac (), .m0_hdr_src_mac (),
    .m1_axis_tdata    (ip1_tdata_w),
    .m1_axis_tvalid   (ip1_tvalid_w),
    .m1_axis_tlast    (ip1_tlast_w),
    .m1_axis_tuser    (ip1_tuser_w),
    .m1_hdr_valid     (ip1_hdr_valid_w),
    .m1_hdr_dst_mac   (),
    .m1_hdr_src_mac   (ip1_hdr_src_mac_w),
    .stat_routed_0    (), .stat_routed_1 (), .stat_dropped ()
  );

  logic [47:0] frame_src_mac_q;
  always_ff @(posedge clk_i or negedge rst_tx_w) begin
    if (!rst_tx_w) frame_src_mac_q <= '0;
    else if (ip1_hdr_valid_w) frame_src_mac_q <= ip1_hdr_src_mac_w;
  end

  // =========================================================================
  // ARP: arp_rx -> arp_tx -> eth_tx_arb port 0
  // =========================================================================
  logic        arp_req_valid_w, arp_req_ready_w;
  logic [47:0] arp_req_mac_w;
  logic [31:0] arp_req_ip_w;
  logic [15:0] arp_stat_rx_w, arp_stat_tx_w;

  arp_rx #(.LOCAL_IP(LOCAL_IP)) u_arp_rx (
    .clk_i            (clk_i),
    .rst_ni           (rst_tx_w),
    .s_axis_tdata     (arp0_tdata_w),
    .s_axis_tvalid    (arp0_tvalid_w),
    .s_axis_tlast     (arp0_tlast_w),
    .s_axis_tuser     (arp0_tuser_w),
    .m_valid_o        (arp_req_valid_w),
    .m_ready_i        (arp_req_ready_w),
    .m_requester_mac_o(arp_req_mac_w),
    .m_requester_ip_o (arp_req_ip_w),
    .stat_rx_requests (arp_stat_rx_w),
    .stat_rx_dropped  ()
  );

  logic        arb0_meta_valid_w, arb0_meta_ready_w;
  logic [47:0] arb0_meta_dst_mac_w, arb0_meta_src_mac_w;
  logic [15:0] arb0_meta_eth_type_w;
  logic [7:0]  arb0_tdata_w;
  logic        arb0_tvalid_w, arb0_tready_w, arb0_tlast_w, arb0_tuser_w;

  arp_tx #(.LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP)) u_arp_tx (
    .clk_i             (clk_i),
    .rst_ni            (rst_tx_w),
    .s_valid_i         (arp_req_valid_w),
    .s_ready_o         (arp_req_ready_w),
    .s_requester_mac_i (arp_req_mac_w),
    .s_requester_ip_i  (arp_req_ip_w),
    .m_meta_valid_o    (arb0_meta_valid_w),
    .m_meta_ready_i    (arb0_meta_ready_w),
    .m_meta_dst_mac_o  (arb0_meta_dst_mac_w),
    .m_meta_src_mac_o  (arb0_meta_src_mac_w),
    .m_meta_eth_type_o (arb0_meta_eth_type_w),
    .m_axis_tdata_o    (arb0_tdata_w),
    .m_axis_tvalid_o   (arb0_tvalid_w),
    .m_axis_tready_i   (arb0_tready_w),
    .m_axis_tlast_o    (arb0_tlast_w),
    .m_axis_tuser_o    (arb0_tuser_w),
    .stat_tx_replies   (arp_stat_tx_w)
  );

  // =========================================================================
  // IPv4 RX
  // =========================================================================
  logic [7:0]  l4_tdata_w;
  logic        l4_tvalid_w, l4_tlast_w, l4_tuser_w;
  logic        ipv4_hdr_valid_w;
  logic [7:0]  ipv4_hdr_proto_w;
  logic [31:0] ipv4_hdr_src_ip_w;
  logic        ipv4_hdr_accept_w;

  ipv4_rx #(.LOCAL_IP(LOCAL_IP), .PROMISCUOUS(1'b0)) u_ipv4_rx (
    .clk_i              (clk_i),
    .rst_ni             (rst_tx_w),
    .s_axis_tdata       (ip1_tdata_w),
    .s_axis_tvalid      (ip1_tvalid_w),
    .s_axis_tlast       (ip1_tlast_w),
    .s_axis_tuser       (ip1_tuser_w),
    .m_hdr_valid_o      (ipv4_hdr_valid_w),
    .m_hdr_proto_o      (ipv4_hdr_proto_w),
    .m_hdr_src_ip_o     (ipv4_hdr_src_ip_w),
    .m_hdr_dst_ip_o     (),
    .m_hdr_accept_o     (ipv4_hdr_accept_w),
    .m_axis_tdata       (l4_tdata_w),
    .m_axis_tvalid      (l4_tvalid_w),
    .m_axis_tlast       (l4_tlast_w),
    .m_axis_tuser       (l4_tuser_w),
    .m_meta_valid_o     (), .m_meta_ready_i (1'b1),
    .m_meta_src_ip_o    (), .m_meta_dst_ip_o(),
    .m_meta_proto_o     (), .m_meta_payload_len_o(),
    .stat_rx_frames     (), .stat_rx_dropped()
  );

  // =========================================================================
  // ICMP echo -> ipv4_tx -> arb1
  // =========================================================================
  logic        icmp_meta_valid_w, icmp_meta_ready_w;
  logic [7:0]  icmp_meta_proto_w;
  logic [31:0] icmp_meta_dst_ip_w;
  logic [47:0] icmp_meta_dst_mac_w;
  logic [15:0] icmp_meta_plen_w;
  logic [7:0]  icmp_axis_tdata_w;
  logic        icmp_axis_tvalid_w, icmp_axis_tready_w;
  logic        icmp_axis_tlast_w, icmp_axis_tuser_w;
  logic [15:0] icmp_stat_rx_w, icmp_stat_tx_w;

  icmp_echo #(.LOCAL_IP(LOCAL_IP), .MAX_DATA_BYTES(1472)) u_icmp_echo (
    .clk_i               (clk_i),
    .rst_ni              (rst_tx_w),
    .s_eth_src_mac_i     (frame_src_mac_q),
    .s_ip_hdr_valid_i    (ipv4_hdr_valid_w),
    .s_ip_proto_i        (ipv4_hdr_proto_w),
    .s_ip_src_ip_i       (ipv4_hdr_src_ip_w),
    .s_ip_accept_i       (ipv4_hdr_accept_w),
    .s_axis_tdata        (l4_tdata_w),
    .s_axis_tvalid       (l4_tvalid_w),
    .s_axis_tlast        (l4_tlast_w),
    .s_axis_tuser        (l4_tuser_w),
    .m_meta_valid_o      (icmp_meta_valid_w),
    .m_meta_ready_i      (icmp_meta_ready_w),
    .m_meta_proto_o      (icmp_meta_proto_w),
    .m_meta_dst_ip_o     (icmp_meta_dst_ip_w),
    .m_meta_dst_mac_o    (icmp_meta_dst_mac_w),
    .m_meta_payload_len_o(icmp_meta_plen_w),
    .m_axis_tdata_o      (icmp_axis_tdata_w),
    .m_axis_tvalid_o     (icmp_axis_tvalid_w),
    .m_axis_tready_i     (icmp_axis_tready_w),
    .m_axis_tlast_o      (icmp_axis_tlast_w),
    .m_axis_tuser_o      (icmp_axis_tuser_w),
    .stat_rx_requests    (icmp_stat_rx_w),
    .stat_tx_replies     (icmp_stat_tx_w)
  );

  logic        arb1_meta_valid_w, arb1_meta_ready_w;
  logic [47:0] arb1_meta_dst_mac_w, arb1_meta_src_mac_w;
  logic [15:0] arb1_meta_eth_type_w;
  logic [7:0]  arb1_tdata_w;
  logic        arb1_tvalid_w, arb1_tready_w, arb1_tlast_w, arb1_tuser_w;

  ipv4_tx #(.LOCAL_IP(LOCAL_IP), .LOCAL_MAC(LOCAL_MAC)) u_ipv4_tx_icmp (
    .clk_i               (clk_i),
    .rst_ni              (rst_tx_w),
    .s_meta_valid_i      (icmp_meta_valid_w),
    .s_meta_ready_o      (icmp_meta_ready_w),
    .s_meta_proto_i      (icmp_meta_proto_w),
    .s_meta_dst_ip_i     (icmp_meta_dst_ip_w),
    .s_meta_dst_mac_i    (icmp_meta_dst_mac_w),
    .s_meta_payload_len_i(icmp_meta_plen_w),
    .s_axis_tdata_i      (icmp_axis_tdata_w),
    .s_axis_tvalid_i     (icmp_axis_tvalid_w),
    .s_axis_tready_o     (icmp_axis_tready_w),
    .s_axis_tlast_i      (icmp_axis_tlast_w),
    .s_axis_tuser_i      (icmp_axis_tuser_w),
    .m_meta_valid_o      (arb1_meta_valid_w),
    .m_meta_ready_i      (arb1_meta_ready_w),
    .m_meta_dst_mac_o    (arb1_meta_dst_mac_w),
    .m_meta_src_mac_o    (arb1_meta_src_mac_w),
    .m_meta_eth_type_o   (arb1_meta_eth_type_w),
    .m_axis_tdata_o      (arb1_tdata_w),
    .m_axis_tvalid_o     (arb1_tvalid_w),
    .m_axis_tready_i     (arb1_tready_w),
    .m_axis_tlast_o      (arb1_tlast_w),
    .m_axis_tuser_o      (arb1_tuser_w)
  );

  // =========================================================================
  // UDP XFCP server (Faza B)
  //   ipv4_rx L4 stream -> udp_xfcp_server -> arbiter.s1
  //   arbiter.m1 -> udp_xfcp_server -> ipv4_tx_udp -> eth_tx_arb port 2
  // =========================================================================
  logic        xfcp_eth_rx_valid_w,  xfcp_eth_rx_ready_w;
  logic [7:0]  xfcp_eth_rx_data_w;
  logic        xfcp_eth_rx_last_w;
  // Pipeline register: breaks udp_xfcp_server -> arbiter timing path
  logic        xfcp_eth_rx_valid_r, xfcp_eth_rx_ready_r;
  logic [7:0]  xfcp_eth_rx_data_r;
  logic        xfcp_eth_rx_last_r;

  logic        udp_meta_valid_w, udp_meta_ready_w;
  logic [7:0]  udp_meta_proto_w;
  logic [31:0] udp_meta_dst_ip_w;
  logic [47:0] udp_meta_dst_mac_w;
  logic [15:0] udp_meta_plen_w;
  logic [7:0]  udp_axis_tdata_w;
  logic        udp_axis_tvalid_w, udp_axis_tready_w;
  logic        udp_axis_tlast_w,  udp_axis_tuser_w;

  logic        arb2_meta_valid_w, arb2_meta_ready_w;
  logic [47:0] arb2_meta_dst_mac_w, arb2_meta_src_mac_w;
  logic [15:0] arb2_meta_eth_type_w;
  logic [7:0]  arb2_tdata_w;
  logic        arb2_tvalid_w, arb2_tready_w, arb2_tlast_w, arb2_tuser_w;

  logic        arb_eth_tx_valid_w;
  logic [7:0]  arb_eth_tx_data_w;
  logic        arb_eth_tx_last_w;
  logic        arb_eth_tx_ready_w;

  udp_xfcp_server #(
    .XFCP_PORT     (XFCP_PORT),
    .MAX_PKT_BYTES (128)
  ) u_udp_xfcp (
    .clk_i                (clk_i),
    .rst_ni               (rst_tx_w),
    .s_ip_hdr_valid_i     (ipv4_hdr_valid_w),
    .s_ip_proto_i         (ipv4_hdr_proto_w),
    .s_ip_src_ip_i        (ipv4_hdr_src_ip_w),
    .s_ip_accept_i        (ipv4_hdr_accept_w),
    .s_eth_src_mac_i      (frame_src_mac_q),
    .s_axis_tdata         (l4_tdata_w),
    .s_axis_tvalid        (l4_tvalid_w),
    .s_axis_tlast         (l4_tlast_w),
    .s_axis_tuser         (l4_tuser_w),
    .xfcp_rx_valid_o      (xfcp_eth_rx_valid_w),
    .xfcp_rx_ready_i      (xfcp_eth_rx_ready_w),
    .xfcp_rx_data_o       (xfcp_eth_rx_data_w),
    .xfcp_rx_last_o       (xfcp_eth_rx_last_w),
    .xfcp_tx_valid_i      (arb_eth_tx_valid_w),
    .xfcp_tx_ready_o      (arb_eth_tx_ready_w),
    .xfcp_tx_data_i       (arb_eth_tx_data_w),
    .xfcp_tx_last_i       (arb_eth_tx_last_w),
    .m_meta_valid_o       (udp_meta_valid_w),
    .m_meta_ready_i       (udp_meta_ready_w),
    .m_meta_proto_o       (udp_meta_proto_w),
    .m_meta_dst_ip_o      (udp_meta_dst_ip_w),
    .m_meta_dst_mac_o     (udp_meta_dst_mac_w),
    .m_meta_payload_len_o (udp_meta_plen_w),
    .m_axis_tdata_o       (udp_axis_tdata_w),
    .m_axis_tvalid_o      (udp_axis_tvalid_w),
    .m_axis_tready_i      (udp_axis_tready_w),
    .m_axis_tlast_o       (udp_axis_tlast_w),
    .m_axis_tuser_o       (udp_axis_tuser_w)
  );

  ipv4_tx #(.LOCAL_IP(LOCAL_IP), .LOCAL_MAC(LOCAL_MAC)) u_ipv4_tx_udp (
    .clk_i                (clk_i),
    .rst_ni               (rst_tx_w),
    .s_meta_valid_i       (udp_meta_valid_w),
    .s_meta_ready_o       (udp_meta_ready_w),
    .s_meta_proto_i       (udp_meta_proto_w),
    .s_meta_dst_ip_i      (udp_meta_dst_ip_w),
    .s_meta_dst_mac_i     (udp_meta_dst_mac_w),
    .s_meta_payload_len_i (udp_meta_plen_w),
    .s_axis_tdata_i       (udp_axis_tdata_w),
    .s_axis_tvalid_i      (udp_axis_tvalid_w),
    .s_axis_tready_o      (udp_axis_tready_w),
    .s_axis_tlast_i       (udp_axis_tlast_w),
    .s_axis_tuser_i       (udp_axis_tuser_w),
    .m_meta_valid_o       (arb2_meta_valid_w),
    .m_meta_ready_i       (arb2_meta_ready_w),
    .m_meta_dst_mac_o     (arb2_meta_dst_mac_w),
    .m_meta_src_mac_o     (arb2_meta_src_mac_w),
    .m_meta_eth_type_o    (arb2_meta_eth_type_w),
    .m_axis_tdata_o       (arb2_tdata_w),
    .m_axis_tvalid_o      (arb2_tvalid_w),
    .m_axis_tready_i      (arb2_tready_w),
    .m_axis_tlast_o       (arb2_tlast_w),
    .m_axis_tuser_o       (arb2_tuser_w)
  );

  // =========================================================================
  // TX arbiter: 3->1 (ARP, ICMP, UDP-XFCP)
  // =========================================================================
  logic        txm_meta_valid_w, txm_meta_ready_w;
  logic [47:0] txm_meta_dst_mac_w, txm_meta_src_mac_w;
  logic [15:0] txm_meta_eth_type_w;
  logic [7:0]  txm_tdata_w;
  logic        txm_tvalid_w, txm_tready_w, txm_tlast_w, txm_tuser_w;

  eth_tx_arb u_tx_arb (
    .clk_i              (clk_i),
    .rst_ni             (rst_tx_w),
    .s_meta0_valid_i    (arb0_meta_valid_w),
    .s_meta0_ready_o    (arb0_meta_ready_w),
    .s_meta0_dst_mac_i  (arb0_meta_dst_mac_w),
    .s_meta0_src_mac_i  (arb0_meta_src_mac_w),
    .s_meta0_eth_type_i (arb0_meta_eth_type_w),
    .s_axis0_tdata_i    (arb0_tdata_w),
    .s_axis0_tvalid_i   (arb0_tvalid_w),
    .s_axis0_tready_o   (arb0_tready_w),
    .s_axis0_tlast_i    (arb0_tlast_w),
    .s_axis0_tuser_i    (arb0_tuser_w),
    .s_meta1_valid_i    (arb1_meta_valid_w),
    .s_meta1_ready_o    (arb1_meta_ready_w),
    .s_meta1_dst_mac_i  (arb1_meta_dst_mac_w),
    .s_meta1_src_mac_i  (arb1_meta_src_mac_w),
    .s_meta1_eth_type_i (arb1_meta_eth_type_w),
    .s_axis1_tdata_i    (arb1_tdata_w),
    .s_axis1_tvalid_i   (arb1_tvalid_w),
    .s_axis1_tready_o   (arb1_tready_w),
    .s_axis1_tlast_i    (arb1_tlast_w),
    .s_axis1_tuser_i    (arb1_tuser_w),
    .s_meta2_valid_i    (arb2_meta_valid_w),
    .s_meta2_ready_o    (arb2_meta_ready_w),
    .s_meta2_dst_mac_i  (arb2_meta_dst_mac_w),
    .s_meta2_src_mac_i  (arb2_meta_src_mac_w),
    .s_meta2_eth_type_i (arb2_meta_eth_type_w),
    .s_axis2_tdata_i    (arb2_tdata_w),
    .s_axis2_tvalid_i   (arb2_tvalid_w),
    .s_axis2_tready_o   (arb2_tready_w),
    .s_axis2_tlast_i    (arb2_tlast_w),
    .s_axis2_tuser_i    (arb2_tuser_w),
    .m_meta_valid_o     (txm_meta_valid_w),
    .m_meta_ready_i     (txm_meta_ready_w),
    .m_meta_dst_mac_o   (txm_meta_dst_mac_w),
    .m_meta_src_mac_o   (txm_meta_src_mac_w),
    .m_meta_eth_type_o  (txm_meta_eth_type_w),
    .m_axis_tdata_o     (txm_tdata_w),
    .m_axis_tvalid_o    (txm_tvalid_w),
    .m_axis_tready_i    (txm_tready_w),
    .m_axis_tlast_o     (txm_tlast_w),
    .m_axis_tuser_o     (txm_tuser_w)
  );

  // =========================================================================
  // TX MAC
  // =========================================================================
  logic [15:0] tx_stat_frames_w;

  eth_tx_mac #(.IFG_CYCLES(12)) u_tx_mac (
    .clk_i            (clk_i),
    .rst_ni           (rst_tx_w),
    .s_meta_valid_i   (txm_meta_valid_w),
    .s_meta_ready_o   (txm_meta_ready_w),
    .s_meta_dst_mac_i (txm_meta_dst_mac_w),
    .s_meta_src_mac_i (txm_meta_src_mac_w),
    .s_meta_eth_type_i(txm_meta_eth_type_w),
    .s_axis_tdata_i   (txm_tdata_w),
    .s_axis_tvalid_i  (txm_tvalid_w),
    .s_axis_tready_o  (txm_tready_w),
    .s_axis_tlast_i   (txm_tlast_w),
    .s_axis_tuser_i   (txm_tuser_w),
    .gmii_txd_o       (eth_txd_o),
    .gmii_tx_en_o     (eth_txen_o),
    .gmii_tx_er_o     (eth_txer_o),
    .stat_tx_frames   (tx_stat_frames_w),
    .stat_tx_underflow()
  );

  // =========================================================================
  // UART XFCP cesta (clk_i domain)
  // =========================================================================
  localparam int NUM_SLAVES = 7;

  // UART config z axil_uart_adapter
  logic [31:0]  baud_div_w;
  logic [4:0]   config_w;
  logic         err_clr_w;
  uart_conf_t   uart_cfg_w;
  uart_status_t rx_status_w;
  uart_status_t tx_status_w;

  always_comb begin
    uart_cfg_w.reserved = 27'h0;
    uart_cfg_w.stop2    = config_w[4];
    uart_cfg_w.parity   = config_w[2] ? {~config_w[3], config_w[3]} : 2'b00;
    uart_cfg_w.dbits    = config_w[1:0];
  end

  // UART RX -> elasticky FIFO
  axi4s_if #(.DATA_WIDTH(8)) uart_rx_raw_s (.TCLK(clk_i), .TRESETn(rst_ni));

  axis_uart_rx #(.AXIS_TLAST(1'b0)) u_uart_rx (
    .m_axis     (uart_rx_raw_s.master),
    .rxd_i      (uart_rx_i),
    .prescale_i (baud_div_w[15:0]),
    .cfg_i      (uart_cfg_w),
    .status_o   (rx_status_w),
    .err_clear_i(err_clr_w)
  );

  // Elasticky FIFO: 8 bajtov (UART -> arbiter)
  logic [7:0] rx_fifo_rdata_w;
  logic       rx_fifo_rvalid_w;
  logic       arb_uart_ready_w;

  xfcp_fifo #(.DATA_WIDTH(8), .DEPTH(8)) u_rx_fifo (
    .clk    (clk_i),
    .rst_n  (rst_ni),
    .flush  (1'b0),
    .w_data (uart_rx_raw_s.TDATA),
    .w_valid(uart_rx_raw_s.TVALID),
    .w_ready(uart_rx_raw_s.TREADY),
    .r_data (rx_fifo_rdata_w),
    .r_valid(rx_fifo_rvalid_w),
    .r_ready(arb_uart_ready_w)
  );

  // XFCP TX z arbitra -> skid buffer -> UART TX
  axi4s_if #(.DATA_WIDTH(8)) xfcp_tx_uart_s (.TCLK(clk_i), .TRESETn(rst_ni));
  logic       arb_uart_tx_valid_w;
  logic [7:0] arb_uart_tx_data_w;
  logic       arb_uart_tx_last_w;

  logic arb_uart_s_ready_w;

  axis_skid_buffer #(.DATA_WIDTH(8), .USER_WIDTH(1), .RESET_DATA(1'b1)) u_xfcp_tx_skid (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .s_valid_i (arb_uart_tx_valid_w),
    .s_ready_o (arb_uart_s_ready_w),
    .s_data_i  (arb_uart_tx_data_w),
    .s_last_i  (arb_uart_tx_last_w),
    .s_user_i  (1'b0),
    .m_valid_o (xfcp_tx_uart_s.TVALID),
    .m_ready_i (xfcp_tx_uart_s.TREADY),
    .m_data_o  (xfcp_tx_uart_s.TDATA[7:0]),
    .m_last_o  (xfcp_tx_uart_s.TLAST),
    .m_user_o  (xfcp_tx_uart_s.TUSER)
  );
  assign xfcp_tx_uart_s.TKEEP = '1;
  assign xfcp_tx_uart_s.TID   = '0;
  assign xfcp_tx_uart_s.TDEST = '0;

  axis_uart_tx u_uart_tx (
    .s_axis     (xfcp_tx_uart_s.slave),
    .txd_o      (uart_tx_o),
    .prescale_i (baud_div_w[15:0]),
    .cfg_i      (uart_cfg_w),
    .status_o   (tx_status_w),
    .tx_done_pulse_o()
  );

  // =========================================================================
  // XFCP Arbiter 2-to-1
  // =========================================================================
  logic       xfcp_fab_rx_valid_w, xfcp_fab_rx_ready_w;
  logic [7:0] xfcp_fab_rx_data_w;
  logic       xfcp_fab_rx_last_w;
  logic       xfcp_fab_tx_valid_w, xfcp_fab_tx_ready_w;
  logic [7:0] xfcp_fab_tx_data_w;
  logic       xfcp_fab_tx_last_w;

  axis_skid_buffer #(.DATA_WIDTH(8)) u_eth_xfcp_skid (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .s_valid_i (xfcp_eth_rx_valid_w),
    .s_ready_o (xfcp_eth_rx_ready_w),
    .s_data_i  (xfcp_eth_rx_data_w),
    .s_last_i  (xfcp_eth_rx_last_w),
    .s_user_i  (1'b0),
    .m_valid_o (xfcp_eth_rx_valid_r),
    .m_ready_i (xfcp_eth_rx_ready_r),
    .m_data_o  (xfcp_eth_rx_data_r),
    .m_last_o  (xfcp_eth_rx_last_r),
    .m_user_o  ()
  );

  xfcp_arbiter_2to1 #(.ORD_FIFO_DEPTH(8)) u_arbiter (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    // Port 0: UART
    .s0_valid_i     (rx_fifo_rvalid_w),
    .s0_ready_o     (arb_uart_ready_w),
    .s0_data_i      (rx_fifo_rdata_w),
    // Port 1: ETH-UDP (cez skid buffer pre timing closure)
    .s1_valid_i     (xfcp_eth_rx_valid_r),
    .s1_ready_o     (xfcp_eth_rx_ready_r),
    .s1_data_i      (xfcp_eth_rx_data_r),
    .s1_last_i      (xfcp_eth_rx_last_r),
    // To XFCP fabric endpoint
    .m_valid_o      (xfcp_fab_rx_valid_w),
    .m_ready_i      (xfcp_fab_rx_ready_w),
    .m_data_o       (xfcp_fab_rx_data_w),
    .m_last_o       (xfcp_fab_rx_last_w),
    // From XFCP fabric endpoint (responses)
    .s_resp_valid_i (xfcp_fab_tx_valid_w),
    .s_resp_ready_o (xfcp_fab_tx_ready_w),
    .s_resp_data_i  (xfcp_fab_tx_data_w),
    .s_resp_last_i  (xfcp_fab_tx_last_w),
    // Response Port 0: UART
    .m0_valid_o     (arb_uart_tx_valid_w),
    .m0_ready_i     (arb_uart_s_ready_w),
    .m0_data_o      (arb_uart_tx_data_w),
    .m0_last_o      (arb_uart_tx_last_w),
    // Response Port 1: ETH
    .m1_valid_o     (arb_eth_tx_valid_w),
    .m1_ready_i     (arb_eth_tx_ready_w),
    .m1_data_o      (arb_eth_tx_data_w),
    .m1_last_o      (arb_eth_tx_last_w)
  );

  // =========================================================================
  // XFCP Fabric Endpoint
  // =========================================================================
  axi4s_if #(.DATA_WIDTH(8)) xfcp_ep_rx_s (.TCLK(clk_i), .TRESETn(rst_ni));
  axi4s_if #(.DATA_WIDTH(8)) xfcp_ep_tx_s (.TCLK(clk_i), .TRESETn(rst_ni));

  assign xfcp_ep_rx_s.TDATA[7:0] = xfcp_fab_rx_data_w;
  assign xfcp_ep_rx_s.TVALID     = xfcp_fab_rx_valid_w;
  assign xfcp_fab_rx_ready_w     = xfcp_ep_rx_s.TREADY;
  assign xfcp_ep_rx_s.TLAST      = xfcp_fab_rx_last_w;
  assign xfcp_ep_rx_s.TKEEP      = '1;
  assign xfcp_ep_rx_s.TUSER      = '0;
  assign xfcp_ep_rx_s.TID        = '0;
  assign xfcp_ep_rx_s.TDEST      = '0;

  assign xfcp_fab_tx_valid_w = xfcp_ep_tx_s.TVALID;
  assign xfcp_ep_tx_s.TREADY = xfcp_fab_tx_ready_w;
  assign xfcp_fab_tx_data_w  = xfcp_ep_tx_s.TDATA[7:0];
  assign xfcp_fab_tx_last_w  = xfcp_ep_tx_s.TLAST;

  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32))
      axil_s [NUM_SLAVES] (.ACLK(clk_i), .ARESETn(rst_ni));

  logic endpoint_busy_w;
  logic dbg_sop_w, dbg_hdr_w, dbg_drop_w, dbg_req_w, dbg_resp_w;
  logic dbg_bad_hdr_w, dbg_recovery_w;
  // Registered debug pulses: break the long combinational path from
  // xfcp_rx_parser/header_fifo/rd_ptr_q -> axil_diag_ctrl counters.
  logic dbg_sop_r, dbg_hdr_r, dbg_drop_r, dbg_req_r, dbg_resp_r;
  logic dbg_bad_hdr_r, dbg_recovery_r;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_sop_r     <= 1'b0; dbg_hdr_r     <= 1'b0;
      dbg_drop_r    <= 1'b0; dbg_req_r     <= 1'b0;
      dbg_resp_r    <= 1'b0; dbg_bad_hdr_r <= 1'b0;
      dbg_recovery_r<= 1'b0;
    end else begin
      dbg_sop_r     <= dbg_sop_w;     dbg_hdr_r     <= dbg_hdr_w;
      dbg_drop_r    <= dbg_drop_w;    dbg_req_r     <= dbg_req_w;
      dbg_resp_r    <= dbg_resp_w;    dbg_bad_hdr_r <= dbg_bad_hdr_w;
      dbg_recovery_r<= dbg_recovery_w;
    end
  end

  xfcp_fabric_endpoint #(
    .NUM_SLAVES     (NUM_SLAVES),
    .AXI_ADDR_WIDTH (32),
    .AXI_DATA_WIDTH (32),
    .LITTLE_ENDIAN  (1'b0),
    .ID_STR         ("XFCP-05-SWITCH "),
    .SLAVE_BASE('{
      32'hFF00_0000,
      32'hFF01_0000,
      32'hFF02_0000,
      32'hFF03_0000,
      32'hFF04_0000,
      32'hFF05_0000,
      32'hFF06_0000
    }),
    .SLAVE_MASK('{
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000
    })
  ) u_endpoint (
    .clk             (clk_i),
    .rst_n           (rst_ni),
    .xfcp_in         (xfcp_ep_rx_s.slave),
    .xfcp_out        (xfcp_ep_tx_s.master),
    .m_axil          (axil_s),
    .endpoint_busy_o (endpoint_busy_w),
    .dbg_sop_o       (dbg_sop_w),
    .dbg_hdr_o       (dbg_hdr_w),
    .dbg_drop_o      (dbg_drop_w),
    .dbg_req_o       (dbg_req_w),
    .dbg_resp_o      (dbg_resp_w),
    .dbg_bad_hdr_o   (dbg_bad_hdr_w),
    .dbg_recovery_o  (dbg_recovery_w)
  );

  // =========================================================================
  // AXI-Lite Slaves
  // =========================================================================

  // Slot 0: System Control
  axil_sys_ctrl #(.CLOCK_FREQ_HZ(CLOCK_HZ)) u_sys_ctrl (
    .clk_i         (clk_i), .rst_ni(rst_ni),
    .s_axil        (axil_s[0].slave),
    .pll_locked_i  (1'b1),
    .ic_timeout_i  (1'b0),
    .fault_addr_i  (32'h0),
    .fault_status_i(32'h0),
    .sw_reset_o    (), .clear_faults_o()
  );

  // Slot 1: UART adapter
  axil_uart_adapter #(.BAUD_DIV_DEFAULT(UART_DEFAULT_BAUD_DIV)) u_uart_adapter (
    .clk_i        (clk_i), .rst_ni(rst_ni),
    .s_axil       (axil_s[1].slave),
    .tx_busy_i    (tx_status_w.tx_busy),
    .rx_busy_i    (rx_status_w.rx_busy),
    .overrun_err_i(rx_status_w.overrun_err),
    .frame_err_i  (rx_status_w.frame_err),
    .parity_err_i (rx_status_w.parity_err),
    .tx_fifo_cnt_i(8'h0),
    .rx_fifo_cnt_i(8'h0),
    .baud_div_o   (baud_div_w),
    .config_o     (config_w),
    .err_clr_o    (err_clr_w)
  );

  // Slot 2: Onboard LED 6-bit
  logic [31:0] led_data_00_w;
  axil_regs u_led_regs_00 (.clk_i(clk_i), .rst_ni(rst_ni),
                            .s_axil(axil_s[2].slave), .data_o(led_data_00_w));
  assign led_o = led_data_00_w[5:0];

  // Slot 3: PMOD J10 8-bit
  logic [31:0] led_data_01_w;
  axil_regs u_led_regs_01 (.clk_i(clk_i), .rst_ni(rst_ni),
                            .s_axil(axil_s[3].slave), .data_o(led_data_01_w));
  assign pmod_j10_o = led_data_01_w[7:0];

  // Slot 4: PMOD J11 8-bit
  logic [31:0] led_data_02_w;
  axil_regs u_led_regs_02 (.clk_i(clk_i), .rst_ni(rst_ni),
                            .s_axil(axil_s[4].slave), .data_o(led_data_02_w));
  assign pmod_j11_o = led_data_02_w[7:0];

  // Slot 5: 7-segment display
  axil_seven_seg_adapter #(
    .CLOCK_FREQ_HZ   (CLOCK_HZ),
    .DIGIT_REFRESH_HZ(250),
    .COMMON_ANODE    (1'b1)
  ) u_seven_seg (
    .clk_i (clk_i), .rst_ni(rst_ni),
    .s_axil(axil_s[5].slave),
    .dig_o (dig_o), .seg_o (seg_o)
  );

  // Slot 6: Diagnostic counters
  wire rx_seen_pulse_w    = uart_rx_raw_s.TVALID;
  wire rx_accept_pulse_w  = uart_rx_raw_s.TVALID &&  uart_rx_raw_s.TREADY;
  wire rx_lost_pulse_w    = uart_rx_raw_s.TVALID && !uart_rx_raw_s.TREADY;
  wire rx_frame_pulse_w   = rx_status_w.frame_err;
  wire rx_overrun_pulse_w = rx_status_w.overrun_err;
  wire tx_byte_pulse_w    = xfcp_tx_uart_s.TVALID && xfcp_tx_uart_s.TREADY;

  axil_diag_ctrl u_diag_ctrl (
    .clk_i        (clk_i), .rst_ni(rst_ni),
    .s_axil       (axil_s[6].slave),
    .rx_seen_i    (rx_seen_pulse_w),
    .rx_accept_i  (rx_accept_pulse_w),
    .rx_lost_i    (rx_lost_pulse_w),
    .rx_frame_i   (rx_frame_pulse_w),
    .rx_overrun_i (rx_overrun_pulse_w),
    .rx_sop_i     (dbg_sop_r),
    .rx_hdr_i     (dbg_hdr_r),
    .rx_bad_hdr_i (dbg_bad_hdr_r),
    .rx_recovery_i(dbg_recovery_r),
    .rx_drop_i    (dbg_drop_r),
    .fab_req_i    (dbg_req_r),
    .fab_resp_i   (dbg_resp_r),
    .tx_byte_i    (tx_byte_pulse_w),
    .tx_pkt_i     (dbg_resp_r)
  );

  // =========================================================================
  // Status LEDs (active-low, clk_i domain)
  // =========================================================================
  logic [26:0] hb_cnt_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) hb_cnt_q <= '0;
    else         hb_cnt_q <= hb_cnt_q + 27'd1;
  end

  // Heartbeat (27-bit @ 125 MHz => ~1.07 s toggle)
  // led_o driven by axil_regs; use pmod_j11_o[7] as HB override (diagnostic)
  // These override the register-driven LEDs for quick visual check:
  // led_o[0] = HB, led_o[1] = PHY reset, rest from axil_regs
  // (axil_regs drives all 6 bits; top 2 can be overridden here for debug)

endmodule

`default_nettype wire

`endif // XFCP_TEST_05_TOP_SV
