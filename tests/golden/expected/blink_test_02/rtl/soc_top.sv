`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire reset_active;
  wire reset_n;

  blink_test blink_test (
    .gpio_o(ONB_LEDS)
  );

  clkpll clkpll (
    .areset(reset_n),
    .clk(SYS_CLK)
  );

endmodule

`default_nettype wire
