`default_nettype none

module irq_combiner #(
  parameter int WIDTH = 1
)(
  input  wire [WIDTH-1:0] irq_i,
  output wire [WIDTH-1:0] irq_o
);

  assign irq_o = irq_i;

endmodule : irq_combiner
`default_nettype wire
