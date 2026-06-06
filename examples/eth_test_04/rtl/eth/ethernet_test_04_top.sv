/**
 * @file ethernet_test_04_top.sv
 * @brief Full L2/L3/L4 Ethernet stack: ARP echo, ICMP echo, UDP echo.
 * @param LOCAL_MAC  48-bit FPGA MAC address.
 * @param LOCAL_IP   32-bit FPGA IP address.
 * @details
 *   RX: eth_rx_mac (eth_rx_clk_i domain) -> pfifo+mfifo (CDC async FIFOs)
 *   TX domain (eth_tx_clk_i):
 *     TX dispatcher (D_IDLE->D_ROUTE->D_STREAM) consumes mfifo meta, then
 *     forwards pfifo payload through eth_type_demux:
 *       port0 (ARP  0x0806): arp_rx -> arp_tx -> eth_tx_arb port0
 *       port1 (IPv4 0x0800): ipv4_rx -> icmp_echo -> ipv4_tx -> arb port1
 *                                    -> udp_echo  -> ipv4_tx -> arb port2
 *     eth_tx_arb (3->1 fixed priority ARP>ICMP>UDP) -> eth_tx_mac
 *
 *   mfifo: {fcs_ok[1], dst_mac[48], src_mac[48], eth_type[16]} = 113 bits, DEPTH=8.
 *   pfifo: {tuser[1], tlast[1], tdata[8]} = 10 bits, DEPTH=2048.
 *   D_ROUTE fires s_hdr_valid_i to eth_type_demux; D_STREAM forwards pfifo bytes.
 *   frame_src_mac_q latches m1_hdr_src_mac on m1_hdr_valid (same cycle as D_ROUTE).
 */
`ifndef ETHERNET_TEST_04_TOP_SV
`define ETHERNET_TEST_04_TOP_SV

`default_nettype none

module ethernet_test_04_top #(
  parameter logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0,
  parameter logic [31:0] LOCAL_IP  = 32'hC0A8_0002
) (
  input  wire logic        sys_clk_i,
  input  wire logic        rst_ni,

  // GMII RX (125 MHz from PHY)
  input  wire logic        eth_rx_clk_i,
  input  wire logic        eth_rxdv_i,
  input  wire logic        eth_rxer_i,
  input  wire logic [7:0]  eth_rxd_i,

  // GMII TX
  input  wire logic        eth_tx_clk_i,
  output      logic        eth_gtx_clk_o,
  output      logic        eth_txen_o,
  output      logic        eth_txer_o,
  output      logic [7:0]  eth_txd_o,

  // PHY management (MDC/MDIO driven to idle)
  output      logic        eth_phyrstb_o,
  output      logic        eth_mdc_o,
  inout       wire  logic  eth_mdio_io,

  // Onboard
  output      logic [5:0]  led_o,
  output      logic [7:0]  dbg_mac_data_o,
  output      logic [7:0]  dbg_ctrl_o,
  output      logic        uart_tap_tx_o,
  input  wire logic [3:0]  btn_i
);

  // btn_i[3] as SW reset (active-low)
  logic rst_w;
  assign rst_w = rst_ni && btn_i[3];

  // TX-domain reset sync (async assert, sync deassert)
  logic [1:0] rst_tx_sync_q;
  logic       rst_tx_w;
  always_ff @(posedge eth_tx_clk_i or negedge rst_w) begin
    if (!rst_w) rst_tx_sync_q <= 2'b00;
    else        rst_tx_sync_q <= {rst_tx_sync_q[0], 1'b1};
  end
  assign rst_tx_w = rst_tx_sync_q[1];

  // -------------------------------------------------------------------------
  // PHY reset: 24-bit counter @ 50 MHz => ~336 ms deassert
  // -------------------------------------------------------------------------
  logic [23:0] phy_rst_cnt_q;
  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) phy_rst_cnt_q <= '0;
    else if (!(&phy_rst_cnt_q)) phy_rst_cnt_q <= phy_rst_cnt_q + 24'd1;
  end
  assign eth_phyrstb_o = &phy_rst_cnt_q;

  assign eth_mdc_o   = 1'b0;
  assign eth_mdio_io = 1'bz;

  // -------------------------------------------------------------------------
  // GTX_CLK: altddio_out, invert_output="ON"
  // -------------------------------------------------------------------------
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
    .outclock   (eth_tx_clk_i),
    .dataout    (eth_gtx_clk_o),
    .aclr       (1'b0),
    .aset       (1'b0),
    .oe         (1'b1),
    .oe_out     (),
    .outclocken (1'b1),
    .sclr       (1'b0),
    .sset       (1'b0)
  );
`else
  assign eth_gtx_clk_o = eth_tx_clk_i;
`endif

  // -------------------------------------------------------------------------
  // GMII RX input sampling: altddio_in, invert_input_clocks="ON"
  // -------------------------------------------------------------------------
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
    .datain    (eth_rxd_i),
    .inclock   (eth_rx_clk_i),
    .dataout_h (rxd_s_w),
    .dataout_l (),
    .aclr      (1'b0),
    .aset      (1'b0),
    .inclocken (1'b1),
    .sclr      (1'b0),
    .sset      (1'b0)
  );

  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_in"),
    .width                  (1)
  ) u_rxdv_ddr (
    .datain    (eth_rxdv_i),
    .inclock   (eth_rx_clk_i),
    .dataout_h (rxdv_s_w),
    .dataout_l (),
    .aclr      (1'b0),
    .aset      (1'b0),
    .inclocken (1'b1),
    .sclr      (1'b0),
    .sset      (1'b0)
  );

  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .lpm_hint               ("UNUSED"),
    .lpm_type               ("altddio_in"),
    .width                  (1)
  ) u_rxer_ddr (
    .datain    (eth_rxer_i),
    .inclock   (eth_rx_clk_i),
    .dataout_h (rxer_s_w),
    .dataout_l (),
    .aclr      (1'b0),
    .aset      (1'b0),
    .inclocken (1'b1),
    .sclr      (1'b0),
    .sset      (1'b0)
  );
`else
  assign rxd_s_w  = eth_rxd_i;
  assign rxdv_s_w = eth_rxdv_i;
  assign rxer_s_w = eth_rxer_i;
`endif

  // -------------------------------------------------------------------------
  // eth_rx_mac outputs (eth_rx_clk_i domain)
  // -------------------------------------------------------------------------
  logic [7:0]  rx_tdata_w;
  logic        rx_tvalid_w;
  logic        rx_tready_w;
  logic        rx_tlast_w;
  logic        rx_tuser_w;

  logic        rx_meta_valid_w;
  logic        rx_meta_ready_w;
  logic [47:0] rx_meta_dst_mac_w;
  logic [47:0] rx_meta_src_mac_w;
  logic [15:0] rx_meta_eth_type_w;
  logic        rx_meta_fcs_ok_w;
  logic        rx_meta_mac_ok_w;

  logic [15:0] rx_stat_frames_w;

  // -------------------------------------------------------------------------
  // Payload async FIFO: {tuser,tlast,tdata} = 10 bits, DEPTH=2048
  // -------------------------------------------------------------------------
  localparam int PAYLOAD_W = 10;
  logic [PAYLOAD_W-1:0] pfifo_wr_w;
  logic                 pfifo_wr_ready_w;
  logic [PAYLOAD_W-1:0] pfifo_rd_w;
  logic                 pfifo_rd_valid_w;
  logic                 pfifo_rd_ready_w;

  logic [7:0]  pfifo_tdata_w;
  logic        pfifo_tlast_w;
  logic        pfifo_tuser_w;

  assign pfifo_wr_w                                    = {rx_tuser_w, rx_tlast_w, rx_tdata_w};
  assign {pfifo_tuser_w, pfifo_tlast_w, pfifo_tdata_w} = pfifo_rd_w;
  assign rx_tready_w                                   = pfifo_wr_ready_w;

  // -------------------------------------------------------------------------
  // Meta async FIFO: {fcs_ok[1],dst_mac[48],src_mac[48],eth_type[16]} = 113b
  // -------------------------------------------------------------------------
  localparam int META_W = 113;
  logic [META_W-1:0] mfifo_wr_w;
  logic              mfifo_wr_ready_w;
  logic [META_W-1:0] mfifo_rd_w;
  logic              mfifo_rd_valid_w;
  logic              mfifo_rd_ready_w;

  logic        meta_fcs_ok_w;
  logic [47:0] meta_dst_mac_w;
  logic [47:0] meta_src_mac_w;
  logic [15:0] meta_eth_type_w;

  assign mfifo_wr_w = {rx_meta_fcs_ok_w, rx_meta_dst_mac_w,
                       rx_meta_src_mac_w, rx_meta_eth_type_w};
  assign rx_meta_ready_w = mfifo_wr_ready_w;
  assign {meta_fcs_ok_w, meta_dst_mac_w,
          meta_src_mac_w, meta_eth_type_w} = mfifo_rd_w;

  // -------------------------------------------------------------------------
  // RX MAC (eth_rx_clk_i domain)
  // -------------------------------------------------------------------------
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
    .m_hdr_valid_o   (),
    .m_hdr_dst_mac_o (),
    .m_hdr_src_mac_o (),
    .m_hdr_eth_type_o(),
    .m_hdr_mac_ok_o  (),
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

  // -------------------------------------------------------------------------
  // Payload async FIFO
  // -------------------------------------------------------------------------
  async_fifo #(
    .DATA_WIDTH (PAYLOAD_W),
    .DEPTH      (2048)
  ) u_payload_fifo (
    .wr_clk_i   (eth_rx_clk_i),
    .wr_rst_ni  (rst_w),
    .wr_data_i  (pfifo_wr_w),
    .wr_valid_i (rx_tvalid_w),
    .wr_ready_o (pfifo_wr_ready_w),
    .rd_clk_i   (eth_tx_clk_i),
    .rd_rst_ni  (rst_tx_w),
    .rd_data_o  (pfifo_rd_w),
    .rd_valid_o (pfifo_rd_valid_w),
    .rd_ready_i (pfifo_rd_ready_w)
  );

  // -------------------------------------------------------------------------
  // Meta async FIFO
  // -------------------------------------------------------------------------
  async_fifo #(
    .DATA_WIDTH (META_W),
    .DEPTH      (8)
  ) u_meta_fifo (
    .wr_clk_i   (eth_rx_clk_i),
    .wr_rst_ni  (rst_w),
    .wr_data_i  (mfifo_wr_w),
    .wr_valid_i (rx_meta_valid_w),
    .wr_ready_o (mfifo_wr_ready_w),
    .rd_clk_i   (eth_tx_clk_i),
    .rd_rst_ni  (rst_tx_w),
    .rd_data_o  (mfifo_rd_w),
    .rd_valid_o (mfifo_rd_valid_w),
    .rd_ready_i (mfifo_rd_ready_w)
  );

  // =========================================================================
  // TX domain (eth_tx_clk_i)
  // =========================================================================

  // -------------------------------------------------------------------------
  // TX dispatcher FSM: consumes mfifo, presents hdr to eth_type_demux, then
  // forwards pfifo payload.
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    D_IDLE   = 2'd0,
    D_ROUTE  = 2'd1,
    D_STREAM = 2'd2
  } disp_state_e;

  disp_state_e disp_state_q;

  always_ff @(posedge eth_tx_clk_i or negedge rst_tx_w) begin
    if (!rst_tx_w) begin
      disp_state_q <= D_IDLE;
    end else begin
      case (disp_state_q)
        D_IDLE:   if (mfifo_rd_valid_w) disp_state_q <= D_ROUTE;
        D_ROUTE:  disp_state_q <= D_STREAM;
        D_STREAM: if (pfifo_rd_valid_w && pfifo_tlast_w) disp_state_q <= D_IDLE;
        default:  disp_state_q <= D_IDLE;
      endcase
    end
  end

  // mfifo consumed in D_ROUTE; pfifo forwarded in D_STREAM
  assign mfifo_rd_ready_w = (disp_state_q == D_ROUTE);
  assign pfifo_rd_ready_w = (disp_state_q == D_STREAM);

  // Demux header inputs (presented in D_ROUTE from mfifo, still valid that cycle)
  logic        demux_hdr_valid_w;
  logic [47:0] demux_hdr_dst_mac_w;
  logic [47:0] demux_hdr_src_mac_w;
  logic [15:0] demux_hdr_eth_type_w;
  logic        demux_hdr_mac_ok_w;

  assign demux_hdr_valid_w   = (disp_state_q == D_ROUTE);
  assign demux_hdr_dst_mac_w = meta_dst_mac_w;
  assign demux_hdr_src_mac_w = meta_src_mac_w;
  assign demux_hdr_eth_type_w = meta_eth_type_w;
  assign demux_hdr_mac_ok_w  = meta_fcs_ok_w;

  // Demux payload inputs (from pfifo, gated to D_STREAM)
  logic [7:0]  demux_tdata_w;
  logic        demux_tvalid_w;
  logic        demux_tlast_w;
  logic        demux_tuser_w;

  assign demux_tdata_w  = pfifo_tdata_w;
  assign demux_tvalid_w = pfifo_rd_valid_w && (disp_state_q == D_STREAM);
  assign demux_tlast_w  = pfifo_tlast_w;
  assign demux_tuser_w  = pfifo_tuser_w;

  // -------------------------------------------------------------------------
  // eth_type_demux: ARP (port0) + IPv4 (port1)
  // -------------------------------------------------------------------------
  logic [7:0]  arp0_tdata_w;
  logic        arp0_tvalid_w;
  logic        arp0_tlast_w;
  logic        arp0_tuser_w;

  logic [7:0]  ip1_tdata_w;
  logic        ip1_tvalid_w;
  logic        ip1_tlast_w;
  logic        ip1_tuser_w;
  logic        ip1_hdr_valid_w;
  logic [47:0] ip1_hdr_src_mac_w;

  eth_type_demux #(
    .ETH_TYPE_0(16'h0806),
    .ETH_TYPE_1(16'h0800)
  ) u_demux (
    .clk_i            (eth_tx_clk_i),
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
    .m0_hdr_valid     (),
    .m0_hdr_dst_mac   (),
    .m0_hdr_src_mac   (),
    .m1_axis_tdata    (ip1_tdata_w),
    .m1_axis_tvalid   (ip1_tvalid_w),
    .m1_axis_tlast    (ip1_tlast_w),
    .m1_axis_tuser    (ip1_tuser_w),
    .m1_hdr_valid     (ip1_hdr_valid_w),
    .m1_hdr_dst_mac   (),
    .m1_hdr_src_mac   (ip1_hdr_src_mac_w),
    .stat_routed_0    (),
    .stat_routed_1    (),
    .stat_dropped     ()
  );

  // Latch src_mac for ICMP/UDP replies (stable for entire frame)
  logic [47:0] frame_src_mac_q;
  always_ff @(posedge eth_tx_clk_i or negedge rst_tx_w) begin
    if (!rst_tx_w) frame_src_mac_q <= '0;
    else if (ip1_hdr_valid_w) frame_src_mac_q <= ip1_hdr_src_mac_w;
  end

  // -------------------------------------------------------------------------
  // ARP: arp_rx -> arp_tx
  // -------------------------------------------------------------------------
  logic        arp_req_valid_w;
  logic        arp_req_ready_w;
  logic [47:0] arp_req_mac_w;
  logic [31:0] arp_req_ip_w;
  logic [15:0] arp_stat_rx_w;
  logic [15:0] arp_stat_tx_w;

  arp_rx #(
    .LOCAL_IP(LOCAL_IP)
  ) u_arp_rx (
    .clk_i            (eth_tx_clk_i),
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

  // ---- arp_tx output wires (to eth_tx_arb port 0) ----
  logic        arb0_meta_valid_w;
  logic        arb0_meta_ready_w;
  logic [47:0] arb0_meta_dst_mac_w;
  logic [47:0] arb0_meta_src_mac_w;
  logic [15:0] arb0_meta_eth_type_w;
  logic [7:0]  arb0_tdata_w;
  logic        arb0_tvalid_w;
  logic        arb0_tready_w;
  logic        arb0_tlast_w;
  logic        arb0_tuser_w;

  arp_tx #(
    .LOCAL_MAC(LOCAL_MAC),
    .LOCAL_IP (LOCAL_IP)
  ) u_arp_tx (
    .clk_i             (eth_tx_clk_i),
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

  // -------------------------------------------------------------------------
  // IPv4 RX: strips IP header, dispatches to ICMP and UDP
  // -------------------------------------------------------------------------
  logic [7:0]  l4_tdata_w;
  logic        l4_tvalid_w;
  logic        l4_tlast_w;
  logic        l4_tuser_w;
  logic        ipv4_hdr_valid_w;
  logic [7:0]  ipv4_hdr_proto_w;
  logic [31:0] ipv4_hdr_src_ip_w;
  logic        ipv4_hdr_accept_w;

  ipv4_rx #(
    .LOCAL_IP   (LOCAL_IP),
    .PROMISCUOUS(1'b0)
  ) u_ipv4_rx (
    .clk_i              (eth_tx_clk_i),
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
    .m_meta_valid_o     (),
    .m_meta_ready_i     (1'b1),
    .m_meta_src_ip_o    (),
    .m_meta_dst_ip_o    (),
    .m_meta_proto_o     (),
    .m_meta_payload_len_o(),
    .stat_rx_frames     (),
    .stat_rx_dropped    ()
  );

  // -------------------------------------------------------------------------
  // ICMP echo: icmp_echo -> ipv4_tx -> eth_tx_arb port 1
  // -------------------------------------------------------------------------
  logic        icmp_meta_valid_w;
  logic        icmp_meta_ready_w;
  logic [7:0]  icmp_meta_proto_w;
  logic [31:0] icmp_meta_dst_ip_w;
  logic [47:0] icmp_meta_dst_mac_w;
  logic [15:0] icmp_meta_plen_w;
  logic [7:0]  icmp_axis_tdata_w;
  logic        icmp_axis_tvalid_w;
  logic        icmp_axis_tready_w;
  logic        icmp_axis_tlast_w;
  logic        icmp_axis_tuser_w;
  logic [15:0] icmp_stat_rx_w;
  logic [15:0] icmp_stat_tx_w;

  icmp_echo #(
    .LOCAL_IP      (LOCAL_IP),
    .MAX_DATA_BYTES(1472)
  ) u_icmp_echo (
    .clk_i               (eth_tx_clk_i),
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

  logic        arb1_meta_valid_w;
  logic        arb1_meta_ready_w;
  logic [47:0] arb1_meta_dst_mac_w;
  logic [47:0] arb1_meta_src_mac_w;
  logic [15:0] arb1_meta_eth_type_w;
  logic [7:0]  arb1_tdata_w;
  logic        arb1_tvalid_w;
  logic        arb1_tready_w;
  logic        arb1_tlast_w;
  logic        arb1_tuser_w;

  ipv4_tx #(
    .LOCAL_IP (LOCAL_IP),
    .LOCAL_MAC(LOCAL_MAC)
  ) u_ipv4_tx_icmp (
    .clk_i               (eth_tx_clk_i),
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

  // -------------------------------------------------------------------------
  // UDP echo: udp_echo -> ipv4_tx -> eth_tx_arb port 2
  // -------------------------------------------------------------------------
  logic        udp_meta_valid_w;
  logic        udp_meta_ready_w;
  logic [7:0]  udp_meta_proto_w;
  logic [31:0] udp_meta_dst_ip_w;
  logic [47:0] udp_meta_dst_mac_w;
  logic [15:0] udp_meta_plen_w;
  logic [7:0]  udp_axis_tdata_w;
  logic        udp_axis_tvalid_w;
  logic        udp_axis_tready_w;
  logic        udp_axis_tlast_w;
  logic        udp_axis_tuser_w;
  logic [15:0] udp_stat_rx_w;
  logic [15:0] udp_stat_tx_w;

  udp_echo #(
    .MAX_DATA_BYTES(1472)
  ) u_udp_echo (
    .clk_i               (eth_tx_clk_i),
    .rst_ni              (rst_tx_w),
    .local_port_i        (16'd7),     // echo port (RFC 862)
    .promiscuous_i       (1'b1),      // accept all UDP ports
    .s_eth_src_mac_i     (frame_src_mac_q),
    .s_ip_hdr_valid_i    (ipv4_hdr_valid_w),
    .s_ip_proto_i        (ipv4_hdr_proto_w),
    .s_ip_src_ip_i       (ipv4_hdr_src_ip_w),
    .s_ip_accept_i       (ipv4_hdr_accept_w),
    .s_axis_tdata        (l4_tdata_w),
    .s_axis_tvalid       (l4_tvalid_w),
    .s_axis_tlast        (l4_tlast_w),
    .s_axis_tuser        (l4_tuser_w),
    .m_meta_valid_o      (udp_meta_valid_w),
    .m_meta_ready_i      (udp_meta_ready_w),
    .m_meta_proto_o      (udp_meta_proto_w),
    .m_meta_dst_ip_o     (udp_meta_dst_ip_w),
    .m_meta_dst_mac_o    (udp_meta_dst_mac_w),
    .m_meta_payload_len_o(udp_meta_plen_w),
    .m_axis_tdata_o      (udp_axis_tdata_w),
    .m_axis_tvalid_o     (udp_axis_tvalid_w),
    .m_axis_tready_i     (udp_axis_tready_w),
    .m_axis_tlast_o      (udp_axis_tlast_w),
    .m_axis_tuser_o      (udp_axis_tuser_w),
    .stat_rx_frames      (udp_stat_rx_w),
    .stat_tx_frames      (udp_stat_tx_w)
  );

  logic        arb2_meta_valid_w;
  logic        arb2_meta_ready_w;
  logic [47:0] arb2_meta_dst_mac_w;
  logic [47:0] arb2_meta_src_mac_w;
  logic [15:0] arb2_meta_eth_type_w;
  logic [7:0]  arb2_tdata_w;
  logic        arb2_tvalid_w;
  logic        arb2_tready_w;
  logic        arb2_tlast_w;
  logic        arb2_tuser_w;

  ipv4_tx #(
    .LOCAL_IP (LOCAL_IP),
    .LOCAL_MAC(LOCAL_MAC)
  ) u_ipv4_tx_udp (
    .clk_i               (eth_tx_clk_i),
    .rst_ni              (rst_tx_w),
    .s_meta_valid_i      (udp_meta_valid_w),
    .s_meta_ready_o      (udp_meta_ready_w),
    .s_meta_proto_i      (udp_meta_proto_w),
    .s_meta_dst_ip_i     (udp_meta_dst_ip_w),
    .s_meta_dst_mac_i    (udp_meta_dst_mac_w),
    .s_meta_payload_len_i(udp_meta_plen_w),
    .s_axis_tdata_i      (udp_axis_tdata_w),
    .s_axis_tvalid_i     (udp_axis_tvalid_w),
    .s_axis_tready_o     (udp_axis_tready_w),
    .s_axis_tlast_i      (udp_axis_tlast_w),
    .s_axis_tuser_i      (udp_axis_tuser_w),
    .m_meta_valid_o      (arb2_meta_valid_w),
    .m_meta_ready_i      (arb2_meta_ready_w),
    .m_meta_dst_mac_o    (arb2_meta_dst_mac_w),
    .m_meta_src_mac_o    (arb2_meta_src_mac_w),
    .m_meta_eth_type_o   (arb2_meta_eth_type_w),
    .m_axis_tdata_o      (arb2_tdata_w),
    .m_axis_tvalid_o     (arb2_tvalid_w),
    .m_axis_tready_i     (arb2_tready_w),
    .m_axis_tlast_o      (arb2_tlast_w),
    .m_axis_tuser_o      (arb2_tuser_w)
  );

  // -------------------------------------------------------------------------
  // TX arbiter: 3->1 (port0=ARP, port1=ICMP, port2=UDP)
  // -------------------------------------------------------------------------
  logic        txm_meta_valid_w;
  logic        txm_meta_ready_w;
  logic [47:0] txm_meta_dst_mac_w;
  logic [47:0] txm_meta_src_mac_w;
  logic [15:0] txm_meta_eth_type_w;
  logic [7:0]  txm_tdata_w;
  logic        txm_tvalid_w;
  logic        txm_tready_w;
  logic        txm_tlast_w;
  logic        txm_tuser_w;

  eth_tx_arb u_tx_arb (
    .clk_i             (eth_tx_clk_i),
    .rst_ni            (rst_tx_w),
    .s_meta0_valid_i   (arb0_meta_valid_w),
    .s_meta0_ready_o   (arb0_meta_ready_w),
    .s_meta0_dst_mac_i (arb0_meta_dst_mac_w),
    .s_meta0_src_mac_i (arb0_meta_src_mac_w),
    .s_meta0_eth_type_i(arb0_meta_eth_type_w),
    .s_axis0_tdata_i   (arb0_tdata_w),
    .s_axis0_tvalid_i  (arb0_tvalid_w),
    .s_axis0_tready_o  (arb0_tready_w),
    .s_axis0_tlast_i   (arb0_tlast_w),
    .s_axis0_tuser_i   (arb0_tuser_w),
    .s_meta1_valid_i   (arb1_meta_valid_w),
    .s_meta1_ready_o   (arb1_meta_ready_w),
    .s_meta1_dst_mac_i (arb1_meta_dst_mac_w),
    .s_meta1_src_mac_i (arb1_meta_src_mac_w),
    .s_meta1_eth_type_i(arb1_meta_eth_type_w),
    .s_axis1_tdata_i   (arb1_tdata_w),
    .s_axis1_tvalid_i  (arb1_tvalid_w),
    .s_axis1_tready_o  (arb1_tready_w),
    .s_axis1_tlast_i   (arb1_tlast_w),
    .s_axis1_tuser_i   (arb1_tuser_w),
    .s_meta2_valid_i   (arb2_meta_valid_w),
    .s_meta2_ready_o   (arb2_meta_ready_w),
    .s_meta2_dst_mac_i (arb2_meta_dst_mac_w),
    .s_meta2_src_mac_i (arb2_meta_src_mac_w),
    .s_meta2_eth_type_i(arb2_meta_eth_type_w),
    .s_axis2_tdata_i   (arb2_tdata_w),
    .s_axis2_tvalid_i  (arb2_tvalid_w),
    .s_axis2_tready_o  (arb2_tready_w),
    .s_axis2_tlast_i   (arb2_tlast_w),
    .s_axis2_tuser_i   (arb2_tuser_w),
    .m_meta_valid_o    (txm_meta_valid_w),
    .m_meta_ready_i    (txm_meta_ready_w),
    .m_meta_dst_mac_o  (txm_meta_dst_mac_w),
    .m_meta_src_mac_o  (txm_meta_src_mac_w),
    .m_meta_eth_type_o (txm_meta_eth_type_w),
    .m_axis_tdata_o    (txm_tdata_w),
    .m_axis_tvalid_o   (txm_tvalid_w),
    .m_axis_tready_i   (txm_tready_w),
    .m_axis_tlast_o    (txm_tlast_w),
    .m_axis_tuser_o    (txm_tuser_w)
  );

  // -------------------------------------------------------------------------
  // TX MAC
  // -------------------------------------------------------------------------
  logic [15:0] tx_stat_frames_w;

  eth_tx_mac #(
    .IFG_CYCLES(12)
  ) u_tx_mac (
    .clk_i             (eth_tx_clk_i),
    .rst_ni            (rst_tx_w),
    .s_meta_valid_i    (txm_meta_valid_w),
    .s_meta_ready_o    (txm_meta_ready_w),
    .s_meta_dst_mac_i  (txm_meta_dst_mac_w),
    .s_meta_src_mac_i  (txm_meta_src_mac_w),
    .s_meta_eth_type_i (txm_meta_eth_type_w),
    .s_axis_tdata_i    (txm_tdata_w),
    .s_axis_tvalid_i   (txm_tvalid_w),
    .s_axis_tready_o   (txm_tready_w),
    .s_axis_tlast_i    (txm_tlast_w),
    .s_axis_tuser_i    (txm_tuser_w),
    .gmii_txd_o        (eth_txd_o),
    .gmii_tx_en_o      (eth_txen_o),
    .gmii_tx_er_o      (eth_txer_o),
    .stat_tx_frames    (tx_stat_frames_w),
    .stat_tx_underflow ()
  );

  // -------------------------------------------------------------------------
  // Raw GMII tap (eth_rx_clk_i domain)
  // -------------------------------------------------------------------------
  gmii_raw_tap #(
    .CLK_HZ  (125_000_000),
    .BAUD    (115_200),
    .N_BYTES (32)
  ) u_gmii_raw_tap (
    .clk_i        (eth_rx_clk_i),
    .rst_ni       (rst_w),
    .gmii_rx_dv_i (rxdv_s_w),
    .gmii_rxd_i   (rxd_s_w),
    .uart_tx_o    (uart_tap_tx_o)
  );

  // -------------------------------------------------------------------------
  // Heartbeat (eth_rx_clk_i, 27-bit => ~1.07 s)
  // -------------------------------------------------------------------------
  logic [26:0] hb_cnt_q;
  always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
    if (!rst_w) hb_cnt_q <= '0;
    else        hb_cnt_q <= hb_cnt_q + 27'd1;
  end

  // LED (active-low)
  assign led_o[0] = !hb_cnt_q[26];          // ~1 Hz heartbeat
  assign led_o[1] = !eth_phyrstb_o;         // PHY in reset
  assign led_o[2] = !rx_stat_frames_w[0];   // RX frame parity
  assign led_o[3] = !arp_stat_tx_w[0];      // ARP replies parity
  assign led_o[4] = !icmp_stat_tx_w[0];     // ICMP replies parity
  assign led_o[5] = !udp_stat_tx_w[0];      // UDP echoes parity

  assign dbg_mac_data_o = rx_stat_frames_w[7:0];
  assign dbg_ctrl_o     = {tx_stat_frames_w[7:0]};

endmodule

`endif // ETHERNET_TEST_04_TOP_SV
