`timescale 1ns/1ps

// Smoke test for crc.sv
//
// T1: after reset crc_o == 32'hFFFF_FFFF
// T2: en_i=0 -- CRC holds value over multiple clocks
// T3: en_i=1, non-zero data -- CRC changes from reset value
//
// Run:
//   vlog -sv -suppress 2892 ../rtl/crc.sv unit/tb_crc_smoke.sv
//   vsim -c -do "run -all; quit" tb_crc_smoke

module tb_crc_smoke;

  int fail_count = 0;

  logic       clk   = 1'b0;
  logic       rst_ni;
  logic [7:0] data_i;
  logic       en_i;
  logic [31:0] crc_o;
  logic [31:0] crc_next_o;

  always #5 clk = ~clk;

  crc dut (
    .clk_i      (clk),
    .rst_ni     (rst_ni),
    .data_i     (data_i),
    .en_i       (en_i),
    .crc_o      (crc_o),
    .crc_next_o (crc_next_o)
  );

  task automatic chk32(input string tag, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08x exp=0x%08x", tag, got, exp);
      fail_count++;
    end else begin
      $display("PASS %s: 0x%08x", tag, got);
    end
  endtask

  initial begin
    // -- T1: reset value --
    $display("-- T1: reset value --");
    rst_ni = 1'b0;
    data_i = 8'h00;
    en_i   = 1'b0;
    @(posedge clk); #1;
    @(posedge clk); #1;
    rst_ni = 1'b1;
    @(posedge clk); #1;
    chk32("T1 crc_o after reset", crc_o, 32'hFFFF_FFFF);

    // -- T2: en_i=0 holds value --
    $display("-- T2: en_i=0 holds value --");
    en_i = 1'b0;
    data_i = 8'hAB;
    repeat (4) @(posedge clk); #1;
    chk32("T2 crc_o unchanged", crc_o, 32'hFFFF_FFFF);

    // -- T3: en_i=1 changes CRC --
    $display("-- T3: en_i=1 changes CRC --");
    en_i   = 1'b1;
    data_i = 8'hAB;
    @(posedge clk); #1;
    en_i = 1'b0;
    if (crc_o === 32'hFFFF_FFFF) begin
      $display("FAIL T3 crc_o did not change: still 0x%08x", crc_o);
      fail_count++;
    end else begin
      $display("PASS T3 crc_o changed to: 0x%08x", crc_o);
    end

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
