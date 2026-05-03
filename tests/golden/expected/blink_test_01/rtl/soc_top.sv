// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  // Internal wires
  wire reset_n;

  // Top-level / adapter assigns
  assign reset_n = RESET_N;

  // Module instances
  blink_test blink_test (
    .clk(SYS_CLK),
    .gpio_o(ONB_LEDS),
    .rst_n(reset_n)
  );

endmodule : soc_top
`default_nettype wire
