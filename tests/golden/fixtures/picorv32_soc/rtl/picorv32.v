// PicoRV32 stub - replace with actual picorv32.v from https://github.com/YosysHQ/picorv32
module picorv32 #(
  parameter ENABLE_IRQ = 1,
  parameter ENABLE_COUNTERS = 0,
  parameter ENABLE_COUNTERS64 = 0,
  parameter TWO_STAGE_SHIFT = 1,
  parameter BARREL_SHIFTER = 0,
  parameter TWO_CYCLE_COMPARE = 0,
  parameter TWO_CYCLE_ALU = 0,
  parameter LATCHED_MEM_RDATA = 0,
  parameter [31:0] PROGADDR_RESET = 32'h 0000_0000,
  parameter [31:0] PROGADDR_IRQ   = 32'h 0000_0010,
  parameter [31:0] STACKADDR      = 32'h ffff_ffff
) (
  input clk, resetn,
  output reg trap,
  output reg mem_valid,
  output reg mem_instr,
  input mem_ready,
  output reg [31:0] mem_addr,
  output reg [31:0] mem_wdata,
  output reg [3:0]  mem_wstrb,
  input [31:0] mem_rdata,
  input [31:0] irq,
  output reg [31:0] eoi,
  output reg trace_valid,
  output reg [35:0] trace_data,
  output reg look_valid,
  output reg [31:0] look_addr,
  output reg [31:0] look_rdata,
  output reg [31:0] look_wdata,
  output reg [3:0]  look_wstrb
);
  // Stub implementation
  initial begin
    trap = 0; mem_valid = 0; mem_instr = 0;
    mem_addr = 0; mem_wdata = 0; mem_wstrb = 0;
    eoi = 0; trace_valid = 0; trace_data = 0;
    look_valid = 0; look_addr = 0; look_rdata = 0;
    look_wdata = 0; look_wstrb = 0;
  end
endmodule
