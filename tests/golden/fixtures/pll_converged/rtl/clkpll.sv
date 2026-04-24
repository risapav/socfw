`default_nettype none

module clkpll (
  input  wire inclk0,
  input  wire areset,
  output wire c0,
  output wire locked
);

  assign c0 = inclk0;
  assign locked = ~areset;

endmodule

`default_nettype wire
