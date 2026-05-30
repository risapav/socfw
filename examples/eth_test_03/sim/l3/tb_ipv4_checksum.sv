`timescale 1ns/1ps
/**
 * @file tb_ipv4_checksum.sv
 * @brief Unit test for ipv4_checksum module.
 * @details Tests:
 *   T1: Valid IPv4/UDP header (checksum=0) -> correct checksum output
 *       Words: 0x4500 0028 0001 0000 4011 0000 C0A8 0102 C0A8 0101
 *       Sum = 0x2088D -> fold = 0x088F -> ~0x088F = 0xF770
 *   T2: Same header with checksum=0xF770 inserted -> output 0x0000
 *       (verification: sum of all words including checksum = 0xFFFF)
 *   T3: Different IP addresses (10.0.0.1 -> 10.0.0.2) -> checksum 0x66C2
 *       Confirms IP fields affect checksum independently.
 *   T4: Edge case — nine 0xFFFF words + 0x0001 -> fold2 carry path
 *       sum = 0x8FFF8 -> fold1 = 0x10000 -> fold2 = 0x0001 -> ~0x0001 = 0xFFFE
 */

module tb_ipv4_checksum;

  logic [159:0] header;
  logic [15:0]  checksum;

  int fails = 0;

  ipv4_checksum dut (
    .header_i(header),
    .checksum_o(checksum)
  );

  task automatic check(
    input logic [159:0] hdr,
    input logic [15:0]  exp,
    input string        label
  );
    header = hdr;
    #1;
    if (checksum !== exp) begin
      $error("%s FAIL: checksum=0x%04X want 0x%04X", label, checksum, exp);
      fails++;
    end else $display("%s PASS: checksum=0x%04X", label, checksum);
  endtask

  initial begin
    // ===== T1: IPv4/UDP header, checksum field = 0 =====
    // ver=0x45 dscp=0x00 len=0x0028 id=0x0001 frag=0x0000
    // ttl=0x40 proto=0x11 csum=0x0000 src=192.168.1.2 dst=192.168.1.1
    // Words: 4500 0028 0001 0000 4011 0000 C0A8 0102 C0A8 0101
    // Sum = 0x2088D -> fold 0x088D+2 = 0x088F -> ~0x088F = 0xF770
    check(
      160'h45_00_00_28_00_01_00_00_40_11_00_00_C0_A8_01_02_C0_A8_01_01,
      16'hF770,
      "T1"
    );

    // ===== T2: Same header with checksum = 0xF770 inserted =====
    // Sum of all 10 words including checksum = 0x2FFFD
    // fold1 = 0xFFFD+2 = 0xFFFF -> ~0xFFFF = 0x0000
    check(
      160'h45_00_00_28_00_01_00_00_40_11_F7_70_C0_A8_01_02_C0_A8_01_01,
      16'h0000,
      "T2"
    );

    // ===== T3: Different src/dst IP -> different checksum =====
    // src=10.0.0.1 dst=10.0.0.2 checksum=0
    // Words: 4500 0028 0001 0000 4011 0000 0A00 0001 0A00 0002
    // Sum = 0x0993D -> ~0x993D = 0x66C2
    check(
      160'h45_00_00_28_00_01_00_00_40_11_00_00_0A_00_00_01_0A_00_00_02,
      16'h66C2,
      "T3"
    );

    // ===== T4: Edge case — fold2 carry path =====
    // Nine words of 0xFFFF + one word 0x0001
    // sum = 9*0xFFFF + 1 = 0x8FFF8
    // fold1 = 0xFFF8 + 0x8 = 0x10000  (17-bit overflow)
    // fold2 = 0x0000 + 1 = 0x0001  -> ~0x0001 = 0xFFFE
    check(
      {{9{16'hFFFF}}, 16'h0001},
      16'hFFFE,
      "T4"
    );

    if (fails == 0) $display("tb_ipv4_checksum: ALL PASS");
    else            $fatal(1, "tb_ipv4_checksum: %0d FAILURES", fails);
    $finish;
  end

endmodule
