/**
 * @file eth_debug_leds.sv
 * @brief LED diagnostics for ETH_TEST_03 UDP echo HW bring-up.
 * @details Six LEDs indicate pipeline progress across clock domains.
 *   LED0 = SYS_CLK heartbeat (~1 Hz)
 *   LED1 = PHY reset released (static once set)
 *   LED2 = GMII RXDV activity (raw, stretched)
 *   LED3 = UDP frame accepted (rx_meta_valid rising edge, stretched)
 *   LED4 = TX MAC active (tx_mac_busy rising edge, stretched)
 *   LED5 = GMII TXEN activity (raw, stretched)
 *
 *   Diagnostic guide:
 *     LED2 off             : PHY/link/RXDV clock routing problem
 *     LED2 on, LED3 off   : frame received but parser dropped it (MAC/IP/UDP filter)
 *     LED3 on, LED4 off   : RX parser OK; CDC or TX controller blocked
 *     LED4 on, LED5 off   : TX meta arrived; gmii_tx_mac not starting
 *     LED5 on, no tcpdump : TX physical/GTX_CLK/PHY timing problem
 *
 *   Async signals from eth_rx_clk and eth_tx_clk domains are bridged via
 *   toggle synchronizers (toggle in source domain, 2-FF sync to sys_clk,
 *   edge detect in sys_clk, stretch counter drives LED).
 *
 * @param SYS_CLK_HZ     System clock frequency in Hz (default 50 MHz)
 * @param ACTIVITY_MS    LED activity stretch window in ms (default 150)
 * @param LED_ACTIVE_LOW 1 = LEDs light on logic 0 (default 0)
 */

`ifndef ETH_DEBUG_LEDS_SV
`define ETH_DEBUG_LEDS_SV

`default_nettype none

module eth_debug_leds #(
  parameter int SYS_CLK_HZ     = 50_000_000,
  parameter int ACTIVITY_MS    = 150,
  parameter bit LED_ACTIVE_LOW = 1'b0
)(
  input  wire logic sys_clk_i,
  input  wire logic eth_rx_clk_i,
  input  wire logic eth_tx_clk_i,
  input  wire logic rst_ni,

  input  wire logic phy_reset_done_i,  // sys_clk domain — direct
  input  wire logic rx_dv_i,           // eth_rx_clk domain, level
  input  wire logic udp_accept_i,      // eth_rx_clk domain, pulse (rx_meta_valid)
  input  wire logic tx_active_i,       // eth_tx_clk domain, level (tx_mac_busy)
  input  wire logic tx_en_i,           // eth_tx_clk domain, level (gmii_tx_en)

  output      logic [5:0] led_o
);

  // ---------------------------------------------------------------------------
  // LED0: heartbeat ~1 Hz in sys_clk domain
  // ---------------------------------------------------------------------------
  localparam int HB_DIV = SYS_CLK_HZ / 2;
  localparam int HB_W   = $clog2(HB_DIV + 1);

  logic [HB_W-1:0] hb_cnt_q;
  logic            hb_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hb_cnt_q <= '0;
      hb_q     <= 1'b0;
    end else if (hb_cnt_q == HB_W'(HB_DIV - 1)) begin
      hb_cnt_q <= '0;
      hb_q     <= ~hb_q;
    end else begin
      hb_cnt_q <= hb_cnt_q + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Toggle synchronizer infrastructure
  // In source domain: rising edge of signal -> toggle a bit
  // 2-FF sync to sys_clk, XOR edge detect -> load stretch counter
  // ---------------------------------------------------------------------------
  localparam int STRETCH_N = (SYS_CLK_HZ / 1000) * ACTIVITY_MS;
  localparam int STR_W     = $clog2(STRETCH_N + 1);

  // --- RX domain toggles (eth_rx_clk) ---
  logic rx_dv_prev_q, udp_prev_q;
  logic rx_dv_tog_q,  udp_tog_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_dv_prev_q <= 1'b0;
      udp_prev_q   <= 1'b0;
      rx_dv_tog_q  <= 1'b0;
      udp_tog_q    <= 1'b0;
    end else begin
      rx_dv_prev_q <= rx_dv_i;
      udp_prev_q   <= udp_accept_i;
      if (rx_dv_i    & ~rx_dv_prev_q) rx_dv_tog_q <= ~rx_dv_tog_q;
      if (udp_accept_i & ~udp_prev_q) udp_tog_q   <= ~udp_tog_q;
    end
  end

  // --- TX domain toggles (eth_tx_clk) ---
  logic tx_act_prev_q, tx_en_prev_q;
  logic tx_act_tog_q,  tx_en_tog_q;

  always_ff @(posedge eth_tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_act_prev_q <= 1'b0;
      tx_en_prev_q  <= 1'b0;
      tx_act_tog_q  <= 1'b0;
      tx_en_tog_q   <= 1'b0;
    end else begin
      tx_act_prev_q <= tx_active_i;
      tx_en_prev_q  <= tx_en_i;
      if (tx_active_i & ~tx_act_prev_q) tx_act_tog_q <= ~tx_act_tog_q;
      if (tx_en_i     & ~tx_en_prev_q)  tx_en_tog_q  <= ~tx_en_tog_q;
    end
  end

  // --- 2-FF synchronizers to sys_clk ---
  logic rx_dv_sync_w, udp_sync_w, tx_act_sync_w, tx_en_sync_w;

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_rx_dv_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (rx_dv_tog_q),  .q_o (rx_dv_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_udp_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (udp_tog_q),    .q_o (udp_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_tx_act_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (tx_act_tog_q), .q_o (tx_act_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_tx_en_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (tx_en_tog_q),  .q_o (tx_en_sync_w)
  );

  // --- Edge detection in sys_clk ---
  logic rx_dv_prev2_q, udp_prev2_q, tx_act_prev2_q, tx_en_prev2_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_dv_prev2_q  <= 1'b0;
      udp_prev2_q    <= 1'b0;
      tx_act_prev2_q <= 1'b0;
      tx_en_prev2_q  <= 1'b0;
    end else begin
      rx_dv_prev2_q  <= rx_dv_sync_w;
      udp_prev2_q    <= udp_sync_w;
      tx_act_prev2_q <= tx_act_sync_w;
      tx_en_prev2_q  <= tx_en_sync_w;
    end
  end

  logic rx_dv_edge_w, udp_edge_w, tx_act_edge_w, tx_en_edge_w;
  assign rx_dv_edge_w  = rx_dv_sync_w  ^ rx_dv_prev2_q;
  assign udp_edge_w    = udp_sync_w    ^ udp_prev2_q;
  assign tx_act_edge_w = tx_act_sync_w ^ tx_act_prev2_q;
  assign tx_en_edge_w  = tx_en_sync_w  ^ tx_en_prev2_q;

  // --- Stretch counters (load on edge, countdown, clear active flag at zero) ---
  logic [STR_W-1:0] rx_dv_str_q, udp_str_q, tx_act_str_q, tx_en_str_q;
  logic             rx_dv_act_q, udp_act_q, tx_act_act_q, tx_en_act_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_dv_str_q  <= '0; rx_dv_act_q  <= 1'b0;
      udp_str_q    <= '0; udp_act_q    <= 1'b0;
      tx_act_str_q <= '0; tx_act_act_q <= 1'b0;
      tx_en_str_q  <= '0; tx_en_act_q  <= 1'b0;
    end else begin
      if (rx_dv_edge_w) begin
        rx_dv_str_q <= STR_W'(STRETCH_N - 1); rx_dv_act_q <= 1'b1;
      end else if (rx_dv_str_q != '0) begin
        rx_dv_str_q <= rx_dv_str_q - 1'b1;
      end else begin
        rx_dv_act_q <= 1'b0;
      end

      if (udp_edge_w) begin
        udp_str_q <= STR_W'(STRETCH_N - 1); udp_act_q <= 1'b1;
      end else if (udp_str_q != '0) begin
        udp_str_q <= udp_str_q - 1'b1;
      end else begin
        udp_act_q <= 1'b0;
      end

      if (tx_act_edge_w) begin
        tx_act_str_q <= STR_W'(STRETCH_N - 1); tx_act_act_q <= 1'b1;
      end else if (tx_act_str_q != '0) begin
        tx_act_str_q <= tx_act_str_q - 1'b1;
      end else begin
        tx_act_act_q <= 1'b0;
      end

      if (tx_en_edge_w) begin
        tx_en_str_q <= STR_W'(STRETCH_N - 1); tx_en_act_q <= 1'b1;
      end else if (tx_en_str_q != '0) begin
        tx_en_str_q <= tx_en_str_q - 1'b1;
      end else begin
        tx_en_act_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LED output
  // ---------------------------------------------------------------------------
  logic [5:0] led_raw_w;
  assign led_raw_w[0] = hb_q;
  assign led_raw_w[1] = phy_reset_done_i;
  assign led_raw_w[2] = rx_dv_act_q;
  assign led_raw_w[3] = udp_act_q;
  assign led_raw_w[4] = tx_act_act_q;
  assign led_raw_w[5] = tx_en_act_q;

  assign led_o = LED_ACTIVE_LOW ? ~led_raw_w : led_raw_w;

endmodule

`endif // ETH_DEBUG_LEDS_SV
