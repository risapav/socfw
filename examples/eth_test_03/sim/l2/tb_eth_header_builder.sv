`timescale 1ns/1ps
/**
 * @file tb_eth_header_builder.sv
 * @brief Unit test for eth_header_builder module.
 * @details Tests:
 *   T1: Expert test vector — exact byte sequence for known DST/SRC/ETYPE
 *   T2: Second vector — verifies all three fields are independent
 *   T3: Out-of-range index (14, 15) -> 0x00 (default case)
 */

module tb_eth_header_builder;

  logic [47:0] dst_mac;
  logic [47:0] src_mac;
  logic [15:0] ethertype;
  logic [3:0]  byte_idx;
  logic [7:0]  byte_out;

  int fails = 0;

  eth_header_builder dut (
    .dst_mac_i(dst_mac), .src_mac_i(src_mac), .ethertype_i(ethertype),
    .byte_idx_i(byte_idx), .byte_o(byte_out)
  );

  // Check one byte and report pass/fail
  task automatic check_byte(
    input int          idx,
    input logic [7:0]  got,
    input logic [7:0]  exp,
    input string       label
  );
    if (got !== exp) begin
      $error("%s FAIL: byte[%0d]=0x%02X want 0x%02X", label, idx, got, exp);
      fails++;
    end
  endtask

  initial begin
    // ===== T1: expert test vector =====
    // dst = DE:AD:BE:EF:12:34   src = 00:0A:35:01:FE:C0   etype = 0x0800
    begin
      logic [7:0] expected[14];
      dst_mac   = 48'hDE_AD_BE_EF_12_34;
      src_mac   = 48'h00_0A_35_01_FE_C0;
      ethertype = 16'h0800;

      expected[0]  = 8'hDE; expected[1]  = 8'hAD; expected[2]  = 8'hBE;
      expected[3]  = 8'hEF; expected[4]  = 8'h12; expected[5]  = 8'h34;
      expected[6]  = 8'h00; expected[7]  = 8'h0A; expected[8]  = 8'h35;
      expected[9]  = 8'h01; expected[10] = 8'hFE; expected[11] = 8'hC0;
      expected[12] = 8'h08; expected[13] = 8'h00;

      for (int i = 0; i < 14; i++) begin
        byte_idx = 4'(i);
        #1;
        check_byte(i, byte_out, expected[i], "T1");
      end
      if (fails == 0) $display("T1  PASS: DE:AD:BE:EF:12:34 / 00:0A:35:01:FE:C0 / 0800");
    end

    // ===== T2: second vector — all fields differ =====
    // dst = FF:FF:FF:FF:FF:FF   src = AA:BB:CC:DD:EE:FF   etype = 0x86DD (IPv6)
    begin
      logic [7:0] expected[14];
      dst_mac   = 48'hFF_FF_FF_FF_FF_FF;
      src_mac   = 48'hAA_BB_CC_DD_EE_FF;
      ethertype = 16'h86DD;

      expected[0]  = 8'hFF; expected[1]  = 8'hFF; expected[2]  = 8'hFF;
      expected[3]  = 8'hFF; expected[4]  = 8'hFF; expected[5]  = 8'hFF;
      expected[6]  = 8'hAA; expected[7]  = 8'hBB; expected[8]  = 8'hCC;
      expected[9]  = 8'hDD; expected[10] = 8'hEE; expected[11] = 8'hFF;
      expected[12] = 8'h86; expected[13] = 8'hDD;

      for (int i = 0; i < 14; i++) begin
        byte_idx = 4'(i);
        #1;
        check_byte(i, byte_out, expected[i], "T2");
      end
      if (fails == 0) $display("T2  PASS: FF:FF:FF:FF:FF:FF / AA:BB:CC:DD:EE:FF / 86DD");
    end

    // ===== T3: out-of-range index -> 0x00 =====
    begin
      dst_mac   = 48'hDE_AD_BE_EF_12_34;
      src_mac   = 48'h00_0A_35_01_FE_C0;
      ethertype = 16'h0800;

      for (int i = 14; i < 16; i++) begin
        byte_idx = 4'(i);
        #1;
        if (byte_out !== 8'h00) begin
          $error("T3 FAIL: byte[%0d]=0x%02X want 0x00", i, byte_out);
          fails++;
        end
      end
      if (fails == 0) $display("T3  PASS: out-of-range index -> 0x00");
    end

    if (fails == 0) $display("tb_eth_header_builder: ALL PASS");
    else            $fatal(1, "tb_eth_header_builder: %0d FAILURES", fails);
    $finish;
  end

endmodule
