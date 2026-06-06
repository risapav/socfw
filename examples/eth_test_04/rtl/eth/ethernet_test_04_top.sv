/**
 * @file ethernet_test_04_top.sv
 * @brief Ethernet echo top: eth_rx_mac -> async FIFOs (CDC) -> eth_echo_app -> eth_tx_mac.
 * @param LOCAL_MAC  48-bit FPGA MAC address used for RX filter and TX source MAC.
 * @details RX MAC clocked by eth_rx_clk_i (125 MHz PHY recovered clock).
 *   TX chain (echo_app + TX MAC) clocked by eth_tx_clk_i (125 MHz PLL).
 *   Two async FIFOs bridge the clock domains:
 *     payload_fifo: DATA_WIDTH=10 ({tuser,tlast,tdata}), DEPTH=2048
 *     meta_fifo:    DATA_WIDTH=113 ({fcs_ok,dst_mac,src_mac,eth_type}), DEPTH=8
 *   GTX_CLK: altddio_out with invert_output="ON" on eth_tx_clk_i (T/2 phase shift).
 *   PHY reset: 24-bit counter at 50 MHz sys_clk_i (~336 ms deassert delay).
 *   LED: heartbeat, phy_reset, rx_frame_cnt[0], echo_cnt[0], rx_activity, tx_activity.
 */
`ifndef ETHERNET_TEST_04_TOP_SV
`define ETHERNET_TEST_04_TOP_SV

`default_nettype none

module ethernet_test_04_top #(
  parameter logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0
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
  //J10
  output      logic [7:0]  dbg_mac_data_o,
  //J11
  output      logic [7:0]  dbg_ctrl_o,
  output      logic        uart_tap_tx_o,
  input  wire logic [3:0]  btn_i
);

  // btn_i[3] as SW reset (active-low, matches board button polarity)
  logic rst_w;
  assign rst_w = rst_ni && btn_i[3];

  // TX-domain reset: 2-FF sync (async assert, sync deassert into eth_tx_clk_i)
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

  // MDC/MDIO idle
  assign eth_mdc_o   = 1'b0;
  assign eth_mdio_io = 1'bz;

  // -------------------------------------------------------------------------
  // GTX_CLK: altddio_out, invert_output="ON" -> 125 MHz shifted by T/2
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
  // GMII RX input sampling: altddio_in with invert_input_clocks="ON"
  // captures on falling edge of eth_rx_clk_i to meet RXD[3:0] setup time.
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
  logic        rx_tready_w;     // = pfifo write ready (overflow detect)
  logic        rx_tlast_w;
  logic        rx_tuser_w;

  logic        rx_meta_valid_w;
  logic        rx_meta_ready_w; // = mfifo write ready
  logic [47:0] rx_meta_dst_mac_w;
  logic [47:0] rx_meta_src_mac_w;
  logic [15:0] rx_meta_eth_type_w;
  logic        rx_meta_fcs_ok_w;
  logic        rx_meta_mac_ok_w;

  logic [15:0] rx_stat_frames_w;
  logic [15:0] rx_stat_drop_w;
  logic        rx_stat_overflow_w;

  // -------------------------------------------------------------------------
  // Payload async FIFO wires
  //   write side: eth_rx_clk_i  (from eth_rx_mac)
  //   read  side: eth_tx_clk_i  (to eth_echo_app s_axis)
  // -------------------------------------------------------------------------
  localparam int PAYLOAD_W = 10;  // {tuser, tlast, tdata}
  logic [PAYLOAD_W-1:0] pfifo_wr_w;
  logic                 pfifo_wr_ready_w;
  logic [PAYLOAD_W-1:0] pfifo_rd_w;
  logic                 pfifo_rd_valid_w;
  logic                 pfifo_rd_ready_w;  // driven by echo_app s_axis_tready_o

  logic [7:0]  pfifo_tdata_w;
  logic        pfifo_tlast_w;
  logic        pfifo_tuser_w;

  assign pfifo_wr_w                        = {rx_tuser_w, rx_tlast_w, rx_tdata_w};
  assign {pfifo_tuser_w, pfifo_tlast_w, pfifo_tdata_w} = pfifo_rd_w;
  assign rx_tready_w                       = pfifo_wr_ready_w;

  // -------------------------------------------------------------------------
  // Meta async FIFO wires
  //   {fcs_ok[1], dst_mac[48], src_mac[48], eth_type[16]} = 113 bits
  //   write side: eth_rx_clk_i  (from eth_rx_mac)
  //   read  side: eth_tx_clk_i  (to eth_echo_app s_meta)
  // -------------------------------------------------------------------------
  localparam int META_W = 113;
  logic [META_W-1:0] mfifo_wr_w;
  logic              mfifo_wr_ready_w;
  logic [META_W-1:0] mfifo_rd_w;
  logic              mfifo_rd_valid_w;
  logic              mfifo_rd_ready_w;  // driven by echo_app s_meta_ready_o

  logic        meta_fcs_ok_w;
  logic [47:0] meta_dst_mac_w;
  logic [47:0] meta_src_mac_w;
  logic [15:0] meta_eth_type_w;

  assign mfifo_wr_w   = {rx_meta_fcs_ok_w, rx_meta_dst_mac_w,
                         rx_meta_src_mac_w, rx_meta_eth_type_w};
  assign rx_meta_ready_w = mfifo_wr_ready_w;
  assign {meta_fcs_ok_w, meta_dst_mac_w,
          meta_src_mac_w, meta_eth_type_w} = mfifo_rd_w;

  // -------------------------------------------------------------------------
  // eth_echo_app outputs -> eth_tx_mac inputs (eth_tx_clk_i domain)
  // -------------------------------------------------------------------------
  logic [7:0]  txm_tdata_w;
  logic        txm_tvalid_w;
  logic        txm_tready_w;   // from TX MAC s_axis_tready_o
  logic        txm_tlast_w;
  logic        txm_tuser_w;

  logic        txm_meta_valid_w;
  logic        txm_meta_ready_w;  // from TX MAC s_meta_ready_o
  logic [47:0] txm_meta_dst_mac_w;
  logic [47:0] txm_meta_src_mac_w;
  logic [15:0] txm_meta_eth_type_w;

  logic [15:0] echo_stat_echo_w;
  logic [15:0] echo_stat_discard_w;
  logic [15:0] tx_stat_frames_w;
  logic [15:0] tx_stat_underflow_w;

  // -------------------------------------------------------------------------
  // Sticky payload overflow flag (eth_rx_clk_i domain)
  // -------------------------------------------------------------------------
  logic overflow_sticky_q;
  always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
    if (!rst_w) overflow_sticky_q <= 1'b0;
    else if (rx_tvalid_w && !pfifo_wr_ready_w) overflow_sticky_q <= 1'b1;
  end

  // -------------------------------------------------------------------------
  // RX MAC (eth_rx_clk_i domain)
  // -------------------------------------------------------------------------
  eth_rx_mac #(
    .LOCAL_MAC       (LOCAL_MAC),
    .ACCEPT_BROADCAST(1'b1),
    .ACCEPT_MULTICAST(1'b0),
    .MAX_FRAME_LEN   (1518)
  ) u_rx_mac (
    .clk_i          (eth_rx_clk_i),
    .rst_ni         (rst_w),
    .gmii_rx_dv_i   (rxdv_s_w),
    .gmii_rx_er_i   (rxer_s_w),
    .gmii_rxd_i     (rxd_s_w),
    .m_axis_tdata   (rx_tdata_w),
    .m_axis_tvalid  (rx_tvalid_w),
    .m_axis_tready  (rx_tready_w),
    .m_axis_tlast   (rx_tlast_w),
    .m_axis_tuser   (rx_tuser_w),
    .m_meta_valid   (rx_meta_valid_w),
    .m_meta_ready   (rx_meta_ready_w),
    .m_meta_dst_mac (rx_meta_dst_mac_w),
    .m_meta_src_mac (rx_meta_src_mac_w),
    .m_meta_eth_type(rx_meta_eth_type_w),
    .m_meta_fcs_ok  (rx_meta_fcs_ok_w),
    .m_meta_mac_ok  (rx_meta_mac_ok_w),
    .stat_overflow  (rx_stat_overflow_w),
    .stat_rx_frames (rx_stat_frames_w),
    .stat_rx_drop   (rx_stat_drop_w)
  );

  // -------------------------------------------------------------------------
  // Payload async FIFO (DEPTH=2048 fits max 1518-byte frame)
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
  // Meta async FIFO (DEPTH=8 for up to 8 in-flight frames)
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

  // -------------------------------------------------------------------------
  // Echo application (eth_tx_clk_i domain)
  // -------------------------------------------------------------------------
  eth_echo_app #(
    .LOCAL_MAC (LOCAL_MAC)
  ) u_echo_app (
    .clk_i               (eth_tx_clk_i),
    .rst_ni              (rst_tx_w),
    .s_meta_valid_i      (mfifo_rd_valid_w),
    .s_meta_ready_o      (mfifo_rd_ready_w),
    .s_meta_fcs_ok_i     (meta_fcs_ok_w),
    .s_meta_dst_mac_i    (meta_dst_mac_w),
    .s_meta_src_mac_i    (meta_src_mac_w),
    .s_meta_eth_type_i   (meta_eth_type_w),
    .s_axis_tdata_i      (pfifo_tdata_w),
    .s_axis_tvalid_i     (pfifo_rd_valid_w),
    .s_axis_tready_o     (pfifo_rd_ready_w),
    .s_axis_tlast_i      (pfifo_tlast_w),
    .s_axis_tuser_i      (pfifo_tuser_w),
    .m_meta_valid_o      (txm_meta_valid_w),
    .m_meta_ready_i      (txm_meta_ready_w),
    .m_meta_dst_mac_o    (txm_meta_dst_mac_w),
    .m_meta_src_mac_o    (txm_meta_src_mac_w),
    .m_meta_eth_type_o   (txm_meta_eth_type_w),
    .m_axis_tdata_o      (txm_tdata_w),
    .m_axis_tvalid_o     (txm_tvalid_w),
    .m_axis_tready_i     (txm_tready_w),
    .m_axis_tlast_o      (txm_tlast_w),
    .m_axis_tuser_o      (txm_tuser_w),
    .stat_echo_frames    (echo_stat_echo_w),
    .stat_discard_frames (echo_stat_discard_w)
  );

  // -------------------------------------------------------------------------
  // TX MAC (eth_tx_clk_i domain)
  // -------------------------------------------------------------------------
  eth_tx_mac #(
    .IFG_CYCLES (12)
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
    .stat_tx_underflow (tx_stat_underflow_w)
  );

  // -------------------------------------------------------------------------
  // Raw GMII tap (eth_rx_clk_i domain): captures 32 bytes after SFD for
  // direct comparison with Wireshark to isolate PHY vs RTL data corruption.
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
  // Heartbeat counter (eth_rx_clk_i, 27-bit => ~1.07 s period)
  // -------------------------------------------------------------------------
  logic [26:0] hb_cnt_q;
  always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
    if (!rst_w) hb_cnt_q <= '0;
    else        hb_cnt_q <= hb_cnt_q + 27'd1;
  end

  // LED (active-low on QMTech board)
  assign led_o[0] = !hb_cnt_q[26];              // ~1 Hz heartbeat
  assign led_o[1] = !eth_phyrstb_o;             // PHY in reset = LED on
  assign led_o[2] = !rx_stat_frames_w[0];       // RX frame parity
  assign led_o[3] = !echo_stat_echo_w[0];       // echoed frame parity
  assign led_o[4] = !eth_rxdv_i;                // RX activity
  assign led_o[5] = !eth_txen_o;                // TX activity

  // Debug bus (acceptable cross-domain for debug LEDs/counters)
  // dbg_ctrl_o[7]: last RX MAC match result; [6:0]: TX frame counter low bits
  assign dbg_mac_data_o = rx_stat_frames_w[7:0];
  assign dbg_ctrl_o     = {rx_meta_mac_ok_w, tx_stat_frames_w[6:0]};

endmodule

`endif // ETHERNET_TEST_04_TOP_SV
