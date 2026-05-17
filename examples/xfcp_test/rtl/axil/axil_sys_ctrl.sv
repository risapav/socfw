/**
 * @file  axil_sys_ctrl.sv
 * @brief AXI-Lite System Control peripheral (SYSC).
 * @param CLOCK_FREQ_HZ  Clock frequency in Hz; used for the 1-second uptime tick.
 * @details
 *   Register map (byte offset, all 32-bit):
 *     0x00  RO    COMPONENT_ID  -- constant 0x53595343 ("SYSC")
 *     0x04  RO    HW_STATUS     -- [0]=pll_locked, [3]=ic_timeout
 *     0x08  PULSE CONTROL       -- [0]=sw_reset, [2]=clear_faults
 *     0x0C  RO    UPTIME        -- seconds since reset (wraps at 2^32)
 *     0x10  RO    FAULT_ADDR    -- fault_addr_i pass-through
 *     0x14  RO    FAULT_STATUS  -- fault_status_i pass-through
 *
 *   CONTROL (PULSE type): writing bit[0] asserts sw_reset_o for one cycle;
 *   writing bit[2] asserts clear_faults_o for one cycle. Both outputs are
 *   registered one cycle after the AXI write completes (PULSE register
 *   update latency -- hw_wdata_o holds the new value one cycle after hw_we_o).
 */
`ifndef AXIL_SYS_CTRL_SV
`define AXIL_SYS_CTRL_SV

`default_nettype none

module axil_sys_ctrl #(
  parameter int CLOCK_FREQ_HZ = 50_000_000
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  axi4lite_if.slave   s_axil,
  input  logic        pll_locked_i,
  input  logic        ic_timeout_i,
  input  logic [31:0] fault_addr_i,
  input  logic [31:0] fault_status_i,
  output logic        sw_reset_o,
  output logic        clear_faults_o
);

  import axi_pkg::*;

  localparam int NUM_REGS  = 6;
  localparam int TICK_BITS = $clog2(CLOCK_FREQ_HZ > 1 ? CLOCK_FREQ_HZ : 2);
  localparam int TICK_MAX  = CLOCK_FREQ_HZ - 1;

  // reg2 = PULSE, all others = RO
  localparam [NUM_REGS*2-1:0] REG_TYPES =
    {2'(AXIL_RO), 2'(AXIL_RO), 2'(AXIL_RO), 2'(AXIL_PULSE), 2'(AXIL_RO), 2'(AXIL_RO)};

  // --------------------------------------------------------------------------
  // Uptime counter: increments once per CLOCK_FREQ_HZ cycles
  // --------------------------------------------------------------------------
  logic [TICK_BITS-1:0] tick_r;
  logic [31:0]          uptime_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tick_r   <= '0;
      uptime_r <= '0;
    end else if (tick_r == TICK_BITS'(TICK_MAX)) begin
      tick_r   <= '0;
      uptime_r <= uptime_r + 32'h1;
    end else begin
      tick_r <= tick_r + TICK_BITS'(1);
    end
  end

  // --------------------------------------------------------------------------
  // Register file wiring
  // --------------------------------------------------------------------------
  logic [NUM_REGS*32-1:0] hw_rdata_w;
  logic [NUM_REGS*32-1:0] hw_wdata_w;
  logic [NUM_REGS-1:0]    hw_we_w;

  assign hw_rdata_w[31:0]    = 32'h5359_5343; // "SYSC"
  assign hw_rdata_w[63:32]   = {28'h0, ic_timeout_i, 2'b0, pll_locked_i};
  assign hw_rdata_w[95:64]   = 32'h0;          // CONTROL: PULSE, hw_rdata unused
  assign hw_rdata_w[127:96]  = uptime_r;
  assign hw_rdata_w[159:128] = fault_addr_i;
  assign hw_rdata_w[191:160] = fault_status_i;

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
  // CONTROL decode: 1-cycle delay aligns ctrl_we_r with the PULSE FF update
  // (hw_wdata_w reflects the new write data one cycle after hw_we_w fires)
  // --------------------------------------------------------------------------
  logic ctrl_we_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ctrl_we_r <= 1'b0;
    else         ctrl_we_r <= hw_we_w[2];
  end

  assign sw_reset_o    = ctrl_we_r & hw_wdata_w[2*32 + 0]; // CONTROL[0]
  assign clear_faults_o = ctrl_we_r & hw_wdata_w[2*32 + 2]; // CONTROL[2]

endmodule

`endif // AXIL_SYS_CTRL_SV
