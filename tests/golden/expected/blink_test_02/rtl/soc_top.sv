// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire RESET_N,
  input wire SYS_CLK
);

  // Internal wires
  wire clkpll_c0;
  wire clkpll_c1;
  wire clkpll_locked;
  wire reset_n;

  // Top-level / adapter assigns
  assign reset_n = RESET_N;

  // Module instances
  blink_test blink_test (
    .clk(clkpll_c0),
    .gpio_o(ONB_LEDS),
    .rst_n(reset_n)
  );
  clkpll clkpll (
    .areset(~reset_n),
    .inclk0(1'b0)
  );

endmodule : soc_top
`default_nettype wire
