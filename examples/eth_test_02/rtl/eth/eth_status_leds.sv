/**
 * @file        eth_status_leds.sv
 * @brief       Diagnosticke LED indikatory pre Ethernet/PHY stav.
 * @details     4 LED indikatory:
 *              LED0 = heartbeat zo SYS_CLK (1 Hz blikanie = FPGA zije)
 *              LED1 = PHY reset uvolneny (phy_reset_done_i deassertovany)
 *              LED2 = ETH RX aktivita (eth_rx_dv_i, stretched 80ms)
 *              LED3 = ETH TX aktivita (eth_tx_en_i, stretched 80ms)
 *
 *              RX toggle vznikne v eth_rx_clk_i domene.
 *              TX toggle vznikne v eth_tx_clk_i domene.
 *              Oba sa synchronizuju do sys_clk_i cez cdc_two_flop_synchronizer.
 */

`ifndef ETH_STATUS_LEDS_SV
`define ETH_STATUS_LEDS_SV

`default_nettype none

module eth_status_leds #(
  parameter int SYS_CLK_HZ     = 50_000_000,
  parameter int LED_COUNT      = 4,
  parameter bit LED_ACTIVE_LOW = 1'b0,
  parameter int ACTIVITY_MS    = 80
) (
  input  wire                  sys_clk_i,
  input  wire                  eth_rx_clk_i,
  input  wire                  eth_tx_clk_i,
  input  wire                  rst_ni,
  input  wire                  phy_reset_done_i,
  input  wire                  eth_rx_dv_i,
  input  wire                  eth_tx_en_i,
  output logic [LED_COUNT-1:0] led_o
);

  // -------------------------------------------------------------------------
  // LED0: heartbeat — toggle SYS_CLK / 2 => 1 Hz blikanie
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
  // LED2: RX activity toggle in eth_rx_clk_i domain
  // -------------------------------------------------------------------------
  logic rx_dv_prev_q;
  logic rx_tog_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_dv_prev_q <= 1'b0;
      rx_tog_q     <= 1'b0;
    end else begin
      rx_dv_prev_q <= eth_rx_dv_i;
      if (eth_rx_dv_i & ~rx_dv_prev_q)
        rx_tog_q <= ~rx_tog_q;
    end
  end

  // -------------------------------------------------------------------------
  // LED3: TX activity toggle in eth_tx_clk_i domain
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
  // CDC: toggles -> sys_clk_i via shared cdc_two_flop_synchronizer
  // -------------------------------------------------------------------------
  logic rx_sync_w;
  logic tx_sync_w;

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_rx_sync (
    .clk_i  (sys_clk_i),
    .rst_ni (rst_ni),
    .d_i    (rx_tog_q),
    .q_o    (rx_sync_w)
  );

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_tx_sync (
    .clk_i  (sys_clk_i),
    .rst_ni (rst_ni),
    .d_i    (tx_tog_q),
    .q_o    (tx_sync_w)
  );

  // --- Edge detection in sys_clk_i domain ---
  logic rx_prev_q;
  logic tx_prev_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_prev_q <= 1'b0;
      tx_prev_q <= 1'b0;
    end else begin
      rx_prev_q <= rx_sync_w;
      tx_prev_q <= tx_sync_w;
    end
  end

  logic rx_edge_w;
  logic tx_edge_w;
  assign rx_edge_w = rx_sync_w ^ rx_prev_q;
  assign tx_edge_w = tx_sync_w ^ tx_prev_q;

  // -------------------------------------------------------------------------
  // Activity stretch counters in sys_clk_i domain
  // -------------------------------------------------------------------------
  localparam int SYS_STRETCH = (SYS_CLK_HZ / 1000) * ACTIVITY_MS;
  localparam int SYS_STR_W   = $clog2(SYS_STRETCH + 1);

  /* verilator lint_off UNUSED */
  logic [SYS_STR_W-1:0] rx_stretch_cnt_q;
  logic [SYS_STR_W-1:0] tx_stretch_cnt_q;
  /* verilator lint_on UNUSED */

  logic rx_active_q;
  logic tx_active_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_stretch_cnt_q <= '0;
      tx_stretch_cnt_q <= '0;
      rx_active_q      <= 1'b0;
      tx_active_q      <= 1'b0;
    end else begin
      if (rx_edge_w) begin
        rx_stretch_cnt_q <= SYS_STR_W'(SYS_STRETCH - 1);
        rx_active_q      <= 1'b1;
      end else if (rx_stretch_cnt_q > 0) begin
        rx_stretch_cnt_q <= rx_stretch_cnt_q - 1'b1;
      end else begin
        rx_active_q <= 1'b0;
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
  // -------------------------------------------------------------------------
  logic [LED_COUNT-1:0] led_raw_w;

  always_comb begin
    led_raw_w = '0;
    if (LED_COUNT > 0) led_raw_w[0] = hb_q;
    if (LED_COUNT > 1) led_raw_w[1] = phy_reset_done_i;
    if (LED_COUNT > 2) led_raw_w[2] = rx_active_q;
    if (LED_COUNT > 3) led_raw_w[3] = tx_active_q;
  end

  assign led_o = LED_ACTIVE_LOW ? ~led_raw_w : led_raw_w;

endmodule

`endif // ETH_STATUS_LEDS_SV
