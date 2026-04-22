`default_nettype none

module gpio_core (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] reg_value,
  output logic [5:0] gpio_o,
  output logic       irq_changed
);

  logic [31:0] prev_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      prev_value <= 32'h0;
    end else begin
      prev_value <= reg_value;
    end
  end

  assign gpio_o      = reg_value[5:0];
  assign irq_changed = (reg_value != prev_value);

endmodule

`default_nettype wire
