/**
 * @file  axil_seven_seg_adapter.sv
 * @brief AXI-Lite 7-segment display adapter (SEG7).
 * @param CLOCK_FREQ_HZ    System clock frequency in Hz.
 * @param DIGIT_REFRESH_HZ Per-digit multiplex rate; total display = DIGIT_REFRESH_HZ * 3.
 * @param COMMON_ANODE     1 = common-anode (digit_sel active-low, segments active-low).
 * @details
 *   Register map (byte offset, all 32-bit):
 *     0x00  RO  COMPONENT_ID  -- constant 0x53454737 ("SEG7")
 *     0x04  RW  DIGITS        -- [4:0]=dig0, [9:5]=dig1, [14:10]=dig2
 *   Digit field: [4]=decimal_point, [3:0]=hex value (0-F).
 *   On reset all digits show 0 with no decimal points.
 *
 *   dig_o[2:0]  -- digit select (COMMON_ANODE: active-low, else active-high)
 *   seg_o[7:0]  -- segment outputs: [7]=DP, [6]=G, [5]=F, [4]=E, [3]=D, [2]=C, [1]=B, [0]=A
 */
`ifndef AXIL_SEVEN_SEG_ADAPTER_SV
`define AXIL_SEVEN_SEG_ADAPTER_SV

`default_nettype none

module axil_seven_seg_adapter #(
  parameter int CLOCK_FREQ_HZ    = 50_000_000,
  parameter int DIGIT_REFRESH_HZ = 250,
  parameter bit COMMON_ANODE     = 1'b1
) (
  input  logic      clk_i,
  input  logic      rst_ni,
  axi4lite_if.slave s_axil,
  output logic [2:0] dig_o,
  output logic [7:0] seg_o
);

  import axi_pkg::*;

  localparam int NUM_DIGITS = 3;
  localparam int NUM_REGS   = 2;

  // reg0 = RO (COMPONENT_ID), reg1 = RW (DIGITS)
  localparam [NUM_REGS*2-1:0] REG_TYPES = {2'(AXIL_RW), 2'(AXIL_RO)};

  // --------------------------------------------------------------------------
  // Register file
  // --------------------------------------------------------------------------
  logic [NUM_REGS*32-1:0] hw_rdata_w;
  logic [NUM_REGS*32-1:0] hw_wdata_w;
  logic [NUM_REGS-1:0]    hw_we_w;

  assign hw_rdata_w[31:0]  = 32'h5345_4737; // "SEG7"
  assign hw_rdata_w[63:32] = 32'h0;          // RW reg: hw_rdata_i ignored

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

  // --------------------------------------------------------------------------
  // Decode DIGITS register (reg1 = hw_wdata_w[63:32])
  // Field format: [4:0]=dig0={dp0,val0}, [9:5]=dig1={dp1,val1}, [14:10]=dig2={dp2,val2}
  // --------------------------------------------------------------------------
  logic [31:0] digits_reg_w;
  assign digits_reg_w = hw_wdata_w[63:32];

  logic [3:0] d0_val_w, d1_val_w, d2_val_w;
  logic       d0_dp_w,  d1_dp_w,  d2_dp_w;

  assign d0_val_w = digits_reg_w[3:0];
  assign d0_dp_w  = digits_reg_w[4];
  assign d1_val_w = digits_reg_w[8:5];
  assign d1_dp_w  = digits_reg_w[9];
  assign d2_val_w = digits_reg_w[13:10];
  assign d2_dp_w  = digits_reg_w[14];

  // packed: digit[i] at digits_packed_w[i*4 +: 4]
  logic [NUM_DIGITS*4-1:0] digits_packed_w;
  logic [NUM_DIGITS-1:0]   dots_w;

  assign digits_packed_w = {d2_val_w, d1_val_w, d0_val_w};
  assign dots_w          = {d2_dp_w,  d1_dp_w,  d0_dp_w};

  // --------------------------------------------------------------------------
  // 7-segment mux driver
  // --------------------------------------------------------------------------
  logic [1:0] seg_idx_w; // internal mux index, not exposed

  seven_seg_mux_packed #(
    .CLOCK_FREQ_HZ    (CLOCK_FREQ_HZ),
    .NUM_DIGITS       (NUM_DIGITS),
    .DIGIT_REFRESH_HZ (DIGIT_REFRESH_HZ),
    .COMMON_ANODE     (COMMON_ANODE)
  ) u_seg (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .digits_i        (digits_packed_w),
    .dots_i          (dots_w),
    .digit_sel_o     (dig_o),
    .segment_sel_o   (seg_o),
    .current_digit_o (seg_idx_w)
  );

endmodule

`endif // AXIL_SEVEN_SEG_ADAPTER_SV
