`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS
);

  blink_test blink_test (
    .clk(SYS_CLK),
    .gpio_o(ONB_LEDS)
  );

endmodule

`default_nettype wire
