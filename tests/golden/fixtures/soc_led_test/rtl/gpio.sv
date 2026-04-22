`default_nettype none

module gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus,
  output logic [5:0] gpio_o,
  output logic irq_changed
);

  logic [31:0] reg_value;
  logic [31:0] prev_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      reg_value  <= 32'h0;
      prev_value <= 32'h0;
    end else begin
      prev_value <= reg_value;
      if (bus.valid && bus.we && bus.addr[11:2] == 10'h0) begin
        reg_value <= bus.wdata;
      end
    end
  end

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = (bus.addr[11:2] == 10'h0) ? reg_value : 32'h0;
  end

  assign gpio_o      = reg_value[5:0];
  assign irq_changed = (reg_value != prev_value);

endmodule
`default_nettype wire
