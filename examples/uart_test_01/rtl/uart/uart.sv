`default_nettype none

import uart_pkg::*;

module uart #(
  parameter int CLK_FREQ_HZ    = 50_000_000,
  parameter int BAUD_RATE      = 115_200,
  parameter int DATA_WIDTH     = 8,
  parameter bit STOP2          = 1'b0,
  parameter logic [1:0] PARITY = 2'b00, // 00 none, 01 odd, 10 even
  parameter logic [1:0] DBITS  = 2'b00  // 00=8, 01=7, 10=6, 11=5
)(
  input  wire                  clk,
  input  wire                  rstn,

  // UART pins
  input  wire                  rx_i,
  output wire                  tx_o,

  // TX stream
  input  wire [DATA_WIDTH-1:0] tx_data_i,
  input  wire                  tx_valid_i,
  output wire                  tx_ready_o,
  output wire                  tx_done_o,

  // RX stream
  output wire [DATA_WIDTH-1:0] rx_data_o,
  output wire                  rx_valid_o,
  input  wire                  rx_ready_i,

  // Control
  input  wire                  err_clear_i,

  // Status
  output wire                  tx_busy_o,
  output wire                  rx_busy_o,
  output wire                  overrun_err_o,
  output wire                  frame_err_o,
  output wire                  parity_err_o
);

  localparam int PRESCALE_VALUE = CLK_FREQ_HZ / BAUD_RATE;
  localparam int PRESCALE_WIDTH = $clog2(PRESCALE_VALUE + 1);

  initial begin
    assert(CLK_FREQ_HZ > 0);
    assert(BAUD_RATE > 0);
    assert(PRESCALE_VALUE >= 2);
    assert(DATA_WIDTH <= 16);
  end

  wire [PRESCALE_WIDTH-1:0] prescale;
  assign prescale = PRESCALE_VALUE[PRESCALE_WIDTH-1:0];

  uart_conf_t cfg;
  assign cfg.reserved = '0;
  assign cfg.stop2    = STOP2;
  assign cfg.parity   = PARITY;
  assign cfg.dbits    = DBITS;

  wire tx_start_tick;
  wire tx_half_tick;
  wire tx_end_tick;

  wire rx_start_tick;
  wire rx_half_tick;
  wire rx_end_tick;

  wire tx_start_pulse;
  wire rx_start_pulse;

  uart_status_t tx_status;
  uart_status_t rx_status;

  uart_baud_gen #(
    .PRESCALE_WIDTH(PRESCALE_WIDTH)
  ) u_tx_baud_gen (
    .clk(clk),
    .rstn(rstn),
    .start_i(tx_start_pulse),
    .enable_i(tx_status.tx_busy),
    .prescale_i(prescale),
    .start_tick_o(tx_start_tick),
    .half_tick_o(tx_half_tick),
    .end_tick_o(tx_end_tick)
  );

  uart_baud_gen #(
    .PRESCALE_WIDTH(PRESCALE_WIDTH)
  ) u_rx_baud_gen (
    .clk(clk),
    .rstn(rstn),
    .start_i(rx_start_pulse),
    .enable_i(rx_status.rx_busy),
    .prescale_i(prescale),
    .start_tick_o(rx_start_tick),
    .half_tick_o(rx_half_tick),
    .end_tick_o(rx_end_tick)
  );

  uart_core_tx #(
    .DATA_WIDTH(DATA_WIDTH)
  ) u_tx (
    .clk(clk),
    .rstn(rstn),

    .start_tick_i(tx_start_tick),
    .half_tick_i(tx_half_tick),
    .end_tick_i(tx_end_tick),

    .cfg_i(cfg),

    .data_i(tx_data_i),
    .valid_i(tx_valid_i),
    .ready_o(tx_ready_o),

    .txd_o(tx_o),

    .status_o(tx_status),

    .tx_done_pulse_o(tx_done_o),
    .tx_start_pulse_o(tx_start_pulse)
  );

  uart_core_rx #(
    .DATA_WIDTH(DATA_WIDTH)
  ) u_rx (
    .clk(clk),
    .rstn(rstn),

    .rxd_i(rx_i),

    .start_tick_i(rx_start_tick),
    .half_tick_i(rx_half_tick),
    .end_tick_i(rx_end_tick),

    .cfg_i(cfg),

    .data_o(rx_data_o),
    .valid_o(rx_valid_o),
    .ready_i(rx_ready_i),

    .status_o(rx_status),

    .rx_start_pulse_o(rx_start_pulse),
    .err_clear_i(err_clear_i)
  );

  assign tx_busy_o     = tx_status.tx_busy;
  assign rx_busy_o     = rx_status.rx_busy;
  assign overrun_err_o = rx_status.overrun_err;
  assign frame_err_o   = rx_status.frame_err;
  assign parity_err_o  = rx_status.parity_err;

endmodule

`default_nettype wire
