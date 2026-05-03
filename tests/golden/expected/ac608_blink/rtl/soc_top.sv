// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  output wire [4:0] ONB_LEDS,
  input wire clk
);



  // Module instances
  blink_ac608 #(
    .CLK_FREQ(50000000)
  ) blink0 (
    .clk(clk),
    .leds_o(ONB_LEDS)
  );

endmodule : soc_top
`default_nettype wire
