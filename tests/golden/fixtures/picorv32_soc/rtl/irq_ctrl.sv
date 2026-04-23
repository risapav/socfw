`default_nettype none

module irq_ctrl (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  bus_if.slave       bus,
  input  wire [31:0] src_irq_i,
  output wire [31:0] cpu_irq_o
);

  logic [31:0] reg_enable;
  logic [31:0] reg_ack;
  logic        reg_ack_we;

  logic [31:0] hw_pending;
  logic [31:0] rdata;
  logic        ready;

  irq0_regs u_regs (
    .SYS_CLK        (SYS_CLK),
    .RESET_N        (RESET_N),
    .addr_i         (bus.addr[3:2]),
    .wdata_i        (bus.wdata),
    .we_i           (bus.we),
    .valid_i        (bus.valid),
    .rdata_o        (rdata),
    .ready_o        (ready),
    .hw_pending     (hw_pending),
    .reg_enable     (reg_enable),
    .reg_ack        (reg_ack),
    .reg_ack_we     (reg_ack_we)
  );

  logic [31:0] pending_q;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      pending_q <= 32'h0;
    end else begin
      pending_q <= pending_q | src_irq_i;
      if (reg_ack_we)
        pending_q <= (pending_q | src_irq_i) & ~reg_ack;
    end
  end

  assign hw_pending  = pending_q;
  assign cpu_irq_o   = pending_q & reg_enable;

  assign bus.rdata = rdata;
  assign bus.ready = ready;

endmodule

`default_nettype wire
