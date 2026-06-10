/**
 * @file    uart_test_02_top.sv
 * @brief   UART test 02 top-level: loopback demo on 125 MHz PLL clock
 * @param   CLK_FREQ_HZ  Must match the PLL output frequency (default 125 MHz).
 * @param   BAUD_RATE    Baud rate (default 115200).
 * @details
 *  Wraps uart + uart_stream_loopback_status into a single clock domain.
 *
 *  Reset: rst_ni is the board active-low reset (RESET_N).  A 2-FF synchroniser
 *  inside this module produces rstn_sync_q, which is:
 *    - asynchronously asserted  (RESET_N low  -> rstn_sync immediately 0)
 *    - synchronously deasserted (RESET_N high -> rstn_sync high after 2 clocks)
 *
 *  Improvements over uart_test_01:
 *    - 125 MHz system clock via external PLL
 *    - PRESCALE_VALUE rounded to nearest integer (error < 0.01 %)
 *    - uart_core_rx: true AXI-Stream held valid (no byte loss on backpressure)
 *    - uart_core_rx: back-to-back frame detection (STOP -> START shortcut)
 *    - uart_core_tx: registered TXD output (no combinational glitches)
 *    - uart_baud_gen: clean reset (all tick outputs 0 after reset)
 *    - err_clear_o from loopback connected to uart.err_clear_i (was floating)
 *    - Synchronous reset deassert in the 125 MHz domain
 */

`ifndef UART_TEST_02_TOP_SV
`define UART_TEST_02_TOP_SV

`default_nettype none

module uart_test_02_top #(
  parameter int CLK_FREQ_HZ = 125_000_000,
  parameter int BAUD_RATE   = 115_200
)(
  input  wire       clk_i,
  input  wire       rst_ni,       // active-low async board reset (RESET_N)
  input  wire       pll_locked_i, // PLL locked -- held low until clk_i is stable

  input  wire       uart_rx_i,
  output wire       uart_tx_o,

  output wire [5:0] led_o
);

  // ==========================================================================
  // 1. Reset synchroniser (async assert, sync deassert) for clk125 domain
  //
  //  Shifts in pll_locked_i so that rstn_w stays low until both board reset
  //  has been released AND the PLL has locked (clk_i is stable).
  // ==========================================================================
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  logic [1:0] rst_sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rst_sync_q <= 2'b00;
    else         rst_sync_q <= {rst_sync_q[0], pll_locked_i};
  end

  wire rstn_w = rst_sync_q[1];

  // ==========================================================================
  // 2. UART core
  // ==========================================================================
  wire [7:0] rx_data_w;
  wire       rx_valid_w, rx_ready_w;
  wire [7:0] tx_data_w;
  wire       tx_valid_w, tx_ready_w;
  wire       err_clear_w;
  wire       tx_busy_w, rx_busy_w;
  wire       overrun_err_w, frame_err_w, parity_err_w;

  uart #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .BAUD_RATE   (BAUD_RATE),
    .DATA_WIDTH  (8),
    .STOP2       (1'b0),
    .PARITY      (2'b00),
    .DBITS       (2'b00)
  ) u_uart (
    .clk         (clk_i),
    .rstn        (rstn_w),
    .rx_i        (uart_rx_i),
    .tx_o        (uart_tx_o),
    .tx_data_i   (tx_data_w),
    .tx_valid_i  (tx_valid_w),
    .tx_ready_o  (tx_ready_w),
    .tx_done_o   (),
    .rx_data_o   (rx_data_w),
    .rx_valid_o  (rx_valid_w),
    .rx_ready_i  (rx_ready_w),
    .err_clear_i (err_clear_w),
    .tx_busy_o   (tx_busy_w),
    .rx_busy_o   (rx_busy_w),
    .overrun_err_o(overrun_err_w),
    .frame_err_o  (frame_err_w),
    .parity_err_o (parity_err_w)
  );

  // ==========================================================================
  // 3. Loopback + LED status
  // ==========================================================================
  uart_stream_loopback_status #(
    .DATA_WIDTH              (8),
    .LED_WIDTH               (6),
    .HEARTBEAT_COUNTER_WIDTH (26), // MSB toggles at ~0.93 Hz @ 125 MHz
    .PULSE_STRETCH_WIDTH     (24)  // activity pulse ~134 ms @ 125 MHz
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
    .err_clear_o  (err_clear_w),   // was floating in uart_test_01
    .leds_o       (led_o)
  );

endmodule

`default_nettype wire

`endif // UART_TEST_02_TOP_SV
