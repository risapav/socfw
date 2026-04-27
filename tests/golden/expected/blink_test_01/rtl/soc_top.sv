`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire reset_n;

  assign reset_n = RESET_N;

  blink_test blink_test (
    .clk(SYS_CLK),
    .gpio_o(ONB_LEDS),
    .rst_n(reset_n)
  );

endmodule

`default_nettype wire
