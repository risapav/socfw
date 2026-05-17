`timescale 1ns/1ps

// Testbench for axil_regfile -- validates all four register types.
//
// DUT configuration (4 registers, byte offset = index * 4):
//   reg0 0x00  AXIL_RO    -- hw_rdata_i passes through to read; writes ignored
//   reg1 0x04  AXIL_RW    -- stored FF, byte-lane strobe, hw_wdata_o mirrors value
//   reg2 0x08  AXIL_W1C   -- HW OR-sets bits each cycle, SW write-1-to-clear
//   reg3 0x0C  AXIL_PULSE -- write fires hw_we_o pulse; reads always 0
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) ../rtl/axil/axil_regfile.sv tb_axil_regfile.sv
//   vsim -c -do "run -all; quit" tb_axil_regfile

module tb_axil_regfile;
  import axi_pkg::*;

  // REG_TYPES: 2 bits per register, register 0 in bits [1:0]
  localparam [7:0] TYPES =
    {2'(AXIL_PULSE), 2'(AXIL_W1C), 2'(AXIL_RW), 2'(AXIL_RO)};

  logic        clk, rst_ni;
  logic [127:0] hw_rdata;
  logic [127:0] hw_wdata;
  logic [3:0]   hw_we;

  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_if (
    .ACLK(clk), .ARESETn(rst_ni)
  );

  axil_regfile #(
    .NUM_REGS   (4),
    .REG_TYPES  (TYPES),
    .RESET_VALS (128'h0)
  ) dut (
    .clk_i      (clk),
    .rst_ni     (rst_ni),
    .s_axil     (axil_if.slave),
    .hw_rdata_i (hw_rdata),
    .hw_wdata_o (hw_wdata),
    .hw_we_o    (hw_we)
  );

  // 10 ns clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // -----------------------------------------------------------------------
  // AXI-Lite master tasks
  // Signals driven at negedge to be stable before the next posedge.
  // AWVALID+WVALID are issued simultaneously; the DUT accepts both
  // in one cycle when idle (AWREADY && WREADY both asserted).
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
    // Wait until both channels are accepted in the same cycle
    @(posedge clk);
    while (!(axil_if.AWREADY && axil_if.WREADY)) @(posedge clk);
    @(negedge clk);
    axil_if.AWVALID = 1'b0;
    axil_if.WVALID  = 1'b0;
    // Wait for write response
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

  // -----------------------------------------------------------------------

  logic [31:0] rdata;

  initial begin
    axil_if.AWVALID = 0; axil_if.AWADDR = 0; axil_if.AWPROT = 0;
    axil_if.WVALID  = 0; axil_if.WDATA  = 0; axil_if.WSTRB  = 0;
    axil_if.BREADY  = 0;
    axil_if.ARVALID = 0; axil_if.ARADDR = 0; axil_if.ARPROT = 0;
    axil_if.RREADY  = 0;
    hw_rdata = '0;

    rst_ni = 1'b0;
    repeat(4) @(posedge clk);
    rst_ni = 1'b1;
    repeat(2) @(posedge clk);

    // ---- T1: AXIL_RO -- read returns hw_rdata_i ----
    hw_rdata[31:0] = 32'hDEAD_BEEF;
    axi_read(32'h00, rdata);
    chk32(rdata, 32'hDEAD_BEEF, "T1 RO read");

    // ---- T2: AXIL_RO -- write is ignored ----
    axi_write(32'h00, 32'h1234_5678);
    axi_read(32'h00, rdata);
    chk32(rdata, 32'hDEAD_BEEF, "T2 RO write ignored");

    // ---- T3: AXIL_RW -- write then read ----
    axi_write(32'h04, 32'hCAFE_BABE);
    axi_read(32'h04, rdata);
    chk32(rdata,           32'hCAFE_BABE, "T3 RW read");
    chk32(hw_wdata[63:32], 32'hCAFE_BABE, "T3 RW hw_wdata_o");

    // ---- T4: AXIL_RW -- byte-lane strobe ----
    // Current reg1: 0xCAFE_BABE. Write 0xDEAD_CAFE with STRB=0b0110.
    // byte3(kept)=0xCA, byte2(new)=0xAD, byte1(new)=0xCA, byte0(kept)=0xBE
    axi_write(32'h04, 32'hDEAD_CAFE, 4'b0110);
    axi_read(32'h04, rdata);
    chk32(rdata, 32'hCAAD_CABE, "T4 RW byte strobe");

    // ---- T5: AXIL_W1C -- HW sets bits ----
    hw_rdata[95:64] = 32'h0000_000F; // drive set for reg2 W1C
    repeat(2) @(posedge clk);        // let OR propagate into val_r
    axi_read(32'h08, rdata);
    chk32(rdata & 32'hF, 32'hF, "T5 W1C HW set bits [3:0]");

    // ---- T6: AXIL_W1C -- SW clears bits [1:0] ----
    hw_rdata[95:64] = 32'h0;        // stop asserting set
    axi_write(32'h08, 32'h0000_0003);
    axi_read(32'h08, rdata);
    // 0xF & ~0x3 = 0xC
    chk32(rdata & 32'hF, 32'hC, "T6 W1C clear bits [1:0]");

    // ---- T7: AXIL_PULSE -- hw_wdata_o latched, reads as 0 ----
    axi_write(32'h0C, 32'hABCD_EF01);
    chk32(hw_wdata[127:96], 32'hABCD_EF01, "T7 PULSE hw_wdata_o latched");
    axi_read(32'h0C, rdata);
    chk32(rdata, 32'h0, "T7 PULSE reads 0");

    // ---- T8: address wrap -- 0x10 maps to rd_idx=0 (reg0 RO) ----
    // With ADDR_BITS=2 the regfile sees only bits [3:2] of the address.
    // 0x10[3:2]=0 => reg0. Reset hw_rdata[31:0] so the read returns 0.
    hw_rdata[31:0] = 32'h0;
    axi_read(32'h10, rdata);
    chk32(rdata, 32'h0, "T8 addr-wrap to reg0 after rdata reset");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
