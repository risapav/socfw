/**
 * @file        ethernet_test_echo.sv
 * @brief       Top-level pre eth_test_02: UDP echo test s RTL8211EG PHY.
 * @details     Prepaja ipreceive + udp_rx_ram_to_stream + eth_udp_echo_test +
 *              udp_tx_stream_to_ram + ipsend + crc do kompletneho echo systemu.
 *
 *              Tok dat:
 *                PHY RX -> ipreceive -> RX RAM -> udp_rx_ram_to_stream -> eth_udp_echo_test
 *                                                                               |
 *                PHY TX <- ipsend <- crc <- TX RAM <- udp_tx_stream_to_ram <---+
 *
 *              AXI-Lite pre eth_udp_echo_test je tie-off (ziadny CPU master).
 *              Echo modul bezi s DEFAULT_IP=BOARD_IP, DEFAULT_UDP_PORT=ECHO_PORT.
 *
 *              MAC filtrovanie: ipreceive prijima iba dst MAC 00:0A:35:01:FE:C0.
 *              Na PC: sudo arp -s <BOARD_IP> 00:0a:35:01:fe:c0
 *
 * @param BOARD_IP          IP adresa FPGA boardu
 * @param ECHO_PORT         UDP port pre echo
 * @param EXPECT_PREAMBLE   1=ipreceive ocakava preambulu+SFD (default),
 *                          0=prvy bajt GMII je uz destination MAC[0]
 * @param DEBUG_TIMER_TX_EN 1=ipsend vysiela periodicky bez echa (HW TX test),
 *                          0=normalne echo-triggerovane vysielanie (default)
 */
`ifndef ETHERNET_TEST_ECHO_SV
`define ETHERNET_TEST_ECHO_SV

`default_nettype none

module ethernet_test_echo #(
  parameter logic [31:0] BOARD_IP          = 32'hC0A81432, // 192.168.20.50
  parameter logic [15:0] ECHO_PORT         = 16'd8080,
  parameter bit          EXPECT_PREAMBLE   = 1'b1,
  parameter bit          DEBUG_TIMER_TX_EN = 1'b0
)(
  input  wire        rst_ni,          // async reset (active-low, from framework)
  input  wire        sys_clk_i,       // 50 MHz system clock
  input  wire        eth_rx_clk_i,    // GMII RX clock (PHY recovered, 125 MHz @ 1G)
  input  wire        eth_tx_clk_i,    // GMII TX clock (PLL 125 MHz)

  // GMII RX
  input  wire        eth_rx_dv_i,
  input  wire [7:0]  eth_rx_data_i,
  input  wire        eth_rx_er_i,

  // GMII TX
  output logic       eth_gtx_clk_o,
  output logic       eth_tx_en_o,
  output logic       eth_tx_er_o,
  output logic [7:0] eth_tx_data_o,

  // PHY management (MDIO stub)
  output logic       eth_mdc_o,
  inout  wire        eth_mdio_io,

  // PHY hardware reset (active-low, delayed release after power-on)
  output logic       eth_rst_no,

  // Diagnosticke LED
  output logic [5:0] status_led_o
);

  import axi_pkg::*;

  // ---------------------------------------------------------------------------
  // PHY reset: sys_clk counter, ~84 ms @ 50 MHz pred uvolnenim PHY resetu
  // ---------------------------------------------------------------------------
  logic [22:0] phy_rst_cnt_q;
  logic        phy_rst_done_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phy_rst_cnt_q  <= '0;
      phy_rst_done_q <= 1'b0;
    end else if (!phy_rst_done_q) begin
      phy_rst_cnt_q  <= phy_rst_cnt_q + 1'b1;
      phy_rst_done_q <= &phy_rst_cnt_q;  // 2^23 cyklov
    end
  end

  assign eth_rst_no    = phy_rst_done_q;
  assign eth_gtx_clk_o = eth_tx_clk_i;

  // MDIO/MDC — stub (nastavenia PHY ponechavame na defaultnych hodnotach)
  assign eth_mdc_o   = 1'b0;
  assign eth_mdio_io = 1'bz;

  // ---------------------------------------------------------------------------
  // ipreceive — GMII RX, zapisuje UDP payload do RX RAM
  // ---------------------------------------------------------------------------
  logic [47:0]  ipr_board_mac_w;
  logic [47:0]  ipr_pc_mac_w;
  logic [15:0]  ipr_ip_proto_w;
  logic         ipr_valid_ip_w;
  logic [159:0] ipr_ip_layer_w;
  logic [31:0]  ipr_pc_ip_w;
  logic [31:0]  ipr_board_ip_w;
  logic [63:0]  ipr_udp_layer_w;
  logic [31:0]  ipr_data_w;
  logic [15:0]  ipr_rx_total_len_w;
  logic         ipr_data_valid_w;
  logic [3:0]   ipr_rx_state_w;
  logic [15:0]  ipr_rx_data_len_w;
  logic [8:0]   ipr_ram_wr_addr_w;
  logic         ipr_data_receive_w;

  ipreceive #(
    .EXPECT_PREAMBLE (EXPECT_PREAMBLE)
  ) u_ipreceive (
    .clk_i             (eth_rx_clk_i),
    .rst_ni            (rst_ni),
    .rx_data_i         (eth_rx_data_i),
    .rx_dv_i           (eth_rx_dv_i),
    .rx_er_i           (eth_rx_er_i),
    .board_mac_o       (ipr_board_mac_w),
    .pc_mac_o          (ipr_pc_mac_w),
    .ip_protocol_o     (ipr_ip_proto_w),
    .valid_ip_p_o      (ipr_valid_ip_w),
    .ip_layer_o        (ipr_ip_layer_w),
    .pc_ip_o           (ipr_pc_ip_w),
    .board_ip_o        (ipr_board_ip_w),
    .udp_layer_o       (ipr_udp_layer_w),
    .data_o            (ipr_data_w),
    .rx_total_length_o (ipr_rx_total_len_w),
    .data_o_valid_o    (ipr_data_valid_w),
    .rx_state_o        (ipr_rx_state_w),
    .rx_data_length_o  (ipr_rx_data_len_w),
    .ram_wr_addr_o     (ipr_ram_wr_addr_w),
    .data_receive_o    (ipr_data_receive_w)
  );

  // ---------------------------------------------------------------------------
  // RX RAM — ipreceive zapisuje (rx_clk), udp_rx_ram_to_stream cita (tx_clk)
  // ---------------------------------------------------------------------------
  logic [8:0]  rx_ram_rd_addr_w;
  logic [31:0] rx_ram_rd_data_w;

  ram u_rx_ram (
    .clk_wr_i  (eth_rx_clk_i),
    .we_i      (ipr_data_valid_w),
    .addr_wr_i (ipr_ram_wr_addr_w),
    .data_i    (ipr_data_w),
    .clk_rd_i  (eth_tx_clk_i),
    .addr_rd_i (rx_ram_rd_addr_w),
    .data_o    (rx_ram_rd_data_w)
  );

  // ---------------------------------------------------------------------------
  // udp_rx_ram_to_stream — CDC + RAM -> byte stream pre echo modul
  // ---------------------------------------------------------------------------
  logic        rx_meta_valid_w;
  logic        rx_meta_ready_w;
  logic [31:0] rx_src_ip_w;
  logic [31:0] rx_dst_ip_w;
  logic [15:0] rx_src_port_w;
  logic [15:0] rx_dst_port_w;
  logic [15:0] rx_length_w;
  logic        rx_stream_valid_w;
  logic        rx_stream_ready_w;
  logic [7:0]  rx_stream_data_w;
  logic        rx_stream_last_w;

  udp_rx_ram_to_stream u_rx_to_stream (
    .rx_clk_i              (eth_rx_clk_i),
    .rst_ni                (rst_ni),
    .data_receive_i        (ipr_data_receive_w),
    .pc_ip_i               (ipr_pc_ip_w),
    .board_ip_i            (ipr_board_ip_w),
    .udp_layer_i           (ipr_udp_layer_w),
    .rx_data_length_i      (ipr_rx_data_len_w),
    .tx_clk_i              (eth_tx_clk_i),
    .ram_addr_o            (rx_ram_rd_addr_w),
    .ram_data_i            (rx_ram_rd_data_w),
    .udp_rx_meta_valid_o   (rx_meta_valid_w),
    .udp_rx_meta_ready_i   (rx_meta_ready_w),
    .udp_rx_src_ip_o       (rx_src_ip_w),
    .udp_rx_dst_ip_o       (rx_dst_ip_w),
    .udp_rx_src_port_o     (rx_src_port_w),
    .udp_rx_dst_port_o     (rx_dst_port_w),
    .udp_rx_length_o       (rx_length_w),
    .udp_rx_valid_o        (rx_stream_valid_w),
    .udp_rx_ready_i        (rx_stream_ready_w),
    .udp_rx_data_o         (rx_stream_data_w),
    .udp_rx_last_o         (rx_stream_last_w)
  );

  // ---------------------------------------------------------------------------
  // AXI-Lite tie-off pre eth_udp_echo_test (ziadny CPU master v eth_test_02)
  // ---------------------------------------------------------------------------
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_if (
    .ACLK    (eth_tx_clk_i),
    .ARESETn (rst_ni)
  );

  assign axil_if.AWVALID = 1'b0;
  assign axil_if.AWADDR  = '0;
  assign axil_if.AWPROT  = '0;
  assign axil_if.WVALID  = 1'b0;
  assign axil_if.WDATA   = '0;
  assign axil_if.WSTRB   = '0;
  assign axil_if.BREADY  = 1'b1;
  assign axil_if.ARVALID = 1'b0;
  assign axil_if.ARADDR  = '0;
  assign axil_if.ARPROT  = '0;
  assign axil_if.RREADY  = 1'b1;

  // ---------------------------------------------------------------------------
  // eth_udp_echo_test — echo FSM + AXI-Lite registre
  // ---------------------------------------------------------------------------
  logic        tx_meta_valid_w;
  logic        tx_meta_ready_w;
  logic [31:0] tx_dst_ip_w;
  logic [15:0] tx_dst_port_w;
  logic [15:0] tx_src_port_w;
  logic [15:0] tx_length_w;
  logic        tx_stream_valid_w;
  logic        tx_stream_ready_w;
  logic [7:0]  tx_stream_data_w;
  logic        tx_stream_last_w;

  eth_udp_echo_test #(
    .DEFAULT_IP       (BOARD_IP),
    .DEFAULT_UDP_PORT (ECHO_PORT)
  ) u_echo (
    .clk_i                  (eth_tx_clk_i),
    .rst_ni                 (rst_ni),
    .s_axil                 (axil_if),
    .udp_rx_meta_valid_i    (rx_meta_valid_w),
    .udp_rx_meta_ready_o    (rx_meta_ready_w),
    .udp_rx_src_ip_i        (rx_src_ip_w),
    .udp_rx_dst_ip_i        (rx_dst_ip_w),
    .udp_rx_src_port_i      (rx_src_port_w),
    .udp_rx_dst_port_i      (rx_dst_port_w),
    .udp_rx_length_i        (rx_length_w),
    .udp_rx_valid_i         (rx_stream_valid_w),
    .udp_rx_ready_o         (rx_stream_ready_w),
    .udp_rx_data_i          (rx_stream_data_w),
    .udp_rx_last_i          (rx_stream_last_w),
    .udp_tx_meta_valid_o    (tx_meta_valid_w),
    .udp_tx_meta_ready_i    (tx_meta_ready_w),
    .udp_tx_dst_ip_o        (tx_dst_ip_w),
    .udp_tx_dst_port_o      (tx_dst_port_w),
    .udp_tx_src_port_o      (tx_src_port_w),
    .udp_tx_length_o        (tx_length_w),
    .udp_tx_valid_o         (tx_stream_valid_w),
    .udp_tx_ready_i         (tx_stream_ready_w),
    .udp_tx_data_o          (tx_stream_data_w),
    .udp_tx_last_o          (tx_stream_last_w),
    .link_up_i              (1'b1),
    .irq_o                  ()
  );

  // ---------------------------------------------------------------------------
  // TX metadata latch + riadenie ipsend
  // ---------------------------------------------------------------------------
  logic [3:0] tx_state_w;
  wire        tx_busy_w = (tx_state_w != 4'd0);
  logic       tx_adapter_idle_w;

  // Meta handshake: akceptuj az ked TX adapter je volny a ipsend nevysiela
  assign tx_meta_ready_w = tx_adapter_idle_w && !tx_busy_w;

  // Latch TX metadata (dst_ip, porty) pri handshake pre ipsend
  logic [31:0] tx_dst_ip_q;
  logic [15:0] tx_dst_port_q;

  always_ff @(posedge eth_tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_dst_ip_q   <= 32'd0;
      tx_dst_port_q <= 16'd0;
    end else if (tx_meta_valid_w && tx_meta_ready_w) begin
      tx_dst_ip_q   <= tx_dst_ip_w;
      tx_dst_port_q <= tx_dst_port_w;
    end
  end

  // Start pulz pre TX adapter = meta handshake prebehol
  wire tx_adapter_start_w = tx_meta_valid_w && tx_meta_ready_w;

  // ---------------------------------------------------------------------------
  // TX RAM — udp_tx_stream_to_ram zapisuje, ipsend cita (oba eth_tx_clk_i)
  // ---------------------------------------------------------------------------
  logic [8:0]  tx_ram_wr_addr_w;
  logic [31:0] tx_ram_wr_data_w;
  logic        tx_ram_wr_we_w;
  logic [8:0]  tx_ram_rd_addr_w;
  logic [31:0] tx_ram_rd_data_w;

  ram u_tx_ram (
    .clk_wr_i  (eth_tx_clk_i),
    .we_i      (tx_ram_wr_we_w),
    .addr_wr_i (tx_ram_wr_addr_w),
    .data_i    (tx_ram_wr_data_w),
    .clk_rd_i  (eth_tx_clk_i),
    .addr_rd_i (tx_ram_rd_addr_w),
    .data_o    (tx_ram_rd_data_w)
  );

  // ---------------------------------------------------------------------------
  // udp_tx_stream_to_ram — echo byte stream -> TX RAM -> ipsend trigger
  // ---------------------------------------------------------------------------
  logic        tx_start_w;
  logic [15:0] tx_data_length_w;
  logic [15:0] tx_total_length_w;

  udp_tx_stream_to_ram u_tx_to_ram (
    .clk_i             (eth_tx_clk_i),
    .rst_ni            (rst_ni),
    .start_i           (tx_adapter_start_w),
    .valid_i           (tx_stream_valid_w),
    .ready_o           (tx_stream_ready_w),
    .data_i            (tx_stream_data_w),
    .last_i            (tx_stream_last_w),
    .ram_wr_addr_o     (tx_ram_wr_addr_w),
    .ram_wr_data_o     (tx_ram_wr_data_w),
    .ram_wr_we_o       (tx_ram_wr_we_w),
    .tx_start_o        (tx_start_w),
    .tx_data_length_o  (tx_data_length_w),
    .tx_total_length_o (tx_total_length_w),
    .idle_o            (tx_adapter_idle_w),
    .tx_busy_i         (tx_busy_w)
  );

  // ---------------------------------------------------------------------------
  // ipsend + crc — TX path (eth_tx_clk_i)
  // ---------------------------------------------------------------------------
  logic [31:0] crc_next_w;
  logic [31:0] crc_w;
  logic        crc_rst_nw;
  logic        crc_en_w;

  ipsend u_ipsend (
    .clk_i             (eth_tx_clk_i),
    .rst_ni            (rst_ni),
    .tx_en_o           (eth_tx_en_o),
    .tx_er_o           (eth_tx_er_o),
    .tx_data_o         (eth_tx_data_o),
    .crc_i             (crc_next_w),
    .ram_rd_data_i     (tx_ram_rd_data_w),
    .crc_en_o          (crc_en_w),
    .crc_rst_no        (crc_rst_nw),
    .tx_state_o        (tx_state_w),
    .tx_data_length_i  (tx_data_length_w),
    .tx_total_length_i (tx_total_length_w),
    .ram_rd_addr_o     (tx_ram_rd_addr_w),
    .tx_src_ip_i       (BOARD_IP),
    .tx_dst_ip_i       (tx_dst_ip_q),
    .tx_src_port_i     (ECHO_PORT),
    .tx_dst_port_i     (tx_dst_port_q),
    .tx_start_i        (tx_start_w),
    .timer_en_i        (DEBUG_TIMER_TX_EN)
  );

  crc u_crc (
    .clk_i      (eth_tx_clk_i),
    .rst_ni     (crc_rst_nw),
    .data_i     (eth_tx_data_o),
    .en_i       (crc_en_w),
    .crc_o      (crc_w),
    .crc_next_o (crc_next_w)
  );

  // ---------------------------------------------------------------------------
  // Diagnosticke LED (heartbeat, PHY reset, RX/TX aktivita)
  // ---------------------------------------------------------------------------
  eth_status_leds #(
    .SYS_CLK_HZ     (50_000_000),
    .LED_COUNT      (6),
    .LED_ACTIVE_LOW (1'b0)
  ) u_leds (
    .sys_clk_i           (sys_clk_i),
    .eth_rx_clk_i        (eth_rx_clk_i),
    .eth_tx_clk_i        (eth_tx_clk_i),
    .rst_ni              (rst_ni),
    .phy_reset_done_i    (phy_rst_done_q),
    .eth_rx_dv_i         (eth_rx_dv_i),
    .ipr_data_receive_i  (ipr_data_receive_w),
    .tx_start_i          (tx_start_w),
    .eth_tx_en_i         (eth_tx_en_o),
    .led_o               (status_led_o)
  );

endmodule

`endif // ETHERNET_TEST_ECHO_SV
