`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire pll0_c0;
  wire reset_n;

  assign reset_n = RESET_N;

  blink_test #(
    .CLK_FREQ(100000000)
  ) blink_test (
    .clk(SYS_CLK),
    .gpio_o(ONB_LEDS),
    .rst_n(reset_n)
  );

  sys_pll pll0 (
    .areset(~reset_n),
    .inclk0(SYS_CLK)
  );

endmodule

`default_nettype wire
