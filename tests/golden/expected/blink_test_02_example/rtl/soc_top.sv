`default_nettype none

module soc_top (
  output wire [5:0] ONB_LEDS,
  output wire [5:0] PMOD_J10_LED,
  output wire [5:0] PMOD_J11_LED,
  input wire RESET_N,
  input wire SYS_CLK
);

  wire clkpll_c0;
  wire clkpll_locked;
  wire reset_active;
  wire reset_n;

  assign reset_n = RESET_N;
  assign reset_active = ~RESET_N;

  blink_test blink_01 (
    .clk(clkpll_c0),
    .leds(ONB_LEDS),
    .rstn(reset_n)
  );

  blink_test blink_02 (
    .clk(clkpll_c0),
    .leds(PMOD_J10_LED),
    .rstn(reset_n)
  );

  blink_test blink_03 (
    .clk(SYS_CLK),
    .leds(PMOD_J11_LED),
    .rstn(reset_n)
  );

  clkpll clkpll (
    .areset(~reset_n),
    .c0(clkpll_c0),
    .inclk0(SYS_CLK),
    .locked(clkpll_locked)
  );

endmodule

`default_nettype wire
