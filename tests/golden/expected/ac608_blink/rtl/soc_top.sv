`default_nettype none

module soc_top (
  output wire [4:0] ONB_LEDS,
  input wire RESET_N,
  input wire clk
);

  wire reset_active;
  wire reset_n;

  assign reset_n = RESET_N;
  assign reset_active = ~RESET_N;

  blink_ac608 blink0 (
    .clk(clk),
    .leds_o(ONB_LEDS)
  );

endmodule

`default_nettype wire
