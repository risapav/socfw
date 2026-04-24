`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS
);

  blink_test blink_test (
    .SYS_CLK(SYS_CLK),
    .ONB_LEDS(ONB_LEDS)
  );

endmodule

`default_nettype wire
