`default_nettype none

// -----------------------------------------------------------------------------
// uart_stream_loopback_status
// -----------------------------------------------------------------------------
// Purpose:
//   Small UART stream helper for soc_top integration.
//
//   - Accepts bytes from UART RX stream.
//   - Buffers one byte.
//   - Sends the byte back to UART TX stream.
//   - Shows communication/status information on LEDs.
//
// Expected connection to uart wrapper:
//   uart.rx_data_o   -> rx_data_i
//   uart.rx_valid_o  -> rx_valid_i
//   rx_ready_o       -> uart.rx_ready_i
//
//   tx_data_o        -> uart.tx_data_i
//   tx_valid_o       -> uart.tx_valid_i
//   uart.tx_ready_o  -> tx_ready_i
//
//   uart.tx_busy_o     -> tx_busy_i
//   uart.rx_busy_o     -> rx_busy_i
//   uart.overrun_err_o -> overrun_err_i
//   uart.frame_err_o   -> frame_err_i
//   uart.parity_err_o  -> parity_err_i
//
// LED mapping, width 6:
//   led[0] = RX byte accepted pulse stretched
//   led[1] = TX byte accepted pulse stretched
//   led[2] = RX busy
//   led[3] = TX busy
//   led[4] = any UART error latched
//   led[5] = heartbeat
// -----------------------------------------------------------------------------

module uart_stream_loopback_status #(
  parameter int DATA_WIDTH = 8,
  parameter int LED_WIDTH  = 6,
  parameter int HEARTBEAT_COUNTER_WIDTH = 24,
  parameter int PULSE_STRETCH_WIDTH     = 22
)(
  input  wire                  clk,
  input  wire                  rstn,

  // UART RX stream input
  input  wire [DATA_WIDTH-1:0] rx_data_i,
  input  wire                  rx_valid_i,
  output wire                  rx_ready_o,

  // UART TX stream output
  output wire [DATA_WIDTH-1:0] tx_data_o,
  output wire                  tx_valid_o,
  input  wire                  tx_ready_i,

  // UART status inputs
  input  wire                  rx_busy_i,
  input  wire                  tx_busy_i,
  input  wire                  overrun_err_i,
  input  wire                  frame_err_i,
  input  wire                  parity_err_i,

  // Optional error clear pulse toward UART wrapper
  output wire                  err_clear_o,

  // Status LEDs
  output wire [LED_WIDTH-1:0]  leds_o
);

  localparam int RX_LED = 0;
  localparam int TX_LED = 1;
  localparam int RB_LED = 2;
  localparam int TB_LED = 3;
  localparam int ER_LED = 4;
  localparam int HB_LED = 5;

  reg [DATA_WIDTH-1:0] buffer_q;
  reg                  buffer_valid_q;

  reg [HEARTBEAT_COUNTER_WIDTH-1:0] heartbeat_cnt_q;
  reg [PULSE_STRETCH_WIDTH-1:0]     rx_pulse_cnt_q;
  reg [PULSE_STRETCH_WIDTH-1:0]     tx_pulse_cnt_q;
  reg                               error_latched_q;

  wire rx_fire;
  wire tx_fire;
  wire any_error;

  assign rx_ready_o = !buffer_valid_q || (tx_ready_i && buffer_valid_q);
  assign rx_fire    = rx_valid_i && rx_ready_o;

  assign tx_data_o  = buffer_q;
  assign tx_valid_o = buffer_valid_q;
  assign tx_fire    = tx_valid_o && tx_ready_i;

  assign any_error  = overrun_err_i || frame_err_i || parity_err_i;

  // Clear UART core errors automatically when we observe them.
  // The local LED error latch remains set until reset.
  assign err_clear_o = any_error;

  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      buffer_q        <= '0;
      buffer_valid_q  <= 1'b0;
      heartbeat_cnt_q <= '0;
      rx_pulse_cnt_q  <= '0;
      tx_pulse_cnt_q  <= '0;
      error_latched_q <= 1'b0;
    end else begin
      heartbeat_cnt_q <= heartbeat_cnt_q + 1'b1;

      if (rx_pulse_cnt_q != '0) begin
        rx_pulse_cnt_q <= rx_pulse_cnt_q - 1'b1;
      end

      if (tx_pulse_cnt_q != '0) begin
        tx_pulse_cnt_q <= tx_pulse_cnt_q - 1'b1;
      end

      if (any_error) begin
        error_latched_q <= 1'b1;
      end

      // One-byte elastic buffer.
      unique case ({rx_fire, tx_fire})
        2'b10: begin
          buffer_q       <= rx_data_i;
          buffer_valid_q <= 1'b1;
        end

        2'b01: begin
          buffer_valid_q <= 1'b0;
        end

        2'b11: begin
          // Simultaneous consume and receive: replace buffer with new byte.
          buffer_q       <= rx_data_i;
          buffer_valid_q <= 1'b1;
        end

        default: begin
          buffer_valid_q <= buffer_valid_q;
        end
      endcase

      if (rx_fire) begin
        rx_pulse_cnt_q <= '1;
      end

      if (tx_fire) begin
        tx_pulse_cnt_q <= '1;
      end
    end
  end

  generate
    if (LED_WIDTH > RX_LED) begin : g_led_rx
      assign leds_o[RX_LED] = |rx_pulse_cnt_q;
    end
    if (LED_WIDTH > TX_LED) begin : g_led_tx
      assign leds_o[TX_LED] = |tx_pulse_cnt_q;
    end
    if (LED_WIDTH > RB_LED) begin : g_led_rbusy
      assign leds_o[RB_LED] = rx_busy_i;
    end
    if (LED_WIDTH > TB_LED) begin : g_led_tbusy
      assign leds_o[TB_LED] = tx_busy_i;
    end
    if (LED_WIDTH > ER_LED) begin : g_led_err
      assign leds_o[ER_LED] = error_latched_q;
    end
    if (LED_WIDTH > HB_LED) begin : g_led_hb
      assign leds_o[HB_LED] = heartbeat_cnt_q[HEARTBEAT_COUNTER_WIDTH-1];
    end

    if (LED_WIDTH > 6) begin : g_led_unused
      genvar i;
      for (i = 6; i < LED_WIDTH; i = i + 1) begin : g_unused
        assign leds_o[i] = 1'b0;
      end
    end
  endgenerate

endmodule

`default_nettype wire
