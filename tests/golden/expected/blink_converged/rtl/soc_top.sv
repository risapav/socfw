// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  input  wire SYS_CLK,
  input  wire RESET_N,
  output wire [5:0] ONB_LEDS
);






  // Module instances
  blink_test #(
    .CLK_FREQ(50000000)
  ) u_blink_test (
    .SYS_CLK(SYS_CLK),
    .ONB_LEDS(ONB_LEDS)
  );
endmodule : soc_top
`default_nettype wire
