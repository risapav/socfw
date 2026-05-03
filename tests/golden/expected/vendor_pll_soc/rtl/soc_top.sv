// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  // Internal wires
  wire pll0_c0;
  wire reset_n;

  // Top-level / adapter assigns
  assign reset_n = RESET_N;

  // Module instances
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

endmodule : soc_top
`default_nettype wire
