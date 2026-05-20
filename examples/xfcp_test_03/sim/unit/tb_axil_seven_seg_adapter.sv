`timescale 1ns/1ps

// Testbench for axil_seven_seg_adapter -- validates register interface and
// physical display output.
//
// DUT: CLOCK_FREQ_HZ=10, DIGIT_REFRESH_HZ=2 -> TicksPerDigit=5, 3 digits,
//      COMMON_ANODE (dig_o active-low, seg_o active-low).
//
//   reg0 0x00 RO COMPONENT_ID -- 0x53454737 ("SEG7")
//   reg1 0x04 RW DIGITS       -- [4:0]=dig0, [9:5]=dig1, [14:10]=dig2
//   Digit field: [4]=dp, [3:0]=hex value 0-F
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) ../rtl/axil/axil_regfile.sv \
//        ../rtl/segment/seven_seg_mux.sv ../rtl/segment/seven_seg_mux_packed.sv \
//        ../rtl/axil/axil_seven_seg_adapter.sv tb_axil_seven_seg_adapter.sv
//   vsim -c -do "run -all; quit" tb_axil_seven_seg_adapter

module tb_axil_seven_seg_adapter;
  import axi_pkg::*;

  localparam int CLK_FREQ = 10;
  localparam int REFRESH  = 2;

  // Expected segment pattern: value=5, dot=0, COMMON_ANODE
  // seg_raw(5) = 7'b0010010, seg_full = {~0, 7'b0010010} = 8'h92
  localparam logic [7:0] SEG_VAL5 = 8'h92;

  logic        clk, rst_ni;
  logic [2:0]  dig_o;
  logic [7:0]  seg_o;

  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_if (
    .ACLK(clk), .ARESETn(rst_ni)
  );

  axil_seven_seg_adapter #(
    .CLOCK_FREQ_HZ    (CLK_FREQ),
    .DIGIT_REFRESH_HZ (REFRESH),
    .COMMON_ANODE     (1'b1)
  ) dut (
    .clk_i  (clk),
    .rst_ni (rst_ni),
    .s_axil (axil_if.slave),
    .dig_o  (dig_o),
    .seg_o  (seg_o)
  );

  // 10 ns clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int          fails    = 0;
  logic [2:0]  digs_seen;
  logic [7:0]  seg_at_dig0;

  // Capture which digits appear and the segment pattern when digit 0 is active.
  // With COMMON_ANODE: dig_o[i] == 0 means digit i is selected.
  always @(posedge clk) begin
    if (!dig_o[0]) begin
      digs_seen[0] = 1;
      seg_at_dig0  = seg_o;
    end
    if (!dig_o[1]) digs_seen[1] = 1;
    if (!dig_o[2]) digs_seen[2] = 1;
  end

  // -----------------------------------------------------------------------
  // AXI-Lite master tasks
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

  // -----------------------------------------------------------------------

  logic [31:0] rdata;

  initial begin
    axil_if.AWVALID = 0; axil_if.AWADDR = 0; axil_if.AWPROT = 0;
    axil_if.WVALID  = 0; axil_if.WDATA  = 0; axil_if.WSTRB  = 0;
    axil_if.BREADY  = 0;
    axil_if.ARVALID = 0; axil_if.ARADDR = 0; axil_if.ARPROT = 0;
    axil_if.RREADY  = 0;
    digs_seen   = 3'b0;
    seg_at_dig0 = 8'hFF;

    rst_ni = 1'b0;
    repeat(4) @(posedge clk);
    rst_ni = 1'b1;
    repeat(2) @(posedge clk);

    // ---- T1: COMPONENT_ID = "SEG7" ----
    axi_read(32'h00, rdata);
    chk32(rdata, 32'h5345_4737, "T1 COMPONENT_ID");

    // ---- T2: DIGITS write 0, read back 0 ----
    axi_write(32'h04, 32'h0);
    axi_read(32'h04, rdata);
    chk32(rdata, 32'h0, "T2 DIGITS all-zero");

    // ---- T3: DIGITS write 0x7FFF (all dp + all max value), read back ----
    axi_write(32'h04, 32'h0000_7FFF);
    axi_read(32'h04, rdata);
    chk32(rdata & 32'h7FFF, 32'h7FFF, "T3 DIGITS all-ones[14:0]");

    // ---- T4: DIGITS = dig0=5, dig1=A, dig2=F (no dots) ----
    // DIGITS = {dig2=5'h0F, dig1=5'h0A, dig0=5'h05}
    // bits[4:0]=0x05, bits[9:5]=0x0A<<5=0x140, bits[14:10]=0x0F<<10=0x3C00
    // total: 0x05 + 0x140 + 0x3C00 = 0x3D45
    axi_write(32'h04, 32'h0000_3D45);
    axi_read(32'h04, rdata);
    chk32(rdata & 32'h7FFF, 32'h3D45, "T4 DIGITS dig0=5/dig1=A/dig2=F");

    // ---- T5: display cycling -- all 3 digits must appear, seg for dig0 correct ----
    // Reset captures now (at negedge, safely between posedges)
    digs_seen   = 3'b0;
    seg_at_dig0 = 8'hFF;
    // Wait 2+ complete mux sequences: 2 * 3 * TicksPerDigit + slack
    // TicksPerDigit = CLK_FREQ/REFRESH = 5 -> 2*3*5+10 = 40 cycles
    repeat(40) @(posedge clk);

    if (digs_seen !== 3'b111) begin
      $display("FAIL T5 display cycling: digs_seen=3'b%03b (exp=3'b111)", digs_seen);
      fails++;
    end else
      $display("PASS T5 display cycling: all 3 digits seen");

    // seg for digit 0 (value 5, no dot, COMMON_ANODE): 8'h92
    chk32({24'h0, seg_at_dig0}, {24'h0, SEG_VAL5}, "T5 seg[0] for digit value 5");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
