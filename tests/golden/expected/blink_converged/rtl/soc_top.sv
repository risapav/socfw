`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire SYS_CLK
);

  blink_test blink_test (
    .ONB_LEDS(ONB_LEDS),
    .SYS_CLK(SYS_CLK)
  );

endmodule

`default_nettype wire
