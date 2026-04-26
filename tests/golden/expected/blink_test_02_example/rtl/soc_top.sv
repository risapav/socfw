`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  output wire [7:0] PMOD_J10_LED8,
  output wire [5:0] PMOD_J11_LED,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire clkpll_c0;
  wire clkpll_locked;
  wire reset_active;
  wire reset_n;
  wire [5:0] w_blink_02_leds_o;

  assign reset_n = RESET_N;
  assign reset_active = ~RESET_N;
  assign PMOD_J10_LED8 = { 2'b0, w_blink_02_leds_o };

  blink_test blink_01 (
    .clk_i(clkpll_c0),
    .leds_o(ONB_LEDS),
    .rst_ni(reset_n)
  );

  blink_test blink_02 (
    .clk_i(clkpll_c0),
    .leds_o(w_blink_02_leds_o),
    .rst_ni(reset_n)
  );

  blink_test blink_03 (
    .clk_i(SYS_CLK),
    .leds_o(PMOD_J11_LED),
    .rst_ni(reset_n)
  );

  clkpll clkpll (
    .areset(~reset_n),
    .c0(clkpll_c0),
    .inclk0(SYS_CLK),
    .locked(clkpll_locked)
  );

endmodule

`default_nettype wire
