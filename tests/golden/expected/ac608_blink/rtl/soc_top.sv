`default_nettype none

module soc_top (
  output wire [4:0] ONB_LEDS,
  input wire clk
);

  blink_ac608 blink0 (
    .clk(clk),
    .leds_o(ONB_LEDS)
  );

endmodule

`default_nettype wire
