/**
 * @file        ethernet_test_echo.sv
 * @brief       GMII Ethernet UDP echo modul pre eth_test_02.
 * @details     Prijima UDP pakety (ipreceive, eth_rx_clk), bufferuje payload
 *              do rx_ram (dual-port CDC), cez udp_rx_ram_to_stream streamuje
 *              do echo FSM, zapisuje do tx_ram a odosila spat (ipsend, eth_tx_clk).
 *              PHY reset counter bezi v eth_tx_clk domene (PLL-zavisly).
 *
 * @param EXPECT_PREAMBLE  1 = ocakava preambulu + SFD pred MAC (GMII standard)
 * @param BOARD_IP         Zachovane pre kompatibilitu (IP berie z ipreceive)
 * @param ECHO_PORT        Zachovane pre kompatibilitu (port berie z prijateho ramca)
 */
`ifndef ETHERNET_TEST_ECHO_SV
`define ETHERNET_TEST_ECHO_SV

`default_nettype none

module ethernet_test_echo #(
  parameter bit          EXPECT_PREAMBLE = 1'b1,
  parameter logic [31:0] BOARD_IP        = 32'hC0A81432,
  parameter logic [15:0] ECHO_PORT       = 16'd8080
)(
  input  wire        rst_ni,
  input  wire        sys_clk_i,
  input  wire        eth_rx_clk_i,
  input  wire        eth_tx_clk_i,

  input  wire        eth_rx_dv_i,
  input  wire [7:0]  eth_rx_data_i,
  input  wire        eth_rx_er_i,

  output logic       eth_gtx_clk_o,
  output logic       eth_tx_en_o,
  output logic       eth_tx_er_o,
  output logic [7:0] eth_tx_data_o,

  output logic       eth_mdc_o,
  inout  wire        eth_mdio_io,

  output logic       eth_rst_no,

  output logic [5:0] status_led_o
);

  // -------------------------------------------------------------------------
  // PHY reset: counter v eth_tx_clk domene (PLL vystup)
  // Counter bezi len ked PLL generuje eth_tx_clk_i => implicitny lock gate
  // 2^23 / 125 MHz = 67 ms
  // -------------------------------------------------------------------------
  logic [22:0] phy_rst_cnt_q;
  logic        phy_rst_done_q;

  always_ff @(posedge eth_tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phy_rst_cnt_q  <= '0;
      phy_rst_done_q <= 1'b0;
    end else if (!phy_rst_done_q) begin
      phy_rst_cnt_q <= phy_rst_cnt_q + 1'b1;
      if (&phy_rst_cnt_q)
        phy_rst_done_q <= 1'b1;
    end
  end

  assign eth_rst_no    = phy_rst_done_q;
  assign eth_gtx_clk_o = eth_tx_clk_i;

  // -------------------------------------------------------------------------
  // MDIO init: po PHY resete zapise GBCR(reg9)+BMCR(reg0) -> restart ANEG
  // Bez tohto RTL8211EG na QMTech oglasi len 10Mbps (HW strapping) a
  // RXDV nikdy neasertuje napriek fyzicky prijatym ramcom.
  // -------------------------------------------------------------------------
  logic mdio_o_w;
  logic mdio_oe_w;

  mdio_init #(
    .CLK_HZ    (125_000_000),
    .MDC_DIV   (62),
    .PHYAD     (5'd1)
  ) u_mdio_init (
    .clk_i          (eth_tx_clk_i),
    .rst_ni         (rst_ni),
    .phy_rst_done_i (phy_rst_done_q),
    .mdc_o          (eth_mdc_o),
    .mdio_o         (mdio_o_w),
    .mdio_oe_o      (mdio_oe_w)
  );

  assign eth_mdio_io = mdio_oe_w ? mdio_o_w : 1'bz;

  // -------------------------------------------------------------------------
  // ipreceive: GMII RX parser (eth_rx_clk domena)
  // Akceptuje ramce s cielovym MAC 00:0A:35:01:FE:C0, parsuje IPv4/UDP
  // -------------------------------------------------------------------------
  logic [31:0] ipr_pc_ip_w;
  logic [31:0] ipr_board_ip_w;
  logic [63:0] ipr_udp_layer_w;
  logic [31:0] ipr_data_w;
  logic [15:0] ipr_rx_data_len_w;
  logic        ipr_data_valid_w;
  logic [8:0]  ipr_ram_wr_addr_w;
  logic        ipr_data_receive_w;

  ipreceive #(
    .EXPECT_PREAMBLE (EXPECT_PREAMBLE)
  ) u_rx (
    .clk_i             (eth_rx_clk_i),
    .rst_ni            (rst_ni),
    .rx_data_i         (eth_rx_data_i),
    .rx_dv_i           (eth_rx_dv_i),
    .rx_er_i           (eth_rx_er_i),
    .board_mac_o       (),
    .pc_mac_o          (),
    .ip_protocol_o     (),
    .valid_ip_p_o      (),
    .ip_layer_o        (),
    .pc_ip_o           (ipr_pc_ip_w),
    .board_ip_o        (ipr_board_ip_w),
    .udp_layer_o       (ipr_udp_layer_w),
    .data_o            (ipr_data_w),
    .rx_total_length_o (),
    .data_o_valid_o    (ipr_data_valid_w),
    .rx_state_o        (),
    .rx_data_length_o  (ipr_rx_data_len_w),
    .ram_wr_addr_o     (ipr_ram_wr_addr_w),
    .data_receive_o    (ipr_data_receive_w)
  );

  // -------------------------------------------------------------------------
  // RX RAM: ipreceive zapise (eth_rx_clk), udp_rx_ram_to_stream cita (eth_tx_clk)
  // -------------------------------------------------------------------------
  logic [8:0]  rx_ram_rd_addr_w;
  logic [31:0] rx_ram_rd_data_w;

  ram #(
    .DATA_WIDTH (32),
    .ADDR_WIDTH (9)
  ) u_rx_ram (
    .clk_wr_i  (eth_rx_clk_i),
    .we_i      (ipr_data_valid_w),
    .addr_wr_i (ipr_ram_wr_addr_w),
    .data_i    (ipr_data_w),
    .clk_rd_i  (eth_tx_clk_i),
    .addr_rd_i (rx_ram_rd_addr_w),
    .data_o    (rx_ram_rd_data_w)
  );

  // -------------------------------------------------------------------------
  // udp_rx_ram_to_stream: CDC most + RAM reader (eth_tx_clk domena)
  // Synchronizuje data_receive_i (rx_clk), latchuje metadata, streamuje bajty
  // -------------------------------------------------------------------------
  logic        udp_rx_meta_valid_w;
  logic        udp_rx_meta_ready_w;
  logic [31:0] udp_rx_src_ip_w;
  logic [31:0] udp_rx_dst_ip_w;
  logic [15:0] udp_rx_src_port_w;
  logic [15:0] udp_rx_dst_port_w;
  logic [15:0] udp_rx_length_w;
  logic        udp_rx_valid_w;
  logic        udp_rx_ready_w;
  logic [7:0]  udp_rx_data_w;
  logic        udp_rx_last_w;

  udp_rx_ram_to_stream u_rx_stream (
    .rx_clk_i            (eth_rx_clk_i),
    .rst_ni              (rst_ni),
    .data_receive_i      (ipr_data_receive_w),
    .pc_ip_i             (ipr_pc_ip_w),
    .board_ip_i          (ipr_board_ip_w),
    .udp_layer_i         (ipr_udp_layer_w),
    .rx_data_length_i    (ipr_rx_data_len_w),
    .tx_clk_i            (eth_tx_clk_i),
    .ram_addr_o          (rx_ram_rd_addr_w),
    .ram_data_i          (rx_ram_rd_data_w),
    .udp_rx_meta_valid_o (udp_rx_meta_valid_w),
    .udp_rx_meta_ready_i (udp_rx_meta_ready_w),
    .udp_rx_src_ip_o     (udp_rx_src_ip_w),
    .udp_rx_dst_ip_o     (udp_rx_dst_ip_w),
    .udp_rx_src_port_o   (udp_rx_src_port_w),
    .udp_rx_dst_port_o   (udp_rx_dst_port_w),
    .udp_rx_length_o     (udp_rx_length_w),
    .udp_rx_valid_o      (udp_rx_valid_w),
    .udp_rx_ready_i      (udp_rx_ready_w),
    .udp_rx_data_o       (udp_rx_data_w),
    .udp_rx_last_o       (udp_rx_last_w)
  );

  // -------------------------------------------------------------------------
  // Echo FSM (eth_tx_clk domena)
  // Latchuje metadata a prepojuje payload stream rx->tx.
  // Caka na tx_stream_idle pred spustenim novej echoe.
  // -------------------------------------------------------------------------
  logic        echo_active_q;
  logic [31:0] echo_src_ip_q;
  logic [31:0] echo_dst_ip_q;
  logic [15:0] echo_src_port_q;
  logic [15:0] echo_dst_port_q;

  logic        tx_stream_idle_w;
  logic        tx_stream_start_w;
  logic        tx_stream_ready_w;

  always_ff @(posedge eth_tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      echo_active_q   <= 1'b0;
      echo_src_ip_q   <= 32'd0;
      echo_dst_ip_q   <= 32'd0;
      echo_src_port_q <= 16'd0;
      echo_dst_port_q <= 16'd0;
    end else begin
      if (!echo_active_q && udp_rx_meta_valid_w && tx_stream_idle_w) begin
        echo_active_q   <= 1'b1;
        echo_src_ip_q   <= udp_rx_dst_ip_w;   // board IP -> echo src
        echo_dst_ip_q   <= udp_rx_src_ip_w;   // PC IP   -> echo dst
        echo_src_port_q <= udp_rx_dst_port_w; // board port -> echo src port
        echo_dst_port_q <= udp_rx_src_port_w; // PC port    -> echo dst port
      end else if (echo_active_q && udp_rx_valid_w && udp_rx_last_w
                   && udp_rx_ready_w) begin
        echo_active_q <= 1'b0;
      end
    end
  end

  // Kombinacne: akceptuj meta + spusti tx_stream v rovnakom cykle
  assign udp_rx_meta_ready_w = !echo_active_q && udp_rx_meta_valid_w && tx_stream_idle_w;
  assign tx_stream_start_w   = !echo_active_q && udp_rx_meta_valid_w && tx_stream_idle_w;
  assign udp_rx_ready_w      = echo_active_q ? tx_stream_ready_w : 1'b0;

  // -------------------------------------------------------------------------
  // udp_tx_stream_to_ram: pakuje bajty streamu do TX RAM (eth_tx_clk domena)
  // -------------------------------------------------------------------------
  logic [8:0]  tx_ram_wr_addr_w;
  logic [31:0] tx_ram_wr_data_w;
  logic        tx_ram_wr_we_w;
  logic        ipsend_start_w;
  logic [15:0] ipsend_data_len_w;
  logic [15:0] ipsend_total_len_w;
  logic [3:0]  ipsend_state_w;

  wire ipsend_busy_w = (ipsend_state_w != 4'd0);

  udp_tx_stream_to_ram u_tx_stream (
    .clk_i             (eth_tx_clk_i),
    .rst_ni            (rst_ni),
    .start_i           (tx_stream_start_w),
    .valid_i           (echo_active_q ? udp_rx_valid_w  : 1'b0),
    .ready_o           (tx_stream_ready_w),
    .data_i            (udp_rx_data_w),
    .last_i            (udp_rx_last_w),
    .ram_wr_addr_o     (tx_ram_wr_addr_w),
    .ram_wr_data_o     (tx_ram_wr_data_w),
    .ram_wr_we_o       (tx_ram_wr_we_w),
    .tx_start_o        (ipsend_start_w),
    .tx_data_length_o  (ipsend_data_len_w),
    .tx_total_length_o (ipsend_total_len_w),
    .idle_o            (tx_stream_idle_w),
    .tx_busy_i         (ipsend_busy_w)
  );

  // -------------------------------------------------------------------------
  // TX RAM: tx_stream zapise + ipsend cita (oboje eth_tx_clk domena)
  // -------------------------------------------------------------------------
  logic [8:0]  tx_ram_rd_addr_w;
  logic [31:0] tx_ram_rd_data_w;

  ram #(
    .DATA_WIDTH (32),
    .ADDR_WIDTH (9)
  ) u_tx_ram (
    .clk_wr_i  (eth_tx_clk_i),
    .we_i      (tx_ram_wr_we_w),
    .addr_wr_i (tx_ram_wr_addr_w),
    .data_i    (tx_ram_wr_data_w),
    .clk_rd_i  (eth_tx_clk_i),
    .addr_rd_i (tx_ram_rd_addr_w),
    .data_o    (tx_ram_rd_data_w)
  );

  // -------------------------------------------------------------------------
  // CRC modul (eth_tx_clk domena)
  // Reset riadi ipsend cez crc_rst_no; data_i cita eth_tx_data_o (registered)
  // -------------------------------------------------------------------------
  logic [31:0] crc_val_w;
  logic        crc_en_w;
  logic        crc_rst_n_w;

  crc u_crc (
    .clk_i      (eth_tx_clk_i),
    .rst_ni     (crc_rst_n_w),
    .data_i     (eth_tx_data_o),
    .en_i       (crc_en_w),
    .crc_o      (crc_val_w),
    .crc_next_o ()
  );

  // -------------------------------------------------------------------------
  // ipsend: GMII TX MAC (eth_tx_clk domena)
  // Spusteny ipsend_start_w; timer_en=0 (len echo rezim, bez periodickeho TX)
  // -------------------------------------------------------------------------
  ipsend u_tx (
    .clk_i             (eth_tx_clk_i),
    .rst_ni            (rst_ni),
    .tx_en_o           (eth_tx_en_o),
    .tx_er_o           (eth_tx_er_o),
    .tx_data_o         (eth_tx_data_o),
    .crc_i             (crc_val_w),
    .ram_rd_data_i     (tx_ram_rd_data_w),
    .crc_en_o          (crc_en_w),
    .crc_rst_no        (crc_rst_n_w),
    .tx_state_o        (ipsend_state_w),
    .tx_data_length_i  (ipsend_data_len_w),
    .tx_total_length_i (ipsend_total_len_w),
    .ram_rd_addr_o     (tx_ram_rd_addr_w),
    .tx_src_ip_i       (echo_src_ip_q),
    .tx_dst_ip_i       (echo_dst_ip_q),
    .tx_src_port_i     (echo_src_port_q),
    .tx_dst_port_i     (echo_dst_port_q),
    .tx_start_i        (ipsend_start_w),
    .timer_en_i        (1'b0)
  );

  // -------------------------------------------------------------------------
  // Diagnosticke LED
  // LED0 = heartbeat, LED1 = PHY reset done, LED2 = RXDV
  // LED3 = ipreceive hotovy, LED4 = echo TX start, LED5 = TXEN aktivita
  // -------------------------------------------------------------------------
  eth_status_leds #(
    .SYS_CLK_HZ     (50_000_000),
    .LED_COUNT      (6),
    .LED_ACTIVE_LOW (1'b1)
  ) u_leds (
    .sys_clk_i          (sys_clk_i),
    .eth_rx_clk_i       (eth_rx_clk_i),
    .eth_tx_clk_i       (eth_tx_clk_i),
    .rst_ni             (rst_ni),
    .phy_reset_done_i   (phy_rst_done_q),
    .eth_rx_dv_i        (eth_rx_dv_i),
    .ipr_data_receive_i (ipr_data_receive_w),
    .tx_start_i         (ipsend_start_w),
    .eth_tx_en_i        (eth_tx_en_o),
    .led_o              (status_led_o)
  );

endmodule

`endif // ETHERNET_TEST_ECHO_SV
