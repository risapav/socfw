/**
 * @file        eth_status_leds.sv
 * @brief       Diagnosticke LED indikatory pre Ethernet/PHY stav.
 * @details     6 LED indikatorov (pri LED_COUNT=6):
 *              LED0 = heartbeat zo SYS_CLK (1 Hz blikanie = FPGA zije)
 *              LED1 = PHY reset uvolneny (phy_reset_done_i assertovany)
 *              LED2 = ETH_RXC heartbeat (bliká ~1Hz ak eth_rx_clk_i bezi)
 *              LED3 = RXDV aktivita (eth_rx_dv_i, stretched)
 *              LED4 = ipreceive hotovy (ipr_data_receive_i pulse, stretched)
 *              LED5 = ETH TX aktivita (eth_tx_en_i, stretched)
 *
 *              Diagnosticka logika (krokovy debug):
 *                LED2 nebliká: ETH_RXC vobec neprúdi (PIN/clock routing problem).
 *                LED2 bliká, LED3 nie: RXC bezi, PHY nevysila RXDV (link/PHY config).
 *                LED3 bliká, LED4 nie: RXDV OK, ipreceive neakceptuje ramec
 *                  (MAC filter, preambula/SFD, zly format).
 *                LED4 bliká, LED5 nie: ipreceive OK, echo FSM/ipsend nefunguje.
 *                LED5 bliká, PC nic nevidí: fyzický TX problem (GTX_CLK, timing).
 *
 *              ipr_data_receive_i je 1-cyklovy pulz v eth_rx_clk_i domene.
 *              tx_start_i je zachovany na porte ale nepouziva sa pre LED vystupy.
 *              Vsetky signaly sa synchronizuju do sys_clk_i cez cdc_two_flop_synchronizer.
 *
 * @param SYS_CLK_HZ     Frekvencia sys_clk_i v Hz
 * @param LED_COUNT      Pocet LED (default 6)
 * @param LED_ACTIVE_LOW 1=LED svietia pri 0, 0=LED svietia pri 1
 * @param ACTIVITY_MS    Dlzka stretch okna v ms (default 80)
 */
`ifndef ETH_STATUS_LEDS_SV
`define ETH_STATUS_LEDS_SV

`default_nettype none

module eth_status_leds #(
  parameter int SYS_CLK_HZ     = 50_000_000,
  parameter int LED_COUNT      = 6,
  parameter bit LED_ACTIVE_LOW = 1'b0,
  parameter int ACTIVITY_MS    = 80
) (
  input  wire                  sys_clk_i,
  input  wire                  eth_rx_clk_i,
  input  wire                  eth_tx_clk_i,
  input  wire                  rst_ni,
  input  wire                  phy_reset_done_i,
  input  wire                  eth_rx_dv_i,
  input  wire                  ipr_data_receive_i,  // rx_clk domain, 1-cycle pulse
  input  wire                  tx_start_i,          // tx_clk domain, nepoužíva sa pre LED
  input  wire                  eth_tx_en_i,
  output logic [LED_COUNT-1:0] led_o
);

  // -------------------------------------------------------------------------
  // LED0: heartbeat — 1 Hz blikanie v sys_clk domene
  // -------------------------------------------------------------------------
  localparam int HB_DIV = SYS_CLK_HZ / 2;
  localparam int HB_W   = $clog2(HB_DIV + 1);

  logic [HB_W-1:0] hb_cnt_q;
  logic            hb_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hb_cnt_q <= '0;
      hb_q     <= 1'b0;
    end else begin
      if (hb_cnt_q == HB_W'(HB_DIV - 1)) begin
        hb_cnt_q <= '0;
        hb_q     <= ~hb_q;
      end else begin
        hb_cnt_q <= hb_cnt_q + 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // LED2: ETH_RXC heartbeat — free-running counter v eth_rx_clk_i domene
  // Bit 26 toggleuje pri 125 MHz kazdych 2^26 cyklov = ~0.93 Hz
  // -------------------------------------------------------------------------
  logic [26:0] rxc_cnt_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rxc_cnt_q <= '0;
    end else begin
      rxc_cnt_q <= rxc_cnt_q + 1'b1;
    end
  end

  logic rxc_hb_sync_w;

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_rxc_sync (
    .clk_i  (sys_clk_i),
    .rst_ni (rst_ni),
    .d_i    (rxc_cnt_q[26]),
    .q_o    (rxc_hb_sync_w)
  );

  // -------------------------------------------------------------------------
  // LED3: toggles v rx_clk domene — RXDV rising edge + ipr_data_receive pulse
  // -------------------------------------------------------------------------
  logic rx_dv_prev_q;
  logic rx_tog_q;
  logic ipr_tog_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_dv_prev_q <= 1'b0;
      rx_tog_q     <= 1'b0;
      ipr_tog_q    <= 1'b0;
    end else begin
      rx_dv_prev_q <= eth_rx_dv_i;
      if (eth_rx_dv_i & ~rx_dv_prev_q)
        rx_tog_q <= ~rx_tog_q;
      if (ipr_data_receive_i)
        ipr_tog_q <= ~ipr_tog_q;
    end
  end

  // -------------------------------------------------------------------------
  // LED5: toggle v tx_clk domene — TXEN rising edge
  // -------------------------------------------------------------------------
  logic tx_en_prev_q;
  logic tx_tog_q;

  always_ff @(posedge eth_tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_en_prev_q <= 1'b0;
      tx_tog_q     <= 1'b0;
    end else begin
      tx_en_prev_q <= eth_tx_en_i;
      if (eth_tx_en_i & ~tx_en_prev_q)
        tx_tog_q <= ~tx_tog_q;
    end
  end

  // -------------------------------------------------------------------------
  // CDC: toggles -> sys_clk_i
  // -------------------------------------------------------------------------
  logic rx_sync_w;
  logic ipr_sync_w;
  logic tx_sync_w;

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_rx_sync (
    .clk_i  (sys_clk_i), .rst_ni (rst_ni),
    .d_i    (rx_tog_q),  .q_o    (rx_sync_w)
  );

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_ipr_sync (
    .clk_i  (sys_clk_i), .rst_ni (rst_ni),
    .d_i    (ipr_tog_q), .q_o    (ipr_sync_w)
  );

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_tx_sync (
    .clk_i  (sys_clk_i), .rst_ni (rst_ni),
    .d_i    (tx_tog_q),  .q_o    (tx_sync_w)
  );

  // -------------------------------------------------------------------------
  // Edge detection v sys_clk_i domene
  // -------------------------------------------------------------------------
  logic rx_prev_q;
  logic ipr_prev_q;
  logic tx_prev_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_prev_q  <= 1'b0;
      ipr_prev_q <= 1'b0;
      tx_prev_q  <= 1'b0;
    end else begin
      rx_prev_q  <= rx_sync_w;
      ipr_prev_q <= ipr_sync_w;
      tx_prev_q  <= tx_sync_w;
    end
  end

  logic rx_edge_w;
  logic ipr_edge_w;
  logic tx_edge_w;

  assign rx_edge_w  = rx_sync_w  ^ rx_prev_q;
  assign ipr_edge_w = ipr_sync_w ^ ipr_prev_q;
  assign tx_edge_w  = tx_sync_w  ^ tx_prev_q;

  // -------------------------------------------------------------------------
  // Activity stretch counters v sys_clk_i domene
  // -------------------------------------------------------------------------
  localparam int SYS_STRETCH = (SYS_CLK_HZ / 1000) * ACTIVITY_MS;
  localparam int SYS_STR_W   = $clog2(SYS_STRETCH + 1);

  /* verilator lint_off UNUSED */
  logic [SYS_STR_W-1:0] rx_stretch_cnt_q;
  logic [SYS_STR_W-1:0] ipr_stretch_cnt_q;
  logic [SYS_STR_W-1:0] tx_stretch_cnt_q;
  /* verilator lint_on UNUSED */

  logic rx_active_q;
  logic ipr_active_q;
  logic tx_active_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_stretch_cnt_q  <= '0;
      ipr_stretch_cnt_q <= '0;
      tx_stretch_cnt_q  <= '0;
      rx_active_q       <= 1'b0;
      ipr_active_q      <= 1'b0;
      tx_active_q       <= 1'b0;
    end else begin
      if (rx_edge_w) begin
        rx_stretch_cnt_q <= SYS_STR_W'(SYS_STRETCH - 1);
        rx_active_q      <= 1'b1;
      end else if (rx_stretch_cnt_q > 0) begin
        rx_stretch_cnt_q <= rx_stretch_cnt_q - 1'b1;
      end else begin
        rx_active_q <= 1'b0;
      end

      if (ipr_edge_w) begin
        ipr_stretch_cnt_q <= SYS_STR_W'(SYS_STRETCH - 1);
        ipr_active_q      <= 1'b1;
      end else if (ipr_stretch_cnt_q > 0) begin
        ipr_stretch_cnt_q <= ipr_stretch_cnt_q - 1'b1;
      end else begin
        ipr_active_q <= 1'b0;
      end

      if (tx_edge_w) begin
        tx_stretch_cnt_q <= SYS_STR_W'(SYS_STRETCH - 1);
        tx_active_q      <= 1'b1;
      end else if (tx_stretch_cnt_q > 0) begin
        tx_stretch_cnt_q <= tx_stretch_cnt_q - 1'b1;
      end else begin
        tx_active_q <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // LED output assembly
  // LED0 = SYS_CLK heartbeat
  // LED1 = PHY reset done
  // LED2 = ETH_RXC heartbeat (~1Hz blik ak bezi)
  // LED3 = RXDV aktivita
  // LED4 = ipreceive hotovy
  // LED5 = ETH TX aktivita
  // -------------------------------------------------------------------------
  logic [LED_COUNT-1:0] led_raw_w;

  always_comb begin
    led_raw_w = '0;
    if (LED_COUNT > 0) led_raw_w[0] = hb_q;
    if (LED_COUNT > 1) led_raw_w[1] = phy_reset_done_i;
    if (LED_COUNT > 2) led_raw_w[2] = rxc_hb_sync_w;
    if (LED_COUNT > 3) led_raw_w[3] = rx_active_q;
    if (LED_COUNT > 4) led_raw_w[4] = ipr_active_q;
    if (LED_COUNT > 5) led_raw_w[5] = tx_active_q;
  end

  assign led_o = LED_ACTIVE_LOW ? ~led_raw_w : led_raw_w;

endmodule

`endif // ETH_STATUS_LEDS_SV
