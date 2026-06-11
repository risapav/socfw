// tb_uart_core_rx_os -- unit tests for uart_core_rx_os (16x oversampled RX)
//
// Tests:
//   R01  Single byte 0x55: correct reception
//   R02  Sequential bytes [0xAA, 0x55]: both received correctly
//   R03  False start glitch rejection: rxd low for < half bit, no output
//   R04  Frame error: stop bit = 0, frame_err set, err_clear clears it
//   R05  Majority vote: glitch on first OS tick only -> correct reception
//   R06  Burst 8 bytes (parallel send + drain)
//
// Sim parameters: SIM_CLK=1_600_000, SIM_BAUD=25_000
//   BIT_CLKS   = 64  (clock cycles per bit)
//   OS_PRESCALE = 4  (clock cycles per OS tick, satisfies MIN_PRESCALE=8 check)
//   Note: MIN_PRESCALE in baud_gen is 8; we use 8 with SIM_BAUD=12_500
//
// REVISED: SIM_BAUD=12_500 -> BIT_CLKS=128, OS_PRESCALE=8
//
// Run: vsim -c -do "run -all; quit" tb_uart_core_rx_os

`timescale 1ns/1ps

module tb_uart_core_rx_os;
  import uart_pkg::*;

  // =========================================================================
  // Sim parameters
  // =========================================================================
  localparam int SIM_CLK_HZ   = 1_600_000;
  localparam int SIM_BAUD     = 12_500;
  localparam int BIT_CLKS     = SIM_CLK_HZ / SIM_BAUD;              // 128
  localparam int OS_PRESCALE  = (SIM_CLK_HZ + SIM_BAUD*8) / (SIM_BAUD*16); // 8
  localparam int OS_PRESCALE_W = $clog2(OS_PRESCALE + 1);           // 4

  // =========================================================================
  // Clock + reset
  // =========================================================================
  logic clk  = 1'b0;
  logic rstn = 1'b0;

  always #5 clk = ~clk;

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic rxd_drv   = 1'b1;
  logic err_clear = 1'b0;
  logic rx_ready  = 1'b0;

  uart_conf_t cfg;
  wire [7:0]       rx_data;
  wire             rx_valid;
  uart_core_status_t    rx_status;
  wire             rx_start_pulse;

  initial begin
    cfg          = '0;
    cfg.stop2    = 1'b0;
    cfg.parity   = 2'b00;
    cfg.dbits    = 2'b00;
  end

  // =========================================================================
  // Baud generator (16x OS)
  // =========================================================================
  wire os_tick_w;

  uart_baud_gen #(
    .PRESCALE_WIDTH (OS_PRESCALE_W)
  ) u_baud (
    .clk         (clk),
    .rstn        (rstn),
    .start_i     (rx_start_pulse),
    .enable_i    (rx_status.rx_busy),
    .prescale_i  (OS_PRESCALE_W'(OS_PRESCALE)),
    .start_tick_o(),
    .half_tick_o (),
    .end_tick_o  (os_tick_w)
  );

  // =========================================================================
  // DUT: uart_core_rx_os
  // =========================================================================
  uart_core_rx_os #(
    .DATA_WIDTH (8)
  ) dut (
    .clk              (clk),
    .rstn             (rstn),
    .rxd_i            (rxd_drv),
    .os_tick_i        (os_tick_w),
    .cfg_i            (cfg),
    .data_o           (rx_data),
    .valid_o          (rx_valid),
    .ready_i          (rx_ready),
    .status_o         (rx_status),
    .rx_start_pulse_o (rx_start_pulse),
    .err_clear_i      (err_clear)
  );

  // =========================================================================
  // UART frame driver task (aligned on clock edge)
  // =========================================================================
  task automatic send_byte(input logic [7:0] data);
    @(posedge clk);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = 1'b1;
    repeat(BIT_CLKS) @(posedge clk);
  endtask

  // Send with glitch on first OS_PRESCALE clocks of specified data bit
  task automatic send_byte_with_glitch(input logic [7:0] data,
                                       input int glitch_bit);
    @(posedge clk);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      if (i == glitch_bit) begin
        rxd_drv = ~data[i];
        repeat(OS_PRESCALE) @(posedge clk);
        rxd_drv = data[i];
        repeat(BIT_CLKS - OS_PRESCALE) @(posedge clk);
      end else begin
        rxd_drv = data[i];
        repeat(BIT_CLKS) @(posedge clk);
      end
    end
    rxd_drv = 1'b1;
    repeat(BIT_CLKS) @(posedge clk);
  endtask

  // Consume one held-valid byte from DUT
  task automatic consume(output logic [7:0] got);
    int timeout = 0;
    while (!rx_valid) begin
      @(posedge clk);
      timeout++;
      if (timeout > 20000) begin
        got = 8'hXX;
        $display("# TIMEOUT waiting for rx_valid");
        return;
      end
    end
    @(posedge clk);
    got      = rx_data;
    rx_ready = 1'b1;
    @(posedge clk);
    rx_ready = 1'b0;
    @(posedge clk);
  endtask

  // =========================================================================
  // Pass/fail helpers
  // =========================================================================
  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic check(input string label, input logic cond);
    if (cond) begin $display("# PASS %s", label); pass_cnt++; end
    else      begin $display("# FAIL %s", label); fail_cnt++; end
  endtask

  // =========================================================================
  // Test body
  // =========================================================================
  logic [7:0] got;
  logic [7:0] got2;

  initial begin
    rstn = 1'b0;
    repeat(4) @(posedge clk);
    rstn = 1'b1;
    repeat(4) @(posedge clk);

    // ------------------------------------------------------------------
    // R01: Single byte 0x55
    // ------------------------------------------------------------------
    send_byte(8'h55);
    consume(got);
    check("R01 received 0x55",  got === 8'h55);
    check("R01 no frame_err",   !rx_status.frame_err);
    check("R01 no overrun",     !rx_status.overrun_err);

    // ------------------------------------------------------------------
    // R02: Two bytes sequentially [0xAA, 0x55]
    // ------------------------------------------------------------------
    send_byte(8'hAA);
    consume(got);
    check("R02 byte[0]=0xAA", got === 8'hAA);
    send_byte(8'h55);
    consume(got);
    check("R02 byte[1]=0x55", got === 8'h55);

    // ------------------------------------------------------------------
    // R03: False start glitch rejection
    //   RXD low for BIT_CLKS/4 clocks (< half-bit), returns high.
    //   Center sample (tick 8 of 16) fires at ~8*8=64 clk after edge.
    //   By then RXD is already HIGH -> false start -> no byte output.
    // ------------------------------------------------------------------
    @(posedge clk);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS / 4) @(posedge clk);  // 32 clks low (< 64-clk half-bit)
    rxd_drv = 1'b1;
    repeat(BIT_CLKS * 2) @(posedge clk);
    check("R03 no byte from glitch", !rx_valid);

    // ------------------------------------------------------------------
    // R04: Frame error (stop bit = 0)
    // ------------------------------------------------------------------
    @(posedge clk);
    rxd_drv = 1'b0;                         // start bit
    repeat(BIT_CLKS) @(posedge clk);
    begin : blk_r04
      logic [7:0] tmp;
      tmp = 8'hAB;
      for (int i = 0; i < 8; i++) begin
        rxd_drv = tmp[i];
        repeat(BIT_CLKS) @(posedge clk);
      end
    end
    rxd_drv = 1'b0;                          // BAD stop bit
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv = 1'b1;
    repeat(BIT_CLKS * 2) @(posedge clk);
    check("R04 frame_err set",    rx_status.frame_err);
    err_clear = 1'b1;
    @(posedge clk);
    err_clear = 1'b0;
    @(posedge clk);
    check("R04 frame_err cleared", !rx_status.frame_err);
    // Flush the frame-error byte (DUT still asserts rx_valid for errored bytes)
    rx_ready = 1'b1;
    @(posedge clk);
    rx_ready = 1'b0;
    @(posedge clk);

    // ------------------------------------------------------------------
    // R05: Majority vote
    //   Bit 0 of 0x5A (=0101_1010) is 0.
    //   Glitch on first OS tick inverts it to 1 for OS_PRESCALE clocks.
    //   Majority vote uses ticks 6,7,8 (all at >> OS_PRESCALE clk in).
    //   Expected: 0x5A received correctly despite the glitch.
    // ------------------------------------------------------------------
    send_byte_with_glitch(8'h5A, 0);
    consume(got);
    check("R05 majority: 0x5A despite 1-tick glitch on bit0", got === 8'h5A);
    check("R05 no frame_err after glitch",                    !rx_status.frame_err);

    // ------------------------------------------------------------------
    // R06: Burst 8 bytes (fork: sender + consumer in parallel)
    // ------------------------------------------------------------------
    begin : blk_r06
      logic [7:0] burst[8];
      logic [7:0] results[8];
      burst[0] = 8'h00; burst[1] = 8'hFF; burst[2] = 8'hAA; burst[3] = 8'h55;
      burst[4] = 8'h81; burst[5] = 8'h7E; burst[6] = 8'h01; burst[7] = 8'hFE;
      fork
        // Sender thread
        begin
          for (int i = 0; i < 8; i++) send_byte(burst[i]);
        end
        // Consumer thread
        begin
          for (int i = 0; i < 8; i++) consume(results[i]);
        end
      join
      for (int i = 0; i < 8; i++)
        check($sformatf("R06 burst[%0d]=0x%02X", i, burst[i]),
              results[i] === burst[i]);
    end

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(10) @(posedge clk);
    $display("# tb_uart_core_rx_os: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("# tb_uart_core_rx_os: all tests passed");
    else
      $display("# FAIL tb_uart_core_rx_os: %0d failures", fail_cnt);
    $finish;
  end

endmodule
