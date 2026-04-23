// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  input  wire SYS_CLK,
  input  wire RESET_N,
  output wire [5:0] ONB_LEDS
);






  // Module instances
  blink_test u_blink_test (
    .clk(SYS_CLK),
    .rst_n(RESET_N),
    .gpio_o(ONB_LEDS)
  );
endmodule : soc_top
`default_nettype wire
