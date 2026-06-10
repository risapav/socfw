// tb_uart_fifo_loopback -- integration test: uart_fifo loopback
//
// Tests:
//   T01  single byte echo: 0x55
//   T02  burst 16 bytes back-to-back (would overflow uart_test_02 1-byte buffer)
//   T03  burst 64 bytes back-to-back (fills RX FIFO, all echoed correctly)
//   T04  frame error recovery: error_latch set; loopback continues
//   T05  512-byte LFSR stream (bulk, sequential echo per byte)
//
// Simulation parameters:
//   SIM_CLK_HZ=1_600_000, SIM_BAUD=100_000 -> PRESCALE=16, BIT_CLKS=16
//   FIFO_DEPTH=16 (small for faster simulation)
//
// Run: vsim -c -do "run -all; quit" tb_uart_fifo_loopback

`timescale 1ns/1ps

module tb_uart_fifo_loopback;
  import uart_pkg::*;

  // =========================================================================
  // Sim parameters
  // =========================================================================
  localparam int SIM_CLK_HZ  = 1_600_000;
  localparam int SIM_BAUD    = 100_000;
  localparam int BIT_CLKS    = (SIM_CLK_HZ + SIM_BAUD/2) / SIM_BAUD; // 16
  localparam int FIFO_DEPTH  = 16;

  // =========================================================================
  // Clock + reset
  // =========================================================================
  logic clk  = 1'b0;
  logic rstn = 1'b0;

  always #5 clk = ~clk;

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic rxd_drv = 1'b1;
  wire  txd;

  // UART FIFO user streams
  wire [7:0] rx_data_w;
  wire       rx_valid_w;
  wire       rx_ready_w;
  wire [7:0] tx_data_w;
  wire       tx_valid_w;
  wire       tx_ready_w;
  wire       tx_busy_w;
  wire       rx_busy_w;
  wire       overrun_err_w;
  wire       frame_err_w;
  wire       parity_err_w;
  wire       err_clear_w;
  wire [5:0] leds_w;

  // =========================================================================
  // DUT: uart_fifo (8N1)
  // =========================================================================
  uart_fifo #(
    .CLK_FREQ_HZ   (SIM_CLK_HZ),
    .BAUD_RATE     (SIM_BAUD),
    .RX_FIFO_DEPTH (FIFO_DEPTH),
    .TX_FIFO_DEPTH (FIFO_DEPTH)
  ) dut_uf (
    .clk           (clk),
    .rstn          (rstn),
    .rx_i          (rxd_drv),
    .tx_o          (txd),
    .tx_data_i     (tx_data_w),
    .tx_valid_i    (tx_valid_w),
    .tx_ready_o    (tx_ready_w),
    .rx_data_o     (rx_data_w),
    .rx_valid_o    (rx_valid_w),
    .rx_ready_i    (rx_ready_w),
    .err_clear_i   (err_clear_w),
    .tx_busy_o     (tx_busy_w),
    .rx_busy_o     (rx_busy_w),
    .overrun_err_o (overrun_err_w),
    .frame_err_o   (frame_err_w),
    .parity_err_o  (parity_err_w),
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

  // =========================================================================
  // DUT: loopback (reuse uart_stream_loopback_status)
  // =========================================================================
  uart_stream_loopback_status #(
    .HEARTBEAT_COUNTER_WIDTH (8),
    .PULSE_STRETCH_WIDTH     (8)
  ) dut_lb (
    .clk           (clk),
    .rstn          (rstn),
    .rx_data_i     (rx_data_w),
    .rx_valid_i    (rx_valid_w),
    .rx_ready_o    (rx_ready_w),
    .tx_data_o     (tx_data_w),
    .tx_valid_o    (tx_valid_w),
    .tx_ready_i    (tx_ready_w),
    .rx_busy_i     (rx_busy_w),
    .tx_busy_i     (tx_busy_w),
    .overrun_err_i (overrun_err_w),
    .frame_err_i   (frame_err_w),
    .parity_err_i  (parity_err_w),
    .err_clear_o   (err_clear_w),
    .leds_o        (leds_w)
  );

  // =========================================================================
  // Check helper
  // =========================================================================
  int fails = 0;

  task automatic chk(input logic cond, input string lbl);
    if (!cond) begin $display("FAIL %s", lbl); fails++; end
    else             $display("PASS %s", lbl);
  endtask

  // =========================================================================
  // BFM: drive rxd_drv (serial input to UART RX)
  // =========================================================================
  task automatic uart_send(input logic [7:0] data,
                           input bit frame_err_force = 0);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = frame_err_force ? 1'b0 : 1'b1;
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  task automatic uart_send_no_gap(input logic [7:0] data);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = 1'b1;
    repeat(BIT_CLKS) @(posedge clk);
  endtask

  // =========================================================================
  // BFM: capture one echo byte from UART TX output (txd)
  // =========================================================================
  task automatic uart_recv(output logic [7:0] data_out);
    @(negedge txd);
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      data_out[i] = txd;
      repeat(BIT_CLKS) @(posedge clk);
    end
    chk(txd === 1'b1, "echo stop bit high");
  endtask

  // =========================================================================
  // Stimulus
  // =========================================================================
  logic [7:0] got;
  logic [7:0] got_arr[64];
  logic [7:0] stream_512[512];

  initial begin
    repeat(4) @(posedge clk);
    rstn = 1'b1;
    repeat(4) @(posedge clk);

    // ------------------------------------------------------------------
    // T01: single byte echo
    // ------------------------------------------------------------------
    fork
      uart_send(8'h55);
      uart_recv(got);
    join
    chk(got === 8'h55, "T01 echo 0x55");

    // ------------------------------------------------------------------
    // T02: burst 16 bytes back-to-back
    //   uart_test_02 would overflow at byte 2 (1-byte buffer).
    //   uart_fifo buffers all 16 in RX FIFO (depth=16).
    // ------------------------------------------------------------------
    fork
      begin
        for (int i = 0; i < 16; i++)
          uart_send_no_gap(8'hC0 + i[7:0]);
        rxd_drv = 1'b1;
      end
      begin
        for (int i = 0; i < 16; i++) begin
          uart_recv(got_arr[i]);
          chk(got_arr[i] === 8'hC0 + i[7:0],
              $sformatf("T02 b2b byte[%0d] expected=0x%02h", i, 8'hC0 + i[7:0]));
        end
      end
    join

    // ------------------------------------------------------------------
    // T03: burst 64 bytes back-to-back (4x FIFO depth)
    //   FIFO buffers up to FIFO_DEPTH at a time; loopback drains at line
    //   rate so no overflow occurs (equal TX/RX baud rates).
    // ------------------------------------------------------------------
    fork
      begin
        for (int i = 0; i < 64; i++)
          uart_send_no_gap(8'(i));
        rxd_drv = 1'b1;
      end
      begin
        for (int i = 0; i < 64; i++) begin
          uart_recv(got_arr[i]);
          chk(got_arr[i] === 8'(i),
              $sformatf("T03 bulk byte[%0d] expected=0x%02h", i, 8'(i)));
        end
      end
    join

    // ------------------------------------------------------------------
    // T04: frame error recovery
    // ------------------------------------------------------------------
    fork
      uart_send(8'h5A, .frame_err_force(1));
      uart_recv(got);
    join
    repeat(BIT_CLKS * 2) @(posedge clk);
    chk(leds_w[4] === 1'b1, "T04 error_latch set after frame error");
    fork
      uart_send(8'hD5);
      uart_recv(got);
    join
    chk(got === 8'hD5, "T04 recovery: echo 0xD5 after frame error");

    // ------------------------------------------------------------------
    // T05: 512-byte LFSR stream (sequential echo, seed=0xA5)
    // ------------------------------------------------------------------
    begin
      logic [7:0] lfsr;
      lfsr = 8'hA5;
      for (int k = 0; k < 512; k++) begin
        lfsr = {lfsr[6:0], 1'b0} ^ (lfsr[7] ? 8'b0111_0001 : 8'b0);
        stream_512[k] = lfsr;
      end
      for (int k = 0; k < 512; k++) begin
        fork
          uart_send(stream_512[k]);
          uart_recv(got);
        join
        chk(got === stream_512[k],
            $sformatf("T05 byte[%0d] expected=0x%02h", k, stream_512[k]));
      end
    end

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    if (fails == 0)
      $display("PASS tb_uart_fifo_loopback: all tests passed");
    else
      $display("FAIL tb_uart_fifo_loopback: %0d test(s) failed", fails);

    $finish;
  end

  initial begin
    repeat(10_000_000) @(posedge clk);
    $display("FAIL tb_uart_fifo_loopback: TIMEOUT");
    $finish;
  end

endmodule : tb_uart_fifo_loopback
