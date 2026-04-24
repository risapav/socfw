`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire reset_active;
  wire reset_n;

  blink_test blink_test (
    .clk(SYS_CLK),
    .rst_n(reset_n),
    .gpio_o(ONB_LEDS)
  );

  sys_pll pll0 (
    .inclk0(SYS_CLK),
    .areset(reset_n)
  );

endmodule

`default_nettype wire
