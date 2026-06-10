// tb_uart_loopback -- integration test: uart + uart_stream_loopback_status
//
// Tests:
//   T01  single byte echo: 0x55
//   T02  burst 8 bytes with inter-frame gap: [0xA0..0xA7], order preserved
//   T03  burst 8 bytes back-to-back, all echoed in order
//   T04  frame error recovery: error_latch set; loopback continues after
//   T05  1024-byte random stream (sequential echo, seed=0xA5)
//
// Simulation parameters:
//   SIM_CLK_HZ=1_600_000, SIM_BAUD=100_000 -> PRESCALE=16, BIT_CLKS=16
//
// Run: vsim -c -do "run -all; quit" tb_uart_loopback

`timescale 1ns/1ps

module tb_uart_loopback;
  import uart_pkg::*;

  // =========================================================================
  // Sim parameters
  // =========================================================================
  localparam int SIM_CLK_HZ = 1_600_000;
  localparam int SIM_BAUD   = 100_000;
  localparam int BIT_CLKS   = (SIM_CLK_HZ + SIM_BAUD/2) / SIM_BAUD; // 16

  // =========================================================================
  // Clock + reset
  // =========================================================================
  logic clk  = 1'b0;
  logic rstn = 1'b0;

  always #5 clk = ~clk;

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic       rxd_drv = 1'b1;
  wire        txd;

  // UART <-> loopback internal wires
  wire [7:0]  rx_data_w;
  wire        rx_valid_w;
  wire        rx_ready_w;
  wire [7:0]  tx_data_w;
  wire        tx_valid_w;
  wire        tx_ready_w;
  wire        tx_busy_w;
  wire        rx_busy_w;
  wire        overrun_err_w;
  wire        frame_err_w;
  wire        parity_err_w;
  wire        err_clear_w;
  wire [5:0]  leds_w;

  // =========================================================================
  // DUT: uart (8N1)
  // =========================================================================
  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD)
  ) dut_uart (
    .clk           (clk),
    .rstn          (rstn),
    .rx_i          (rxd_drv),
    .tx_o          (txd),
    .tx_data_i     (tx_data_w),
    .tx_valid_i    (tx_valid_w),
    .tx_ready_o    (tx_ready_w),
    .tx_done_o     (),
    .rx_data_o     (rx_data_w),
    .rx_valid_o    (rx_valid_w),
    .rx_ready_i    (rx_ready_w),
    .err_clear_i   (err_clear_w),
    .tx_busy_o     (tx_busy_w),
    .rx_busy_o     (rx_busy_w),
    .overrun_err_o (overrun_err_w),
    .frame_err_o   (frame_err_w),
    .parity_err_o  (parity_err_w)
  );

  // =========================================================================
  // DUT: loopback buffer
  //   HEARTBEAT_COUNTER_WIDTH and PULSE_STRETCH_WIDTH reduced for simulation
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
    rxd_drv = 1'b0;                                         // start bit
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = frame_err_force ? 1'b0 : 1'b1;               // stop bit
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv = 1'b1;                                         // idle
    repeat(2) @(posedge clk);                               // settle
  endtask

  // Send without trailing idle gap (for back-to-back tests)
  task automatic uart_send_no_gap(input logic [7:0] data);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = 1'b1;                                         // stop bit only
    repeat(BIT_CLKS) @(posedge clk);
    // no trailing idle
  endtask

  // =========================================================================
  // BFM: capture one echo byte from UART TX output (txd)
  // =========================================================================
  task automatic uart_recv(output logic [7:0] data_out);
    @(negedge txd);                                         // detect start bit
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);          // center of bit 0
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
  logic [7:0] got_arr[8];
  logic [7:0] stream_1024[1024];

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
    // T02: burst 8 bytes with inter-frame gap, verify order preserved
    // ------------------------------------------------------------------
    fork
      begin
        for (int i = 0; i < 8; i++)
          uart_send(8'hA0 + i[7:0]);
      end
      begin
        for (int i = 0; i < 8; i++) begin
          uart_recv(got_arr[i]);
          chk(got_arr[i] === 8'hA0 + i[7:0],
              $sformatf("T02 byte[%0d] expected=0x%02h", i, 8'hA0 + i[7:0]));
        end
      end
    join

    // ------------------------------------------------------------------
    // T03: burst 8 bytes back-to-back, verify all echoed in order
    // ------------------------------------------------------------------
    fork
      begin
        for (int i = 0; i < 8; i++)
          uart_send_no_gap(8'hB0 + i[7:0]);
        rxd_drv = 1'b1;                     // return to idle after burst
      end
      begin
        for (int i = 0; i < 8; i++) begin
          uart_recv(got_arr[i]);
          chk(got_arr[i] === 8'hB0 + i[7:0],
              $sformatf("T03 back-to-back byte[%0d] expected=0x%02h", i, 8'hB0 + i[7:0]));
        end
      end
    join

    // ------------------------------------------------------------------
    // T04: frame error recovery
    //   Send a byte with forced-low stop bit. The UART detects frame_err;
    //   loopback latches error (leds_o[4]) and auto-clears via err_clear_o.
    //   Verify error_latch set, then verify loopback echoes next byte correctly.
    // ------------------------------------------------------------------
    fork
      uart_send(8'h5A, .frame_err_force(1));  // frame error: stop bit low
      uart_recv(got);                          // drain the (possibly echoed) byte
    join
    repeat(BIT_CLKS * 2) @(posedge clk);
    chk(leds_w[4] === 1'b1, "T04 error_latch set after frame error");
    // verify loopback still operates correctly after the error
    fork
      uart_send(8'hD5);
      uart_recv(got);
    join
    chk(got === 8'hD5, "T04 recovery: echo 0xD5 after frame error");

    // ------------------------------------------------------------------
    // T05: 1024-byte random stream
    //   Sequential send-then-echo per byte (1-byte loopback buffer design).
    //   LFSR seed=0xA5 generates deterministic pseudo-random sequence.
    // ------------------------------------------------------------------
    begin
      logic [7:0] lfsr;
      lfsr = 8'hA5;
      for (int k = 0; k < 1024; k++) begin
        // Galois LFSR, polynomial x^8+x^6+x^5+x^4+1 (maximal length)
        lfsr = {lfsr[6:0], 1'b0} ^ (lfsr[7] ? 8'b0111_0001 : 8'b0);
        stream_1024[k] = lfsr;
      end
      for (int k = 0; k < 1024; k++) begin
        fork
          uart_send(stream_1024[k]);
          uart_recv(got);
        join
        chk(got === stream_1024[k],
            $sformatf("T05 byte[%0d] expected=0x%02h", k, stream_1024[k]));
      end
    end

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    if (fails == 0)
      $display("PASS tb_uart_loopback: all tests passed");
    else
      $display("FAIL tb_uart_loopback: %0d test(s) failed", fails);

    $finish;
  end

  // Timeout watchdog
  initial begin
    repeat(5_000_000) @(posedge clk);
    $display("FAIL tb_uart_loopback: TIMEOUT");
    $finish;
  end

endmodule : tb_uart_loopback
