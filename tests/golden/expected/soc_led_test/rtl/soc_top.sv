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
  gpio0_shell gpio0 (
    .RESET_N(reset_n),
    .SYS_CLK(SYS_CLK)
  );

endmodule : soc_top
`default_nettype wire
