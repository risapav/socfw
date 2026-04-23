// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  input  wire SYS_CLK,
  input  wire RESET_N,
  output wire [5:0] ONB_LEDS
);

  // Internal wires
  wire clk_100mhz; // generated clock  wire clk_100mhz_sh; // generated clock




  // Module instances
  clkpll u_clkpll (
    .clk(SYS_CLK),
    .areset(~RESET_N)
  );  blink_test u_blink_test (
    .clk(clk_100mhz),
    .rst_n(rst_n_clk_100mhz),
    .gpio_o(ONB_LEDS)
  );
endmodule : soc_top
`default_nettype wire
