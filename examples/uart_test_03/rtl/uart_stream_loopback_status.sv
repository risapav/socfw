/**
 * @file    uart_stream_loopback_status.sv
 * @brief   One-byte loopback buffer with LED status display
 * @param   DATA_WIDTH              Data width; must match uart core (8).
 * @param   LED_WIDTH               Number of LEDs (6 used).
 * @param   HEARTBEAT_COUNTER_WIDTH Counter MSB drives heartbeat LED (~1 Hz @ 125 MHz with 26).
 * @param   PULSE_STRETCH_WIDTH     RX/TX activity pulse stretch (visible @ 125 MHz with 24).
 * @details
 *  Accepts bytes from UART RX stream and echoes them back on UART TX stream.
 *  A single elastic byte buffer allows simultaneous consume+receive.
 *
 *  LED mapping (index):
 *    0  RX byte accepted (stretched pulse)
 *    1  TX byte accepted (stretched pulse)
 *    2  RX busy
 *    3  TX busy
 *    4  Any UART error latched since last reset
 *    5  Heartbeat (MSB of free-running counter)
 *
 *  err_clear_o: pulses high whenever any error is observed.
 *    Connect to uart.err_clear_i to auto-clear sticky error flags.
 */

`ifndef UART_STREAM_LOOPBACK_STATUS_SV
`define UART_STREAM_LOOPBACK_STATUS_SV

`default_nettype none

module uart_stream_loopback_status #(
  parameter int DATA_WIDTH              = 8,
  parameter int LED_WIDTH               = 6,
  parameter int HEARTBEAT_COUNTER_WIDTH = 26,
  parameter int PULSE_STRETCH_WIDTH     = 24,
  parameter bit AUTO_CLEAR_ERRORS       = 1'b1
)(
  input  wire clk,
  input  wire rstn,

  // UART RX stream input
  input  wire [DATA_WIDTH-1:0] rx_data_i,
  input  wire                  rx_valid_i,
  output wire                  rx_ready_o,

  // UART TX stream output
  output wire [DATA_WIDTH-1:0] tx_data_o,
  output wire                  tx_valid_o,
  input  wire                  tx_ready_i,

  // UART status
  input  wire rx_busy_i,
  input  wire tx_busy_i,
  input  wire overrun_err_i,
  input  wire frame_err_i,
  input  wire parity_err_i,

  // Auto-clear pulse to uart.err_clear_i
  output wire err_clear_o,

  // Status LEDs
  output wire [LED_WIDTH-1:0] leds_o
);

  logic [DATA_WIDTH-1:0]            buffer_q;
  logic                             buffer_valid_q;
  logic [HEARTBEAT_COUNTER_WIDTH-1:0] heartbeat_q;
  logic [PULSE_STRETCH_WIDTH-1:0]   rx_pulse_q;
  logic [PULSE_STRETCH_WIDTH-1:0]   tx_pulse_q;
  logic                             error_latch_q;

  wire any_error_w = overrun_err_i || frame_err_i || parity_err_i;

  // RX ready: accept when buffer is empty or is being simultaneously consumed
  assign rx_ready_o = !buffer_valid_q || tx_ready_i;

  wire rx_fire_w = rx_valid_i && rx_ready_o;
  wire tx_fire_w = buffer_valid_q && tx_ready_i;

  assign tx_data_o  = buffer_q;
  assign tx_valid_o = buffer_valid_q;

  // Auto-clear UART core error flags when observed
  assign err_clear_o = AUTO_CLEAR_ERRORS ? any_error_w : 1'b0;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      buffer_q       <= '0;
      buffer_valid_q <= 1'b0;
      heartbeat_q    <= '0;
      rx_pulse_q     <= '0;
      tx_pulse_q     <= '0;
      error_latch_q  <= 1'b0;
    end else begin
      heartbeat_q <= heartbeat_q + 1'b1;

      if (rx_pulse_q != '0) rx_pulse_q <= rx_pulse_q - 1'b1;
      if (tx_pulse_q != '0) tx_pulse_q <= tx_pulse_q - 1'b1;

      if (any_error_w) error_latch_q <= 1'b1;

      // One-byte elastic buffer
      unique case ({rx_fire_w, tx_fire_w})
        2'b10: begin
          buffer_q       <= rx_data_i;
          buffer_valid_q <= 1'b1;
        end
        2'b01: begin
          buffer_valid_q <= 1'b0;
        end
        2'b11: begin
          // Simultaneous consume + receive: replace in-place
          buffer_q       <= rx_data_i;
          buffer_valid_q <= 1'b1;
        end
        default: ;
      endcase

      if (rx_fire_w) rx_pulse_q <= '1;
      if (tx_fire_w) tx_pulse_q <= '1;
    end
  end

  // LED assignments with generate guards
  generate
    if (LED_WIDTH > 0) assign leds_o[0] = |rx_pulse_q;
    if (LED_WIDTH > 1) assign leds_o[1] = |tx_pulse_q;
    if (LED_WIDTH > 2) assign leds_o[2] = rx_busy_i;
    if (LED_WIDTH > 3) assign leds_o[3] = tx_busy_i;
    if (LED_WIDTH > 4) assign leds_o[4] = error_latch_q;
    if (LED_WIDTH > 5) assign leds_o[5] = heartbeat_q[HEARTBEAT_COUNTER_WIDTH-1];
    if (LED_WIDTH > 6) begin : g_led_unused
      genvar gi;
      for (gi = 6; gi < LED_WIDTH; gi++) begin : g_unused
        assign leds_o[gi] = 1'b0;
      end
    end
  endgenerate

endmodule

`default_nettype wire

`endif // UART_STREAM_LOOPBACK_STATUS_SV
