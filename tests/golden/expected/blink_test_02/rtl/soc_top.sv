`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire reset_active;
  wire reset_n;

  blink_test blink_test (
    .clk(clk_100mhz),
    .gpio_o(ONB_LEDS),
    .rst_n(reset_n)
  );

  clkpll clkpll (
    .areset(reset_n),
    .inclk0(1'b0)
  );

endmodule

`default_nettype wire
