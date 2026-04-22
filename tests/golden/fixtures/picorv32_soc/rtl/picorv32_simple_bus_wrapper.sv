`default_nettype none

module picorv32_simple_bus_wrapper #(
  parameter bit ENABLE_IRQ         = 1'b1,
  parameter bit ENABLE_COUNTERS    = 1'b0,
  parameter bit ENABLE_COUNTERS64  = 1'b0,
  parameter bit TWO_STAGE_SHIFT    = 1'b1,
  parameter bit BARREL_SHIFTER     = 1'b0,
  parameter bit TWO_CYCLE_COMPARE  = 1'b0,
  parameter bit TWO_CYCLE_ALU      = 1'b0,
  parameter bit LATCHED_MEM_RDATA  = 1'b0,
  parameter logic [31:0] PROGADDR_RESET = 32'h0000_0000,
  parameter logic [31:0] PROGADDR_IRQ   = 32'h0000_0010,
  parameter logic [31:0] STACKADDR      = 32'h0001_0000
)(
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] irq,
  bus_if.master      bus
);

  logic        mem_valid;
  logic        mem_instr;
  logic        mem_ready;
  logic [31:0] mem_addr;
  logic [31:0] mem_wdata;
  logic [3:0]  mem_wstrb;
  logic [31:0] mem_rdata;

  logic        req_active;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;

  picorv32 #(
    .ENABLE_IRQ        (ENABLE_IRQ),
    .ENABLE_COUNTERS   (ENABLE_COUNTERS),
    .ENABLE_COUNTERS64 (ENABLE_COUNTERS64),
    .TWO_STAGE_SHIFT   (TWO_STAGE_SHIFT),
    .BARREL_SHIFTER    (BARREL_SHIFTER),
    .TWO_CYCLE_COMPARE (TWO_CYCLE_COMPARE),
    .TWO_CYCLE_ALU     (TWO_CYCLE_ALU),
    .LATCHED_MEM_RDATA (LATCHED_MEM_RDATA),
    .PROGADDR_RESET    (PROGADDR_RESET),
    .PROGADDR_IRQ      (PROGADDR_IRQ),
    .STACKADDR         (STACKADDR)
  ) u_cpu (
    .clk         (SYS_CLK),
    .resetn      (RESET_N),
    .trap        (),
    .mem_valid   (mem_valid),
    .mem_instr   (mem_instr),
    .mem_ready   (mem_ready),
    .mem_addr    (mem_addr),
    .mem_wdata   (mem_wdata),
    .mem_wstrb   (mem_wstrb),
    .mem_rdata   (mem_rdata),
    .irq         (irq),
    .eoi         (),
    .trace_valid (),
    .trace_data  (),
    .look_valid  (),
    .look_addr   (),
    .look_rdata  (),
    .look_wdata  (),
    .look_wstrb  ()
  );

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      req_active <= 1'b0;
      req_addr   <= 32'h0;
      req_wdata  <= 32'h0;
      req_wstrb  <= 4'h0;
    end else begin
      if (!req_active && mem_valid) begin
        req_active <= 1'b1;
        req_addr   <= mem_addr;
        req_wdata  <= mem_wdata;
        req_wstrb  <= mem_wstrb;
      end else if (req_active && bus.ready) begin
        req_active <= 1'b0;
      end
    end
  end

  assign bus.addr  = req_active ? req_addr  : mem_addr;
  assign bus.wdata = req_active ? req_wdata : mem_wdata;
  assign bus.be    = ((req_active ? req_wstrb : mem_wstrb) == 4'b0000) ? 4'hF : (req_active ? req_wstrb : mem_wstrb);
  assign bus.we    = |(req_active ? req_wstrb : mem_wstrb);
  assign bus.valid = req_active | mem_valid;

  assign mem_ready = bus.ready;
  assign mem_rdata = bus.rdata;

endmodule

`default_nettype wire
