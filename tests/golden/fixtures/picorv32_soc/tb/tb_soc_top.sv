`timescale 1ns/1ps
`default_nettype none

module tb_soc_top;

  logic SYS_CLK;
  logic RESET_N;
  wire [5:0] ONB_LEDS;

  soc_top dut (
    .SYS_CLK (SYS_CLK),
    .RESET_N (RESET_N),
    .ONB_LEDS(ONB_LEDS)
  );

  initial begin
    SYS_CLK = 1'b0;
    forever #10 SYS_CLK = ~SYS_CLK; // 50 MHz
  end

  initial begin
    RESET_N = 1'b0;
    repeat (10) @(posedge SYS_CLK);
    RESET_N = 1'b1;
  end

  logic [5:0] leds_a, leds_b, leds_c;

  initial begin
    $display("[TB] starting simulation");

    repeat (3000) @(posedge SYS_CLK);
    leds_a = ONB_LEDS;

    repeat (3000) @(posedge SYS_CLK);
    leds_b = ONB_LEDS;

    repeat (3000) @(posedge SYS_CLK);
    leds_c = ONB_LEDS;

    $display("[TB] LED states: %b %b %b", leds_a, leds_b, leds_c);

    if (^leds_c === 1'bx)
      $fatal(1, "[TB] LED state contains X");

    if (leds_a == leds_b && leds_b == leds_c)
      $fatal(1, "[TB] LED state did not evolve");

    $finish;
  end

endmodule

`default_nettype wire
