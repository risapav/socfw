/**
 * @file eth_debug_leds.sv
 * @brief LED diagnostics for ETH_TEST_03 UDP echo HW bring-up.
 * @details Six LEDs indicate pipeline progress across clock domains.
 *
 *   Normal mode (LAYER_DEBUG=0, MAC_DEBUG=0):
 *     LED0 = SYS_CLK heartbeat (~1 Hz)
 *     LED1 = PHY reset released (static once set)
 *     LED2 = GMII RXDV activity (raw, stretched)
 *     LED3 = UDP frame accepted (rx_meta_valid rising edge, stretched)
 *     LED4 = TX MAC active (tx_mac_busy rising edge, stretched)
 *     LED5 = GMII TXEN activity (raw, stretched)
 *
 *   Layer debug mode (LAYER_DEBUG=1, MAC_DEBUG=0):
 *     LED0 = SYS_CLK heartbeat
 *     LED1 = PHY reset released
 *     LED2 = GMII RXDV activity
 *     LED3 = gmii_rx_mac frame_done (frame completed by MAC, stretched)
 *     LED4 = eth_header_parser hdr_valid (L2 accepted, stretched)
 *     LED5 = ipv4_header_parser hdr_valid (L3 accepted, stretched)
 *
 *   MAC debug mode (MAC_DEBUG=1, overrides LAYER_DEBUG):
 *     LED0 = SYS_CLK heartbeat
 *     LED1 = PHY reset released
 *     LED2 = GMII RXDV activity
 *     LED3 = eth_header_parser hdr_done_pulse (any header parsed)
 *     LED4 = eth_header_parser hdr_accept_pulse (MAC filter accepted)
 *     LED5 = eth_header_parser hdr_drop_pulse (MAC filter dropped)
 *
 *   Diagnostic guide (MAC_DEBUG=1):
 *     LED3 blinks, LED4 blinks, LED5 off : MAC filter passing -- L2 fixed!
 *     LED3 blinks, LED4 off, LED5 blinks : MAC filter still dropping
 *     LED3 off                            : parser never reaches byte 13
 *
 *   Async signals from eth_rx_clk and eth_tx_clk domains are bridged via
 *   toggle synchronizers (toggle in source domain, 2-FF sync to sys_clk,
 *   edge detect in sys_clk, stretch counter drives LED).
 *
 * @param SYS_CLK_HZ     System clock frequency in Hz (default 50 MHz)
 * @param ACTIVITY_MS    LED activity stretch window in ms (default 150)
 * @param LED_ACTIVE_LOW 1 = LEDs light on logic 0 (default 0)
 * @param LAYER_DEBUG    1 = debug mode: LED3/4/5 show RX pipeline layers
 * @param MAC_DEBUG      1 = MAC debug mode: LED3/4/5 show L2 MAC filter pulses (overrides LAYER_DEBUG)
 */

`ifndef ETH_DEBUG_LEDS_SV
`define ETH_DEBUG_LEDS_SV

`default_nettype none

module eth_debug_leds #(
  parameter int SYS_CLK_HZ     = 50_000_000,
  parameter int ACTIVITY_MS    = 150,
  parameter bit LED_ACTIVE_LOW = 1'b0,
  parameter bit LAYER_DEBUG    = 1'b0,
  parameter bit MAC_DEBUG      = 1'b0
)(
  input  wire logic sys_clk_i,
  input  wire logic eth_rx_clk_i,
  input  wire logic eth_tx_clk_i,
  input  wire logic rst_ni,

  input  wire logic phy_reset_done_i,  // sys_clk domain -- direct
  input  wire logic rx_dv_i,           // eth_rx_clk domain, level
  input  wire logic udp_accept_i,      // eth_rx_clk domain, pulse (rx_meta_valid)
  input  wire logic tx_active_i,       // eth_tx_clk domain, level (tx_mac_busy)
  input  wire logic tx_en_i,           // eth_tx_clk domain, level (gmii_tx_en)

  // Layer debug signals -- eth_rx_clk domain, used when LAYER_DEBUG=1
  input  wire logic layer_frame_done_i,  // gmii_rx_mac frame_done (pulse)
  input  wire logic layer_eth_hdr_i,     // eth_header_parser hdr_valid (level)
  input  wire logic layer_ipv4_hdr_i,    // ipv4_header_parser hdr_valid (level)

  // MAC debug signals -- eth_rx_clk domain, 1-cycle pulses, used when MAC_DEBUG=1
  input  wire logic mac_hdr_done_i,    // eth_header_parser hdr_done_pulse (any header)
  input  wire logic mac_accept_i,      // eth_header_parser hdr_accept_pulse (MAC accepted)
  input  wire logic mac_drop_i,        // eth_header_parser hdr_drop_pulse (MAC dropped)

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

  // --- RX domain toggles (eth_rx_clk) -- normal mode signals ---
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

  // --- Layer debug toggles (eth_rx_clk) -- LAYER_DEBUG=1 ---
  logic dbg_fd_prev_q, dbg_l2_prev_q, dbg_l3_prev_q;
  logic dbg_fd_tog_q,  dbg_l2_tog_q,  dbg_l3_tog_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_fd_prev_q <= 1'b0; dbg_l2_prev_q <= 1'b0; dbg_l3_prev_q <= 1'b0;
      dbg_fd_tog_q  <= 1'b0; dbg_l2_tog_q  <= 1'b0; dbg_l3_tog_q  <= 1'b0;
    end else begin
      dbg_fd_prev_q <= layer_frame_done_i;
      dbg_l2_prev_q <= layer_eth_hdr_i;
      dbg_l3_prev_q <= layer_ipv4_hdr_i;
      if (layer_frame_done_i & ~dbg_fd_prev_q) dbg_fd_tog_q <= ~dbg_fd_tog_q;
      if (layer_eth_hdr_i    & ~dbg_l2_prev_q) dbg_l2_tog_q <= ~dbg_l2_tog_q;
      if (layer_ipv4_hdr_i   & ~dbg_l3_prev_q) dbg_l3_tog_q <= ~dbg_l3_tog_q;
    end
  end

  // --- MAC debug toggles (eth_rx_clk) -- MAC_DEBUG=1 ---
  logic mac_hd_prev_q, mac_ma_prev_q, mac_md_prev_q;
  logic mac_hd_tog_q,  mac_ma_tog_q,  mac_md_tog_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mac_hd_prev_q <= 1'b0; mac_ma_prev_q <= 1'b0; mac_md_prev_q <= 1'b0;
      mac_hd_tog_q  <= 1'b0; mac_ma_tog_q  <= 1'b0; mac_md_tog_q  <= 1'b0;
    end else begin
      mac_hd_prev_q <= mac_hdr_done_i;
      mac_ma_prev_q <= mac_accept_i;
      mac_md_prev_q <= mac_drop_i;
      if (mac_hdr_done_i & ~mac_hd_prev_q) mac_hd_tog_q <= ~mac_hd_tog_q;
      if (mac_accept_i   & ~mac_ma_prev_q) mac_ma_tog_q <= ~mac_ma_tog_q;
      if (mac_drop_i     & ~mac_md_prev_q) mac_md_tog_q <= ~mac_md_tog_q;
    end
  end

  // --- 2-FF synchronizers to sys_clk ---
  logic rx_dv_sync_w, udp_sync_w, tx_act_sync_w, tx_en_sync_w;
  logic dbg_fd_sync_w, dbg_l2_sync_w, dbg_l3_sync_w;
  logic mac_hd_sync_w, mac_ma_sync_w, mac_md_sync_w;

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
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_dbg_fd_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (dbg_fd_tog_q), .q_o (dbg_fd_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_dbg_l2_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (dbg_l2_tog_q), .q_o (dbg_l2_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_dbg_l3_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (dbg_l3_tog_q), .q_o (dbg_l3_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_mac_hd_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (mac_hd_tog_q), .q_o (mac_hd_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_mac_ma_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (mac_ma_tog_q), .q_o (mac_ma_sync_w)
  );
  cdc_two_flop_synchronizer #(.WIDTH(1)) u_mac_md_sync (
    .clk_i (sys_clk_i), .rst_ni (rst_ni),
    .d_i   (mac_md_tog_q), .q_o (mac_md_sync_w)
  );

  // --- Edge detection in sys_clk ---
  logic rx_dv_prev2_q, udp_prev2_q, tx_act_prev2_q, tx_en_prev2_q;
  logic dbg_fd_prev2_q, dbg_l2_prev2_q, dbg_l3_prev2_q;
  logic mac_hd_prev2_q, mac_ma_prev2_q, mac_md_prev2_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_dv_prev2_q  <= 1'b0;
      udp_prev2_q    <= 1'b0;
      tx_act_prev2_q <= 1'b0;
      tx_en_prev2_q  <= 1'b0;
      dbg_fd_prev2_q <= 1'b0;
      dbg_l2_prev2_q <= 1'b0;
      dbg_l3_prev2_q <= 1'b0;
      mac_hd_prev2_q <= 1'b0;
      mac_ma_prev2_q <= 1'b0;
      mac_md_prev2_q <= 1'b0;
    end else begin
      rx_dv_prev2_q  <= rx_dv_sync_w;
      udp_prev2_q    <= udp_sync_w;
      tx_act_prev2_q <= tx_act_sync_w;
      tx_en_prev2_q  <= tx_en_sync_w;
      dbg_fd_prev2_q <= dbg_fd_sync_w;
      dbg_l2_prev2_q <= dbg_l2_sync_w;
      dbg_l3_prev2_q <= dbg_l3_sync_w;
      mac_hd_prev2_q <= mac_hd_sync_w;
      mac_ma_prev2_q <= mac_ma_sync_w;
      mac_md_prev2_q <= mac_md_sync_w;
    end
  end

  logic rx_dv_edge_w, udp_edge_w, tx_act_edge_w, tx_en_edge_w;
  logic dbg_fd_edge_w, dbg_l2_edge_w, dbg_l3_edge_w;
  logic mac_hd_edge_w, mac_ma_edge_w, mac_md_edge_w;
  assign rx_dv_edge_w  = rx_dv_sync_w  ^ rx_dv_prev2_q;
  assign udp_edge_w    = udp_sync_w    ^ udp_prev2_q;
  assign tx_act_edge_w = tx_act_sync_w ^ tx_act_prev2_q;
  assign tx_en_edge_w  = tx_en_sync_w  ^ tx_en_prev2_q;
  assign dbg_fd_edge_w = dbg_fd_sync_w ^ dbg_fd_prev2_q;
  assign dbg_l2_edge_w = dbg_l2_sync_w ^ dbg_l2_prev2_q;
  assign dbg_l3_edge_w = dbg_l3_sync_w ^ dbg_l3_prev2_q;
  assign mac_hd_edge_w = mac_hd_sync_w ^ mac_hd_prev2_q;
  assign mac_ma_edge_w = mac_ma_sync_w ^ mac_ma_prev2_q;
  assign mac_md_edge_w = mac_md_sync_w ^ mac_md_prev2_q;

  // --- Stretch counters ---
  logic [STR_W-1:0] rx_dv_str_q, udp_str_q, tx_act_str_q, tx_en_str_q;
  logic             rx_dv_act_q, udp_act_q, tx_act_act_q, tx_en_act_q;
  logic [STR_W-1:0] dbg_fd_str_q, dbg_l2_str_q, dbg_l3_str_q;
  logic             dbg_fd_act_q, dbg_l2_act_q, dbg_l3_act_q;
  logic [STR_W-1:0] mac_hd_str_q, mac_ma_str_q, mac_md_str_q;
  logic             mac_hd_act_q, mac_ma_act_q, mac_md_act_q;

  always_ff @(posedge sys_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_dv_str_q  <= '0; rx_dv_act_q  <= 1'b0;
      udp_str_q    <= '0; udp_act_q    <= 1'b0;
      tx_act_str_q <= '0; tx_act_act_q <= 1'b0;
      tx_en_str_q  <= '0; tx_en_act_q  <= 1'b0;
      dbg_fd_str_q <= '0; dbg_fd_act_q <= 1'b0;
      dbg_l2_str_q <= '0; dbg_l2_act_q <= 1'b0;
      dbg_l3_str_q <= '0; dbg_l3_act_q <= 1'b0;
      mac_hd_str_q <= '0; mac_hd_act_q <= 1'b0;
      mac_ma_str_q <= '0; mac_ma_act_q <= 1'b0;
      mac_md_str_q <= '0; mac_md_act_q <= 1'b0;
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

      if (dbg_fd_edge_w) begin
        dbg_fd_str_q <= STR_W'(STRETCH_N - 1); dbg_fd_act_q <= 1'b1;
      end else if (dbg_fd_str_q != '0) begin
        dbg_fd_str_q <= dbg_fd_str_q - 1'b1;
      end else begin
        dbg_fd_act_q <= 1'b0;
      end

      if (dbg_l2_edge_w) begin
        dbg_l2_str_q <= STR_W'(STRETCH_N - 1); dbg_l2_act_q <= 1'b1;
      end else if (dbg_l2_str_q != '0) begin
        dbg_l2_str_q <= dbg_l2_str_q - 1'b1;
      end else begin
        dbg_l2_act_q <= 1'b0;
      end

      if (dbg_l3_edge_w) begin
        dbg_l3_str_q <= STR_W'(STRETCH_N - 1); dbg_l3_act_q <= 1'b1;
      end else if (dbg_l3_str_q != '0) begin
        dbg_l3_str_q <= dbg_l3_str_q - 1'b1;
      end else begin
        dbg_l3_act_q <= 1'b0;
      end

      if (mac_hd_edge_w) begin
        mac_hd_str_q <= STR_W'(STRETCH_N - 1); mac_hd_act_q <= 1'b1;
      end else if (mac_hd_str_q != '0) begin
        mac_hd_str_q <= mac_hd_str_q - 1'b1;
      end else begin
        mac_hd_act_q <= 1'b0;
      end

      if (mac_ma_edge_w) begin
        mac_ma_str_q <= STR_W'(STRETCH_N - 1); mac_ma_act_q <= 1'b1;
      end else if (mac_ma_str_q != '0) begin
        mac_ma_str_q <= mac_ma_str_q - 1'b1;
      end else begin
        mac_ma_act_q <= 1'b0;
      end

      if (mac_md_edge_w) begin
        mac_md_str_q <= STR_W'(STRETCH_N - 1); mac_md_act_q <= 1'b1;
      end else if (mac_md_str_q != '0) begin
        mac_md_str_q <= mac_md_str_q - 1'b1;
      end else begin
        mac_md_act_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LED output — MAC_DEBUG overrides LAYER_DEBUG overrides normal
  // ---------------------------------------------------------------------------
  logic [5:0] led_raw_w;
  assign led_raw_w[0] = hb_q;
  assign led_raw_w[1] = phy_reset_done_i;
  assign led_raw_w[2] = rx_dv_act_q;
  assign led_raw_w[3] = MAC_DEBUG  ? mac_hd_act_q  : LAYER_DEBUG ? dbg_fd_act_q  : udp_act_q;
  assign led_raw_w[4] = MAC_DEBUG  ? mac_ma_act_q  : LAYER_DEBUG ? dbg_l2_act_q  : tx_act_act_q;
  assign led_raw_w[5] = MAC_DEBUG  ? mac_md_act_q  : LAYER_DEBUG ? dbg_l3_act_q  : tx_en_act_q;

  assign led_o = LED_ACTIVE_LOW ? ~led_raw_w : led_raw_w;

endmodule

`endif // ETH_DEBUG_LEDS_SV
