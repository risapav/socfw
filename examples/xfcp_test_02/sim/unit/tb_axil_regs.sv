`timescale 1ns/1ps

// Testbench for axil_regs (OUT_ output register).
//
//   reg0 0x00 RO COMPONENT_ID -- 0x4F55545F ("OUT_")
//   reg1 0x04 RW DATA_REG     -- data_o[31:0], reset=0
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) ../rtl/axil/axil_regfile.sv \
//        ../rtl/axil/axil_regs.sv tb_axil_regs.sv
//   vsim -c -do "run -all; quit" tb_axil_regs

module tb_axil_regs;
  import axi_pkg::*;

  logic        clk, rst_ni;
  logic [31:0] data_out;

  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_if (
    .ACLK(clk), .ARESETn(rst_ni)
  );

  axil_regs dut (
    .clk_i  (clk),
    .rst_ni (rst_ni),
    .s_axil (axil_if.slave),
    .data_o (data_out)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

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

  logic [31:0] rdata;

  initial begin
    axil_if.AWVALID = 0; axil_if.AWADDR = 0; axil_if.AWPROT = 0;
    axil_if.WVALID  = 0; axil_if.WDATA  = 0; axil_if.WSTRB  = 0;
    axil_if.BREADY  = 0;
    axil_if.ARVALID = 0; axil_if.ARADDR = 0; axil_if.ARPROT = 0;
    axil_if.RREADY  = 0;

    rst_ni = 1'b0;
    repeat(4) @(posedge clk);
    rst_ni = 1'b1;
    repeat(2) @(posedge clk);

    // ---- T1: COMPONENT_ID = "OUT_" ----
    axi_read(32'h00, rdata);
    chk32(rdata, 32'h4F55_545F, "T1 COMPONENT_ID");

    // ---- T2: DATA_REG reset = 0 ----
    axi_read(32'h04, rdata);
    chk32(rdata, 32'h0, "T2 DATA_REG reset");
    chk32(data_out, 32'h0, "T2 data_o reset");

    // ---- T3: Write 0x3F (6 LSBs = all LEDs on) ----
    axi_write(32'h04, 32'h0000_003F);
    axi_read(32'h04, rdata);
    chk32(rdata, 32'h3F, "T3 DATA_REG all-LEDs");
    chk32(data_out, 32'h3F, "T3 data_o all-LEDs");

    // ---- T4: Write alternating pattern ----
    axi_write(32'h04, 32'hAA55_1234);
    axi_read(32'h04, rdata);
    chk32(rdata, 32'hAA55_1234, "T4 DATA_REG full 32-bit write");
    chk32(data_out, 32'hAA55_1234, "T4 data_o full 32-bit");

    // ---- T5: Byte-lane strobe -- update only byte0 ----
    // current: 0xAA55_1234, write 0xXX_XX_XX_FF with STRB=0b0001
    // byte3(kept)=0xAA, byte2(kept)=0x55, byte1(kept)=0x12, byte0(new)=0xFF
    axi_write(32'h04, 32'h0000_00FF, 4'b0001);
    axi_read(32'h04, rdata);
    chk32(rdata, 32'hAA55_12FF, "T5 byte-strobe byte0");
    chk32(data_out, 32'hAA55_12FF, "T5 data_o byte-strobe");

    // ---- T6: Clear DATA_REG ----
    axi_write(32'h04, 32'h0);
    axi_read(32'h04, rdata);
    chk32(rdata, 32'h0, "T6 DATA_REG cleared");
    chk32(data_out, 32'h0, "T6 data_o cleared");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
