// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  input  wire SYS_CLK,
  input  wire RESET_N,
  output wire [5:0] ONB_LEDS
);






  // Module instances
  sys_pll u_pll0 (
    .inclk0(SYS_CLK),
    .areset(~RESET_N)
  );  blink_test #(
    .CLK_FREQ(100000000)
  ) u_blink_test (
    .clk(SYS_CLK),
    .rst_n(RESET_N),
    .gpio_o(ONB_LEDS)
  );
endmodule : soc_top
`default_nettype wire
