`default_nettype none

module gpio_core (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] reg_value,
  output wire        irq_pending,
  output wire        irq_changed,
  output wire [5:0]  gpio_o
);

  logic [31:0] prev_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N)
      prev_value <= 32'h0;
    else
      prev_value <= reg_value;
  end

  assign gpio_o = reg_value[5:0];
  assign irq_changed = (reg_value != prev_value);
  assign irq_pending = irq_changed;

endmodule

`default_nettype wire
