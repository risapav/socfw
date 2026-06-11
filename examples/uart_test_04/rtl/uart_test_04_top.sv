/**
 * @file    uart_test_04_top.sv
 * @brief   UART test 04 top-level: 16x oversampled FIFO loopback on 125 MHz PLL clock.
 * @param   CLK_FREQ_HZ  Must match the PLL output frequency (default 125 MHz).
 * @param   BAUD_RATE    Baud rate (default 115200).
 * @details
 *  Identical loopback architecture to uart_test_03_top but uses uart_fifo_os
 *  (16x oversampled RX) instead of uart_fifo (1x sampler).
 *
 *  RX baud generator runs at 16x baud rate (PRESCALE_OS=68 @ 125 MHz/115200).
 *  Majority vote on center 3 samples provides glitch rejection on UART RX.
 *
 *  LED mapping (via uart_stream_loopback_status):
 *    0  RX byte accepted -- stretched pulse
 *    1  TX byte accepted -- stretched pulse
 *    2  RX busy
 *    3  TX busy
 *    4  Any UART error latched since last reset
 *    5  Heartbeat (~1 Hz @ 125 MHz)
 */

`ifndef UART_TEST_04_TOP_SV
`define UART_TEST_04_TOP_SV

`default_nettype none

module uart_test_04_top #(
  parameter int CLK_FREQ_HZ = 125_000_000,
  parameter int BAUD_RATE   = 115_200
)(
  input  wire       clk_i,
  input  wire       rst_ni,
  input  wire       pll_locked_i,

  input  wire       uart_rx_i,
  output wire       uart_tx_o,

  output wire [5:0] led_o
);

  // ==========================================================================
  // Reset synchroniser (async assert, sync deassert, waits for PLL locked)
  // ==========================================================================
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  logic [1:0] rst_sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rst_sync_q <= 2'b00;
    else         rst_sync_q <= {rst_sync_q[0], pll_locked_i};
  end

  wire rstn_w = rst_sync_q[1];

  // ==========================================================================
  // UART with FIFOs (16x oversampled RX)
  // ==========================================================================
  wire [7:0] rx_data_w;
  wire       rx_valid_w, rx_ready_w;
  wire [7:0] tx_data_w;
  wire       tx_valid_w, tx_ready_w;
  wire       err_clear_w;
  wire       tx_busy_w, rx_busy_w;
  wire       overrun_err_w, frame_err_w, parity_err_w;

  uart_fifo_os #(
    .CLK_FREQ_HZ   (CLK_FREQ_HZ),
    .BAUD_RATE     (BAUD_RATE),
    .DATA_WIDTH    (8),
    .RX_FIFO_DEPTH (64),
    .TX_FIFO_DEPTH (64)
  ) u_uart_fifo (
    .clk                (clk_i),
    .rstn               (rstn_w),
    .rx_i               (uart_rx_i),
    .tx_o               (uart_tx_o),
    .tx_data_i          (tx_data_w),
    .tx_valid_i         (tx_valid_w),
    .tx_ready_o         (tx_ready_w),
    .rx_data_o          (rx_data_w),
    .rx_valid_o         (rx_valid_w),
    .rx_ready_i         (rx_ready_w),
    .err_clear_i        (err_clear_w),
    .tx_busy_o          (tx_busy_w),
    .rx_busy_o          (rx_busy_w),
    .overrun_err_o      (overrun_err_w),
    .frame_err_o        (frame_err_w),
    .parity_err_o       (parity_err_w),
    .tx_fifo_level_o    (),
    .rx_fifo_level_o    (),
    .tx_fifo_full_o     (),
    .tx_fifo_empty_o    (),
    .rx_fifo_full_o     (),
    .rx_fifo_empty_o    (),
    .rx_fifo_overflow_o (),
    .tx_fifo_overflow_o (),
    .rx_fifo_underflow_o(),
    .tx_fifo_underflow_o()
  );

  // ==========================================================================
  // Loopback + LED status
  // ==========================================================================
  uart_stream_loopback_status #(
    .DATA_WIDTH              (8),
    .LED_WIDTH               (6),
    .HEARTBEAT_COUNTER_WIDTH (26),
    .PULSE_STRETCH_WIDTH     (24)
  ) u_loopback (
    .clk          (clk_i),
    .rstn         (rstn_w),
    .rx_data_i    (rx_data_w),
    .rx_valid_i   (rx_valid_w),
    .rx_ready_o   (rx_ready_w),
    .tx_data_o    (tx_data_w),
    .tx_valid_o   (tx_valid_w),
    .tx_ready_i   (tx_ready_w),
    .rx_busy_i    (rx_busy_w),
    .tx_busy_i    (tx_busy_w),
    .overrun_err_i(overrun_err_w),
    .frame_err_i  (frame_err_w),
    .parity_err_i (parity_err_w),
    .err_clear_o  (err_clear_w),
    .leds_o       (led_o)
  );

endmodule

`default_nettype wire

`endif // UART_TEST_04_TOP_SV
