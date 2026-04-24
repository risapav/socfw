`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS
);

  blink_test blink_test (
    .clk(clk_100mhz),
    .gpio_o(ONB_LEDS)
  );

  clkpll clkpll (
    .clk(SYS_CLK)
  );

endmodule

`default_nettype wire
