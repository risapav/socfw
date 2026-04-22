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

  logic [5:0] leds_prev;

  initial begin
    leds_prev = 6'h00;

    $display("[TB] starting simulation");
    repeat (5000) @(posedge SYS_CLK);
    leds_prev = ONB_LEDS;

    repeat (5000) @(posedge SYS_CLK);

    $display("[TB] LED state old=%b new=%b", leds_prev, ONB_LEDS);

    if (^ONB_LEDS === 1'bx) begin
      $fatal(1, "[TB] LED state contains X");
    end

    if (ONB_LEDS == leds_prev) begin
      $fatal(1, "[TB] LED state did not change");
    end

    $finish;
  end

endmodule

`default_nettype wire
