`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire clkpll_c0;
  wire clkpll_c1;
  wire clkpll_locked;
  wire reset_active;
  wire reset_n;

  assign reset_n = RESET_N;
  assign reset_active = ~RESET_N;

  blink_test blink_test (
    .clk(clkpll_c0),
    .gpio_o(ONB_LEDS),
    .rst_n(reset_n)
  );

  clkpll clkpll (
    .areset(~reset_n),
    .inclk0(1'b0)
  );

endmodule

`default_nettype wire
