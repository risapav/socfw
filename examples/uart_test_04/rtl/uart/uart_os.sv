/**
 * @file    uart_os.sv
 * @brief   UART wrapper with 16x oversampled RX and standard TX.
 * @param   CLK_FREQ_HZ  System clock frequency in Hz (default 125 MHz).
 * @param   BAUD_RATE    Desired baud rate (default 115200).
 * @param   DATA_WIDTH   Data width; must be 8.
 * @param   STOP2        True for 2 stop bits.
 * @param   PARITY       2'b00 none, 2'b01 odd, 2'b10 even.
 * @param   DBITS        2'b00=8, 2'b01=7, 2'b10=6, 2'b11=5 data bits.
 * @details
 *  Drop-in replacement for uart.sv.  RX path uses uart_core_rx_os (16x
 *  oversampled) instead of uart_core_rx (1x sampler).
 *
 *  RX baud generator runs at 16x baud rate:
 *    PRESCALE_OS = round(CLK_FREQ_HZ / (BAUD_RATE * 16))
 *  At 125 MHz / 115200: PRESCALE_OS = 68, error = +0.33%.
 *
 *  TX path is unchanged from uart.sv.
 */

`ifndef UART_OS_SV
`define UART_OS_SV

`default_nettype none

import uart_pkg::*;

module uart_os #(
  parameter int          CLK_FREQ_HZ = 125_000_000,
  parameter int          BAUD_RATE   = 115_200,
  parameter int          DATA_WIDTH  = 8,
  parameter bit          STOP2       = 1'b0,
  parameter logic [1:0]  PARITY      = 2'b00,
  parameter logic [1:0]  DBITS       = 2'b00
)(
  input  wire clk,
  input  wire rstn,

  // UART pins
  input  wire rx_i,
  output wire tx_o,

  // TX stream
  input  wire [DATA_WIDTH-1:0] tx_data_i,
  input  wire                  tx_valid_i,
  output wire                  tx_ready_o,
  output wire                  tx_done_o,

  // RX stream (AXI-Stream: held valid)
  output wire [DATA_WIDTH-1:0] rx_data_o,
  output wire                  rx_valid_o,
  input  wire                  rx_ready_i,

  // Control
  input  wire err_clear_i,

  // Status
  output wire tx_busy_o,
  output wire rx_busy_o,
  output wire overrun_err_o,
  output wire frame_err_o,
  output wire parity_err_o
);

  // TX: 1x baud divisor (rounded)
  localparam int PRESCALE_TX    = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
  // RX: 16x baud divisor (rounded)
  localparam int PRESCALE_RX_OS = (CLK_FREQ_HZ + BAUD_RATE * 8) / (BAUD_RATE * 16);
  localparam int PRESCALE_TX_W  = $clog2(PRESCALE_TX + 1);
  localparam int PRESCALE_OS_W  = $clog2(PRESCALE_RX_OS + 1);

  // synthesis translate_off
  initial begin
    assert(CLK_FREQ_HZ > 0);
    assert(BAUD_RATE > 0);
    assert(PRESCALE_TX    >= 8);
    assert(PRESCALE_RX_OS >= 2);
    assert(DATA_WIDTH == 8);
  end
  // synthesis translate_on

  uart_conf_t cfg_w;
  assign cfg_w.reserved = '0;
  assign cfg_w.stop2    = STOP2;
  assign cfg_w.parity   = PARITY;
  assign cfg_w.dbits    = DBITS;

  // ------------------------------------------------------------------
  // TX baud generator (1x)
  // ------------------------------------------------------------------
  wire tx_end_tick_w;
  wire tx_start_pulse_w;
  uart_status_t tx_status_w;

  uart_baud_gen #(
    .PRESCALE_WIDTH (PRESCALE_TX_W)
  ) u_tx_baud (
    .clk         (clk),
    .rstn        (rstn),
    .start_i     (tx_start_pulse_w),
    .enable_i    (tx_status_w.tx_busy),
    .prescale_i  (PRESCALE_TX_W'(PRESCALE_TX)),
    .start_tick_o(),
    .half_tick_o (),
    .end_tick_o  (tx_end_tick_w)
  );

  // ------------------------------------------------------------------
  // RX baud generator (16x OS)
  // ------------------------------------------------------------------
  wire os_tick_w;
  wire rx_start_pulse_w;
  uart_status_t rx_status_w;

  uart_baud_gen #(
    .PRESCALE_WIDTH (PRESCALE_OS_W)
  ) u_rx_baud (
    .clk         (clk),
    .rstn        (rstn),
    .start_i     (rx_start_pulse_w),
    .enable_i    (rx_status_w.rx_busy),
    .prescale_i  (PRESCALE_OS_W'(PRESCALE_RX_OS)),
    .start_tick_o(),
    .half_tick_o (),
    .end_tick_o  (os_tick_w)
  );

  // ------------------------------------------------------------------
  // TX core
  // ------------------------------------------------------------------
  uart_core_tx #(
    .DATA_WIDTH (DATA_WIDTH)
  ) u_tx (
    .clk              (clk),
    .rstn             (rstn),
    .end_tick_i       (tx_end_tick_w),
    .cfg_i            (cfg_w),
    .data_i           (tx_data_i),
    .valid_i          (tx_valid_i),
    .ready_o          (tx_ready_o),
    .txd_o            (tx_o),
    .status_o         (tx_status_w),
    .tx_done_pulse_o  (tx_done_o),
    .tx_start_pulse_o (tx_start_pulse_w)
  );

  // ------------------------------------------------------------------
  // RX core (16x oversampled)
  // ------------------------------------------------------------------
  uart_core_rx_os #(
    .DATA_WIDTH (DATA_WIDTH)
  ) u_rx (
    .clk              (clk),
    .rstn             (rstn),
    .rxd_i            (rx_i),
    .os_tick_i        (os_tick_w),
    .cfg_i            (cfg_w),
    .data_o           (rx_data_o),
    .valid_o          (rx_valid_o),
    .ready_i          (rx_ready_i),
    .status_o         (rx_status_w),
    .rx_start_pulse_o (rx_start_pulse_w),
    .err_clear_i      (err_clear_i)
  );

  assign tx_busy_o     = tx_status_w.tx_busy;
  assign rx_busy_o     = rx_status_w.rx_busy;
  assign overrun_err_o = rx_status_w.overrun_err;
  assign frame_err_o   = rx_status_w.frame_err;
  assign parity_err_o  = rx_status_w.parity_err;

endmodule

`default_nettype wire

`endif // UART_OS_SV
