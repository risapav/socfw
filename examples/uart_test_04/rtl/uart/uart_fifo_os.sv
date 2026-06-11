/**
 * @file    uart_fifo_os.sv
 * @brief   UART wrapper with synchronous RX/TX FIFOs and 16x oversampled RX.
 * @param   CLK_FREQ_HZ    System clock frequency in Hz (default 125 MHz).
 * @param   BAUD_RATE      Desired baud rate (default 115200).
 * @param   DATA_WIDTH     Data width; must be 8.
 * @param   STOP2          True for 2 stop bits.
 * @param   PARITY         2'b00 none, 2'b01 odd, 2'b10 even.
 * @param   DBITS          2'b00=8, 2'b01=7, 2'b10=6, 2'b11=5 data bits.
 * @param   RX_FIFO_DEPTH     RX FIFO depth in bytes; must be a power of 2 > 1.
 * @param   TX_FIFO_DEPTH     TX FIFO depth in bytes; must be a power of 2 > 1.
 * @param   RX_FIFO_RAM_STYLE Quartus RAM implementation hint for RX FIFO ("logic", "M9K", "AUTO").
 * @param   TX_FIFO_RAM_STYLE Quartus RAM implementation hint for TX FIFO ("logic", "M9K", "AUTO").
 * @details
 *  Drop-in replacement for uart_fifo.sv.  Uses uart_os (16x oversampled RX)
 *  instead of uart.  All FIFO logic, back-pressure, and status signals are
 *  identical to uart_fifo.
 */

`ifndef UART_FIFO_OS_SV
`define UART_FIFO_OS_SV

`default_nettype none

import uart_pkg::*;

module uart_fifo_os #(
  parameter int         CLK_FREQ_HZ   = 125_000_000,
  parameter int         BAUD_RATE     = 115_200,
  parameter int         DATA_WIDTH    = 8,
  parameter bit         STOP2         = 1'b0,
  parameter logic [1:0] PARITY        = 2'b00,
  parameter logic [1:0] DBITS         = 2'b00,
  parameter int         RX_FIFO_DEPTH     = 64,
  parameter int         TX_FIFO_DEPTH     = 64,
  parameter string      RX_FIFO_RAM_STYLE = "logic",
  parameter string      TX_FIFO_RAM_STYLE = "logic"
)(
  input  wire clk,
  input  wire rstn,

  // UART serial pins
  input  wire rx_i,
  output wire tx_o,

  // TX user stream
  input  wire [DATA_WIDTH-1:0] tx_data_i,
  input  wire                  tx_valid_i,
  output wire                  tx_ready_o,

  // RX user stream (held-valid)
  output wire [DATA_WIDTH-1:0] rx_data_o,
  output wire                  rx_valid_o,
  input  wire                  rx_ready_i,

  // Control
  input  wire err_clear_i,

  // Status
  output wire tx_busy_o,
  output wire rx_busy_o,
  output wire [$clog2(TX_FIFO_DEPTH):0] tx_fifo_level_o,
  output wire [$clog2(RX_FIFO_DEPTH):0] rx_fifo_level_o,
  output wire                           tx_fifo_full_o,
  output wire                           tx_fifo_empty_o,
  output wire                           rx_fifo_full_o,
  output wire                           rx_fifo_empty_o,
  output wire                           rx_fifo_overflow_o,
  output wire                           tx_fifo_overflow_o,
  output wire                           rx_fifo_underflow_o,
  output wire                           tx_fifo_underflow_o,
  output wire                           overrun_err_o,
  output wire                           frame_err_o,
  output wire                           parity_err_o
);

  // synthesis translate_off
  initial begin
    assert(DATA_WIDTH == 8)
      else $fatal(1, "uart_fifo_os: DATA_WIDTH must be 8");
    assert(RX_FIFO_DEPTH > 1)
      else $fatal(1, "uart_fifo_os: RX_FIFO_DEPTH must be > 1");
    assert(TX_FIFO_DEPTH > 1)
      else $fatal(1, "uart_fifo_os: TX_FIFO_DEPTH must be > 1");
    assert(2**$clog2(RX_FIFO_DEPTH) == RX_FIFO_DEPTH)
      else $fatal(1, "uart_fifo_os: RX_FIFO_DEPTH must be a power of 2");
    assert(2**$clog2(TX_FIFO_DEPTH) == TX_FIFO_DEPTH)
      else $fatal(1, "uart_fifo_os: TX_FIFO_DEPTH must be a power of 2");
  end
  // synthesis translate_on

  wire [DATA_WIDTH-1:0] uart_rx_data_w;
  wire                  uart_rx_valid_w;
  wire                  uart_rx_ready_w;
  wire [DATA_WIDTH-1:0] uart_tx_data_w;
  wire                  uart_tx_valid_w;
  wire                  uart_tx_ready_w;

  // ------------------------------------------------------------------
  // UART core (16x oversampled RX)
  // ------------------------------------------------------------------
  uart_os #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .BAUD_RATE   (BAUD_RATE),
    .DATA_WIDTH  (DATA_WIDTH),
    .STOP2       (STOP2),
    .PARITY      (PARITY),
    .DBITS       (DBITS)
  ) u_uart (
    .clk          (clk),
    .rstn         (rstn),
    .rx_i         (rx_i),
    .tx_o         (tx_o),
    .tx_data_i    (uart_tx_data_w),
    .tx_valid_i   (uart_tx_valid_w),
    .tx_ready_o   (uart_tx_ready_w),
    .tx_done_o    (),
    .rx_data_o    (uart_rx_data_w),
    .rx_valid_o   (uart_rx_valid_w),
    .rx_ready_i   (uart_rx_ready_w),
    .err_clear_i  (err_clear_i),
    .tx_busy_o    (tx_busy_o),
    .rx_busy_o    (rx_busy_o),
    .overrun_err_o(overrun_err_o),
    .frame_err_o  (frame_err_o),
    .parity_err_o (parity_err_o)
  );

  // ------------------------------------------------------------------
  // RX FIFO
  // ------------------------------------------------------------------
  sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (RX_FIFO_DEPTH),
    .RAM_STYLE  (RX_FIFO_RAM_STYLE)
  ) u_rx_fifo (
    .clk        (clk),
    .rstn       (rstn),
    .wr_data_i  (uart_rx_data_w),
    .wr_valid_i (uart_rx_valid_w),
    .wr_ready_o (uart_rx_ready_w),
    .rd_data_o  (rx_data_o),
    .rd_valid_o (rx_valid_o),
    .rd_ready_i (rx_ready_i),
    .err_clear_i(err_clear_i),
    .level_o    (rx_fifo_level_o),
    .full_o     (rx_fifo_full_o),
    .empty_o    (rx_fifo_empty_o),
    .overflow_o (rx_fifo_overflow_o),
    .underflow_o(rx_fifo_underflow_o)
  );

  // ------------------------------------------------------------------
  // TX FIFO
  // ------------------------------------------------------------------
  sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (TX_FIFO_DEPTH),
    .RAM_STYLE  (TX_FIFO_RAM_STYLE)
  ) u_tx_fifo (
    .clk        (clk),
    .rstn       (rstn),
    .wr_data_i  (tx_data_i),
    .wr_valid_i (tx_valid_i),
    .wr_ready_o (tx_ready_o),
    .rd_data_o  (uart_tx_data_w),
    .rd_valid_o (uart_tx_valid_w),
    .rd_ready_i (uart_tx_ready_w),
    .err_clear_i(err_clear_i),
    .level_o    (tx_fifo_level_o),
    .full_o     (tx_fifo_full_o),
    .empty_o    (tx_fifo_empty_o),
    .overflow_o (tx_fifo_overflow_o),
    .underflow_o(tx_fifo_underflow_o)
  );

endmodule

`default_nettype wire

`endif // UART_FIFO_OS_SV
