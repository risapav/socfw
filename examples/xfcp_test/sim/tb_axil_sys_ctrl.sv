`timescale 1ns/1ps

// Testbench for axil_sys_ctrl -- validates all 6 registers and control outputs.
//
// DUT configuration (CLOCK_FREQ_HZ=10 for fast uptime testing):
//   reg0 0x00 RO    COMPONENT_ID -- constant 0x53595343 ("SYSC")
//   reg1 0x04 RO    HW_STATUS    -- [0]=pll_locked, [3]=ic_timeout
//   reg2 0x08 PULSE CONTROL      -- [0]=sw_reset, [2]=clear_faults
//   reg3 0x0C RO    UPTIME       -- seconds counter (ticks every 10 cycles here)
//   reg4 0x10 RO    FAULT_ADDR
//   reg5 0x14 RO    FAULT_STATUS
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) ../rtl/axil/axil_regfile.sv \
//        ../rtl/axil/axil_sys_ctrl.sv tb_axil_sys_ctrl.sv
//   vsim -c -do "run -all; quit" tb_axil_sys_ctrl

module tb_axil_sys_ctrl;
  import axi_pkg::*;

  localparam int CLK_FREQ = 10;

  logic        clk, rst_ni;
  logic        pll_locked;
  logic        ic_timeout;
  logic [31:0] fault_addr;
  logic [31:0] fault_status;
  logic        sw_reset;
  logic        clear_faults;

  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_if (
    .ACLK(clk), .ARESETn(rst_ni)
  );

  axil_sys_ctrl #(
    .CLOCK_FREQ_HZ (CLK_FREQ)
  ) dut (
    .clk_i          (clk),
    .rst_ni         (rst_ni),
    .s_axil         (axil_if.slave),
    .pll_locked_i   (pll_locked),
    .ic_timeout_i   (ic_timeout),
    .fault_addr_i   (fault_addr),
    .fault_status_i (fault_status),
    .sw_reset_o     (sw_reset),
    .clear_faults_o (clear_faults)
  );

  // 10 ns clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails          = 0;
  int sw_reset_cnt   = 0;
  int clr_faults_cnt = 0;

  // Capture one-cycle output pulses at posedge
  always @(posedge clk) begin
    if (sw_reset)    sw_reset_cnt++;
    if (clear_faults) clr_faults_cnt++;
  end

  // -----------------------------------------------------------------------
  // AXI-Lite master tasks (identical protocol to tb_axil_regfile)
  // -----------------------------------------------------------------------

  task automatic axi_write(
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0]  strb = 4'hF
  );
    @(negedge clk);
    axil_if.AWVALID = 1'b1; axil_if.AWADDR = addr; axil_if.AWPROT = '0;
    axil_if.WVALID  = 1'b1; axil_if.WDATA  = data; axil_if.WSTRB  = strb;
    axil_if.BREADY  = 1'b1;
    @(posedge clk);
    while (!(axil_if.AWREADY && axil_if.WREADY)) @(posedge clk);
    @(negedge clk);
    axil_if.AWVALID = 1'b0;
    axil_if.WVALID  = 1'b0;
    @(posedge clk);
    while (!axil_if.BVALID) @(posedge clk);
    @(negedge clk);
    axil_if.BREADY = 1'b0;
  endtask

  task automatic axi_read(
    input  logic [31:0] addr,
    output logic [31:0] data
  );
    @(negedge clk);
    axil_if.ARVALID = 1'b1; axil_if.ARADDR = addr; axil_if.ARPROT = '0;
    axil_if.RREADY  = 1'b1;
    @(posedge clk);
    while (!axil_if.ARREADY) @(posedge clk);
    @(negedge clk);
    axil_if.ARVALID = 1'b0;
    @(posedge clk);
    while (!axil_if.RVALID) @(posedge clk);
    data = axil_if.RDATA;
    @(negedge clk);
    axil_if.RREADY = 1'b0;
  endtask

  task automatic chk32(
    input logic [31:0] got,
    input logic [31:0] exp,
    input string       lbl
  );
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08X exp=0x%08X", lbl, got, exp);
      fails++;
    end else
      $display("PASS %s: 0x%08X", lbl, got);
  endtask

  task automatic chk_int(
    input int    got,
    input int    exp,
    input string lbl
  );
    if (got !== exp) begin
      $display("FAIL %s: got=%0d exp=%0d", lbl, got, exp);
      fails++;
    end else
      $display("PASS %s: %0d", lbl, got);
  endtask

  // -----------------------------------------------------------------------

  logic [31:0] rdata;
  logic [31:0] uptime_pre;

  initial begin
    axil_if.AWVALID = 0; axil_if.AWADDR = 0; axil_if.AWPROT = 0;
    axil_if.WVALID  = 0; axil_if.WDATA  = 0; axil_if.WSTRB  = 0;
    axil_if.BREADY  = 0;
    axil_if.ARVALID = 0; axil_if.ARADDR = 0; axil_if.ARPROT = 0;
    axil_if.RREADY  = 0;
    pll_locked   = 1'b0;
    ic_timeout   = 1'b0;
    fault_addr   = '0;
    fault_status = '0;

    rst_ni = 1'b0;
    repeat(4) @(posedge clk);
    rst_ni = 1'b1;
    repeat(2) @(posedge clk);

    // ---- T1: COMPONENT_ID = "SYSC" ----
    axi_read(32'h00, rdata);
    chk32(rdata, 32'h5359_5343, "T1 COMPONENT_ID");

    // ---- T2: HW_STATUS pll_locked ----
    pll_locked = 1'b1;
    axi_read(32'h04, rdata);
    chk32(rdata & 32'h1, 32'h1, "T2 HW_STATUS pll_locked[0]");

    // ---- T3: HW_STATUS ic_timeout ----
    ic_timeout = 1'b1;
    axi_read(32'h04, rdata);
    chk32(rdata & 32'h9, 32'h9, "T3 HW_STATUS ic_timeout[3]+pll_locked[0]");
    pll_locked = 1'b0;
    ic_timeout  = 1'b0;

    // ---- T4: CONTROL [0] -> sw_reset_o fires once ----
    sw_reset_cnt = 0;
    axi_write(32'h08, 32'h0000_0001);
    chk_int(sw_reset_cnt, 1, "T4 sw_reset pulse count");

    // ---- T5: CONTROL [2] -> clear_faults_o fires once ----
    clr_faults_cnt = 0;
    axi_write(32'h08, 32'h0000_0004);
    chk_int(clr_faults_cnt, 1, "T5 clear_faults pulse count");

    // ---- T6: CONTROL reads as 0 (PULSE type) ----
    axi_read(32'h08, rdata);
    chk32(rdata, 32'h0, "T6 CONTROL reads 0");

    // ---- T7: UPTIME increments ----
    // CLK_FREQ=10: one uptime tick per 10 clock cycles
    axi_read(32'h0C, uptime_pre);
    repeat(CLK_FREQ * 3) @(posedge clk); // guaranteed 3 ticks
    axi_read(32'h0C, rdata);
    if (rdata <= uptime_pre) begin
      $display("FAIL T7 UPTIME: no increment (before=0x%08X after=0x%08X)",
               uptime_pre, rdata);
      fails++;
    end else
      $display("PASS T7 UPTIME: 0x%08X -> 0x%08X", uptime_pre, rdata);

    // ---- T8: FAULT_ADDR pass-through ----
    fault_addr = 32'hDEAD_BEEF;
    axi_read(32'h10, rdata);
    chk32(rdata, 32'hDEAD_BEEF, "T8 FAULT_ADDR");

    // ---- T9: FAULT_STATUS pass-through ----
    fault_status = 32'hCAFE_BABE;
    axi_read(32'h14, rdata);
    chk32(rdata, 32'hCAFE_BABE, "T9 FAULT_STATUS");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
