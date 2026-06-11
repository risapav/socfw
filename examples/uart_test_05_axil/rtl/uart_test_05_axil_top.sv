/**
 * @file    uart_test_05_axil_top.sv
 * @brief   UART test 05 top-level: AXI-Lite UART loopback via uart_axil peripheral.
 * @param   CLK_FREQ_HZ  Must match PLL output frequency (default 125 MHz).
 * @param   BAUD_RATE    Baud rate (default 115200).
 * @param   FIFO_DEPTH   RX and TX FIFO depth in bytes (default 64).
 * @details
 *  Demonstrates uart_axil as a synthesizable AXI-Lite peripheral.
 *  An internal axil_uart_loopback master polls the STATUS register,
 *  reads RX_DATA (popping the RX FIFO), and writes the byte to TX_DATA.
 *
 *  Data path:
 *    UART RX  -->  uart_axil RX FIFO  -->  axil_uart_loopback  -->  uart_axil TX FIFO  -->  UART TX
 *                  (via AXI-Lite registers: STATUS poll, RX_DATA read, TX_DATA write)
 *
 *  LED mapping:
 *    [0]  RX byte received  (1-cycle pulse, stretched ~33ms)
 *    [1]  TX byte sent      (1-cycle pulse, stretched ~33ms)
 *    [2]  uart_axil IRQ     (any enabled IRQ asserted)
 *    [3]  unused (0)
 *    [4]  unused (0)
 *    [5]  Heartbeat ~0.93 Hz at 125 MHz (bit 26 of free-running counter)
 */

`ifndef UART_TEST_05_AXIL_TOP_SV
`define UART_TEST_05_AXIL_TOP_SV

`default_nettype none

import axi_pkg::*;

module uart_test_05_axil_top #(
  parameter int CLK_FREQ_HZ = 125_000_000,
  parameter int BAUD_RATE   = 115_200,
  parameter int FIFO_DEPTH  = 64
)(
  input  wire       clk_i,
  input  wire       rst_ni,
  input  wire       pll_locked_i,

  input  wire       uart_rx_i,
  output wire       uart_tx_o,

  output wire [5:0] led_o
);

  // ==========================================================================
  // Reset synchroniser (async assert, sync deassert, holds until PLL locked)
  // ==========================================================================
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  logic [1:0] rst_sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rst_sync_q <= 2'b00;
    else         rst_sync_q <= {rst_sync_q[0], pll_locked_i};
  end

  wire rstn_w = rst_sync_q[1];

  // ==========================================================================
  // AXI-Lite bus (ADDR_WIDTH=8: covers 0x00-0x2C register space)
  // ==========================================================================
  axi4lite_if #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) axil_bus (
    .ACLK   (clk_i),
    .ARESETn(rstn_w)
  );

  // ==========================================================================
  // uart_axil peripheral
  // ==========================================================================
  wire irq_w;

  uart_axil #(
    .CLK_FREQ_HZ    (CLK_FREQ_HZ),
    .BAUD_RATE      (BAUD_RATE),
    .RX_FIFO_DEPTH  (FIFO_DEPTH),
    .TX_FIFO_DEPTH  (FIFO_DEPTH)
  ) u_uart (
    .clk_i  (clk_i),
    .rst_ni (rstn_w),
    .s_axil (axil_bus),
    .rx_i   (uart_rx_i),
    .tx_o   (uart_tx_o),
    .irq_o  (irq_w)
  );

  // ==========================================================================
  // AXI-Lite loopback master
  // ==========================================================================
  wire rx_active_w, tx_active_w;

  axil_uart_loopback u_loop (
    .clk_i      (clk_i),
    .rst_ni     (rstn_w),
    .m_axil     (axil_bus),
    .rx_active_o(rx_active_w),
    .tx_active_o(tx_active_w)
  );

  // ==========================================================================
  // LED logic
  // ==========================================================================

  // Heartbeat: bit[26] toggles at CLK / 2^27 ~= 0.93 Hz @ 125 MHz
  logic [26:0] hb_cnt_r;
  always_ff @(posedge clk_i or negedge rstn_w)
    if (!rstn_w) hb_cnt_r <= '0;
    else         hb_cnt_r <= hb_cnt_r + 27'd1;

  // Activity pulse stretcher: hold LED for 2^22 clocks (~33 ms @ 125 MHz)
  logic [21:0] rx_stretch_r, tx_stretch_r;
  always_ff @(posedge clk_i or negedge rstn_w) begin
    if (!rstn_w) begin
      rx_stretch_r <= '0;
      tx_stretch_r <= '0;
    end else begin
      if (rx_active_w)
        rx_stretch_r <= '1;
      else if (rx_stretch_r != '0)
        rx_stretch_r <= rx_stretch_r - 22'd1;

      if (tx_active_w)
        tx_stretch_r <= '1;
      else if (tx_stretch_r != '0)
        tx_stretch_r <= tx_stretch_r - 22'd1;
    end
  end

  assign led_o[0] = (rx_stretch_r != '0);
  assign led_o[1] = (tx_stretch_r != '0);
  assign led_o[2] = irq_w;
  assign led_o[3] = 1'b0;
  assign led_o[4] = 1'b0;
  assign led_o[5] = hb_cnt_r[26];

endmodule

`default_nettype wire

`endif // UART_TEST_05_AXIL_TOP_SV
