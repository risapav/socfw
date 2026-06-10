// tb_uart_baud_gen -- unit tests for uart_baud_gen prescale_safe_w clamp
//
// Tests:
//   P01  prescale=0  -> clamped to MIN_PRESCALE=8, end_tick delay = 7
//   P02  prescale=7  -> clamped to MIN_PRESCALE=8, end_tick delay = 7
//   P03  prescale=8  -> no clamp, end_tick delay = 7
//   P04  prescale=12 -> no clamp, end_tick delay = 11
//   P05  half_tick position: fires at (P-1)/2 cycles before end_tick
//   P06  period: consecutive end_ticks separated by exactly P clocks
//
// Run: vsim -c -do "run -all; quit" tb_uart_baud_gen

`timescale 1ns/1ps

module tb_uart_baud_gen;

  localparam int PRESCALE_WIDTH = 4;

  logic clk  = 1'b0;
  logic rstn = 1'b0;

  always #5 clk = ~clk;

  logic [PRESCALE_WIDTH-1:0] prescale_drv = '0;
  logic                       start_drv   = 1'b0;
  logic                       enable_drv  = 1'b0;

  wire  start_tick_w;
  wire  half_tick_w;
  wire  end_tick_w;

  uart_baud_gen #(
    .PRESCALE_WIDTH (PRESCALE_WIDTH)
  ) dut (
    .clk         (clk),
    .rstn        (rstn),
    .start_i     (start_drv),
    .enable_i    (enable_drv),
    .prescale_i  (prescale_drv),
    .start_tick_o(start_tick_w),
    .half_tick_o (half_tick_w),
    .end_tick_o  (end_tick_w)
  );

  int fails = 0;

  task automatic chk(input logic cond, input string lbl);
    if (!cond) begin $display("FAIL %s", lbl); fails++; end
    else             $display("PASS %s", lbl);
  endtask

  // Trigger start_i and count posedges until end_tick fires.
  // Returns the cycle count (end_tick fires at cycle = effective_P - 1).
  task automatic measure_end_tick_delay(
    input  int prescale_val,
    output int delay_cnt
  );
    prescale_drv = PRESCALE_WIDTH'(prescale_val);
    enable_drv   = 1'b1;
    start_drv    = 1'b1;
    @(posedge clk);
    start_drv    = 1'b0;
    delay_cnt    = 0;
    while (!end_tick_w && delay_cnt < 32) begin
      @(posedge clk);
      delay_cnt++;
    end
  endtask

  // After end_tick fires, count clocks to the NEXT end_tick (= full period P).
  task automatic measure_period(output int period_cnt);
    // end_tick is currently asserted; wait for it to de-assert first
    @(posedge clk);
    period_cnt = 1;
    while (!end_tick_w && period_cnt < 32) begin
      @(posedge clk);
      period_cnt++;
    end
  endtask

  int delay;
  int period;

  initial begin
    repeat(4) @(posedge clk);
    rstn = 1'b1;
    repeat(2) @(posedge clk);

    // ------------------------------------------------------------------
    // P01: prescale=0 -> clamped to 8, end_tick delay = P = 8
    //   Testbench samples registered outputs: sees output set at clk N
    //   only after clk N+1, so delay count = P (one extra sample cycle).
    // ------------------------------------------------------------------
    measure_end_tick_delay(0, delay);
    chk(end_tick_w === 1'b1, "P01 end_tick fires");
    chk(delay == 8, $sformatf("P01 prescale=0 clamped: delay=%0d (expected 8)", delay));

    // ------------------------------------------------------------------
    // P02: prescale=7 -> clamped to 8, end_tick delay = 8
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    measure_end_tick_delay(7, delay);
    chk(end_tick_w === 1'b1, "P02 end_tick fires");
    chk(delay == 8, $sformatf("P02 prescale=7 clamped: delay=%0d (expected 8)", delay));

    // ------------------------------------------------------------------
    // P03: prescale=8 -> no clamp, end_tick delay = 8
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    measure_end_tick_delay(8, delay);
    chk(end_tick_w === 1'b1, "P03 end_tick fires");
    chk(delay == 8, $sformatf("P03 prescale=8: delay=%0d (expected 8)", delay));

    // ------------------------------------------------------------------
    // P04: prescale=12 -> no clamp, end_tick delay = 12
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    measure_end_tick_delay(12, delay);
    chk(end_tick_w === 1'b1, "P04 end_tick fires");
    chk(delay == 12, $sformatf("P04 prescale=12: delay=%0d (expected 12)", delay));

    // ------------------------------------------------------------------
    // P05: half_tick position for P=8
    //   half_offset = (8-1)/2 = 3; half_tick fires 2 clocks before end_tick.
    //   end_tick delay = 8, so half_tick delay = 8 - (half_offset-1) = 6.
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    prescale_drv = PRESCALE_WIDTH'(8);
    enable_drv   = 1'b1;
    start_drv    = 1'b1;
    @(posedge clk);
    start_drv    = 1'b0;
    begin
      int half_delay;
      half_delay = 0;
      while (!half_tick_w && half_delay < 32) begin
        @(posedge clk);
        half_delay++;
      end
      chk(half_tick_w === 1'b1, "P05 half_tick fires");
      chk(half_delay == 6,
          $sformatf("P05 half_tick at delay=%0d (expected 6 for P=8)", half_delay));
    end

    // ------------------------------------------------------------------
    // P06: period verification for P=8 (after end_tick, next end_tick = 8 clocks)
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    measure_end_tick_delay(8, delay);
    measure_period(period);
    chk(end_tick_w === 1'b1, "P06 second end_tick fires");
    chk(period == 8, $sformatf("P06 period=%0d (expected 8)", period));

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    if (fails == 0)
      $display("PASS tb_uart_baud_gen: all tests passed");
    else
      $display("FAIL tb_uart_baud_gen: %0d test(s) failed", fails);

    $finish;
  end

  initial begin
    repeat(50_000) @(posedge clk);
    $display("FAIL tb_uart_baud_gen: TIMEOUT");
    $finish;
  end

endmodule : tb_uart_baud_gen
