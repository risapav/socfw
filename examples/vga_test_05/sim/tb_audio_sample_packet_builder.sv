`timescale 1ns/1ps
`default_nettype none

// Testbench for audio_sample_packet_builder.
//
// Purely combinational DUT — no clock needed.
// Verifies header, audio word byte split, and parity for each subpacket.
//
// Run with:
//   vlog -sv -suppress 2892 ../rtl/hdmi/audio_sample_packet_builder.sv \
//                            tb_audio_sample_packet_builder.sv
//   vsim -c -do "run -all; quit" tb_audio_sample_packet_builder
module tb_audio_sample_packet_builder;

  logic [15:0] l0, r0, l1, r1, l2, r2, l3, r3;
  logic [7:0]  hb [0:2];
  logic [7:0]  pb [0:27];

  audio_sample_packet_builder dut (
    .l0_i(l0), .r0_i(r0),
    .l1_i(l1), .r1_i(r1),
    .l2_i(l2), .r2_i(r2),
    .l3_i(l3), .r3_i(r3),
    .hb_o(hb),
    .pb_o(pb)
  );

  int fails = 0;

  task automatic chk8(string lbl, logic [7:0] got, logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%02X expected 0x%02X", lbl, got, exp);
      fails++;
    end
  endtask

  // Verify one subpacket (sp 0..3)
  task automatic chk_sp(
    int sp,
    logic [15:0] l_val, r_val
  );
    automatic int base = sp * 7;
    automatic logic [7:0] exp_pb0 = {3'b000, ^r_val, 3'b000, ^l_val};
    chk8($sformatf("sp%0d pb[0] VUCP", sp), pb[base+0], exp_pb0);
    chk8($sformatf("sp%0d pb[1] AW_L[7:0]=0",  sp), pb[base+1], 8'h00);
    chk8($sformatf("sp%0d pb[2] AW_L[15:8]",   sp), pb[base+2], l_val[7:0]);
    chk8($sformatf("sp%0d pb[3] AW_L[23:16]",  sp), pb[base+3], l_val[15:8]);
    chk8($sformatf("sp%0d pb[4] AW_R[7:0]=0",  sp), pb[base+4], 8'h00);
    chk8($sformatf("sp%0d pb[5] AW_R[15:8]",   sp), pb[base+5], r_val[7:0]);
    chk8($sformatf("sp%0d pb[6] AW_R[23:16]",  sp), pb[base+6], r_val[15:8]);
  endtask

  initial begin
    // ── Test 1: all zeros ─────────────────────────────────────────────────
    l0=0; r0=0; l1=0; r1=0; l2=0; r2=0; l3=0; r3=0;
    #1;
    chk8("T1 hb[0]", hb[0], 8'h02);
    chk8("T1 hb[1]", hb[1], 8'h0F);
    chk8("T1 hb[2]", hb[2], 8'h00);
    for (int sp = 0; sp < 4; sp++)
      chk_sp(sp, 16'h0000, 16'h0000);

    // ── Test 2: known values (L=0x0001, R=0x0003) ─────────────────────────
    // ^0x0001 = 1 (odd parity), ^0x0003 = 0 (even parity)
    l0=16'h0001; r0=16'h0003;
    l1=16'h0001; r1=16'h0003;
    l2=16'h0001; r2=16'h0003;
    l3=16'h0001; r3=16'h0003;
    #1;
    chk8("T2 pb[0] VUCP", pb[0], 8'h01);  // P1=0, P0=1
    chk8("T2 pb[2] L[7:0]",  pb[2], 8'h01);
    chk8("T2 pb[3] L[15:8]", pb[3], 8'h00);
    chk8("T2 pb[5] R[7:0]",  pb[5], 8'h03);
    chk8("T2 pb[6] R[15:8]", pb[6], 8'h00);

    // ── Test 3: distinct values in each slot ──────────────────────────────
    l0=16'hABCD; r0=16'h1234;
    l1=16'h0100; r1=16'h0200;
    l2=16'hFFFF; r2=16'h8000;
    l3=16'h0000; r3=16'h0001;
    #1;
    chk_sp(0, 16'hABCD, 16'h1234);
    chk_sp(1, 16'h0100, 16'h0200);
    chk_sp(2, 16'hFFFF, 16'h8000);
    chk_sp(3, 16'h0000, 16'h0001);

    // ── Test 4: parity of 0xFFFF ──────────────────────────────────────────
    // ^0xFFFF = 0 (even parity, all bits set)
    l0=16'hFFFF; r0=16'hFFFF; #1;
    chk8("T4 parity ^0xFFFF=0", pb[0], 8'h00);

    // ── Test 5: parity of 0x8000 ──────────────────────────────────────────
    // ^0x8000 = 1 (single bit)
    l0=16'h8000; r0=16'h8000; #1;
    chk8("T5 parity ^0x8000=1", pb[0], 8'h11);  // P1=1, P0=1

    $display("");
    $display("%s (%0d failure%s)",
             fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
             fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
