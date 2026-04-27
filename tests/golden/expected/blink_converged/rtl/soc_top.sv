`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire SYS_CLK
);

  blink_test #(
    .CLK_FREQ(50000000)
  ) blink_test (
    .ONB_LEDS(ONB_LEDS),
    .SYS_CLK(SYS_CLK)
  );

endmodule

`default_nettype wire
