/**
 * @file  axil_regs.sv
 * @brief AXI-Lite generic output register (OUT_).
 * @details
 *   Register map (byte offset, all 32-bit):
 *     0x00  RO  COMPONENT_ID  -- constant 0x4F55545F ("OUT_")
 *     0x04  RW  DATA_REG      -- output data; data_o driven from this register
 *
 *   data_o[31:0] reflects DATA_REG at all times (RW register, reset=0).
 *   Byte-lane write strobes are supported; partial writes update only the
 *   selected byte lanes (e.g., use WSTRB=0x01 to write only the LED byte).
 */
`ifndef AXIL_REGS_SV
`define AXIL_REGS_SV

`default_nettype none

module axil_regs (
  input  logic        clk_i,
  input  logic        rst_ni,
  axi4lite_if.slave   s_axil,
  output logic [31:0] data_o
);

  import axi_pkg::*;

  localparam int NUM_REGS = 2;

  // reg0 = RO (COMPONENT_ID), reg1 = RW (DATA_REG)
  localparam [NUM_REGS*2-1:0] REG_TYPES = {2'(AXIL_RW), 2'(AXIL_RO)};

  logic [NUM_REGS*32-1:0] hw_rdata_w;
  logic [NUM_REGS*32-1:0] hw_wdata_w;
  logic [NUM_REGS-1:0]    hw_we_w;

  assign hw_rdata_w[31:0]  = 32'h4F55_545F; // "OUT_"
  assign hw_rdata_w[63:32] = 32'h0;          // RW: hw_rdata_i ignored

  axil_regfile #(
    .NUM_REGS  (NUM_REGS),
    .REG_TYPES (REG_TYPES),
    .RESET_VALS('0)
  ) u_regfile (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .s_axil     (s_axil),
    .hw_rdata_i (hw_rdata_w),
    .hw_wdata_o (hw_wdata_w),
    .hw_we_o    (hw_we_w)
  );

  assign data_o = hw_wdata_w[63:32]; // DATA_REG

endmodule

`endif // AXIL_REGS_SV
