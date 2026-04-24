`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS
);

  blink_test blink_test (
    .clk(SYS_CLK),
    .gpio_o(ONB_LEDS)
  );

  sys_pll pll0 (
    .inclk0(SYS_CLK)
  );

endmodule

`default_nettype wire
