// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  input wire SYS_CLK
);



  // Module instances
  blink_test #(
    .CLK_FREQ(50000000)
  ) blink_test (
    .ONB_LEDS(ONB_LEDS),
    .SYS_CLK(SYS_CLK)
  );

endmodule : soc_top
`default_nettype wire
