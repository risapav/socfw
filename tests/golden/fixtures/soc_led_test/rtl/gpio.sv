`default_nettype none

module gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus,
  output wire [5:0] gpio_o,
  output wire irq_changed
);

  logic [31:0] reg_value;
  logic [31:0] rdata;
  logic        ready;

  gpio0_regs u_regs (
    .SYS_CLK  (SYS_CLK),
    .RESET_N  (RESET_N),
    .addr_i   (bus.addr[11:2]),
    .wdata_i  (bus.wdata),
    .we_i     (bus.we),
    .valid_i  (bus.valid),
    .rdata_o  (rdata),
    .ready_o  (ready),
    .reg_value(reg_value)
  );

  gpio_core u_core (
    .SYS_CLK    (SYS_CLK),
    .RESET_N    (RESET_N),
    .reg_value  (reg_value),
    .gpio_o     (gpio_o),
    .irq_changed(irq_changed)
  );

  assign bus.rdata = rdata;
  assign bus.ready = ready;

endmodule

`default_nettype wire
