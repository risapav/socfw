`timescale 1ns/1ps
`default_nettype none

// Testbench for acr_packet_builder.
//
// Purely combinational DUT — no clock needed.
// Checks header bytes, all 4 identical subpackets, and valid_o gating.
//
// Run with:
//   vlog -sv -suppress 2892 ../rtl/hdmi/acr_packet_builder.sv tb_acr_packet_builder.sv
//   vsim -c -do "run -all; quit" tb_acr_packet_builder
module tb_acr_packet_builder;

  logic        enable;
  logic [19:0] n_val;
  logic [19:0] cts_val;
  logic        cts_valid;

  logic [7:0]  hb [0:2];
  logic [7:0]  pb [0:27];
  logic        valid;

  acr_packet_builder dut (
    .enable_i   (enable),
    .n_i        (n_val),
    .cts_i      (cts_val),
    .cts_valid_i(cts_valid),
    .hb_o       (hb),
    .pb_o       (pb),
    .valid_o    (valid)
  );

  int fails = 0;

  task automatic chk8(string lbl, logic [7:0] got, logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%02X expected 0x%02X", lbl, got, exp);
      fails++;
    end
  endtask

  task automatic chk1(string lbl, logic got, logic exp);
    if (got !== exp) begin
      $display("FAIL %s: got %0b expected %0b", lbl, got, exp);
      fails++;
    end
  endtask

  initial begin
    // ── Test 1: standard 800×600/48kHz values ────────────────────────────────
    enable    = 1'b1;
    n_val     = 20'd6144;
    cts_val   = 20'd40000;
    cts_valid = 1'b1;
    #1;

    chk8("T1 hb[0]", hb[0], 8'h01);
    chk8("T1 hb[1]", hb[1], 8'h00);
    chk8("T1 hb[2]", hb[2], 8'h00);
    chk1("T1 valid", valid, 1'b1);

    // HDMI 1.3 Table 7-3: MSB-first byte order
    for (int sp = 0; sp < 4; sp++) begin
      chk8($sformatf("T1 sp%0d pb[0] CTS[19:16]", sp), pb[sp*7+0], {4'h0, cts_val[19:16]});
      chk8($sformatf("T1 sp%0d pb[1] CTS[15:8]",  sp), pb[sp*7+1], cts_val[15:8]);
      chk8($sformatf("T1 sp%0d pb[2] CTS[7:0]",   sp), pb[sp*7+2], cts_val[7:0]);
      chk8($sformatf("T1 sp%0d pb[3] N[19:16]",   sp), pb[sp*7+3], {4'h0, n_val[19:16]});
      chk8($sformatf("T1 sp%0d pb[4] N[15:8]",    sp), pb[sp*7+4], n_val[15:8]);
      chk8($sformatf("T1 sp%0d pb[5] N[7:0]",     sp), pb[sp*7+5], n_val[7:0]);
      chk8($sformatf("T1 sp%0d pb[6] reserved",   sp), pb[sp*7+6], 8'h00);
    end

    // ── Test 2: enable=0 → valid=0 ───────────────────────────────────────────
    enable = 1'b0;
    #1;
    chk1("T2 valid=0 when disabled", valid, 1'b0);

    // ── Test 3: cts_valid=0 → valid=0 ────────────────────────────────────────
    enable    = 1'b1;
    cts_valid = 1'b0;
    #1;
    chk1("T3 valid=0 when cts_invalid", valid, 1'b0);

    // ── Test 4: arbitrary N/CTS — verify byte split and all 4 subpackets equal
    enable    = 1'b1;
    n_val     = 20'hABCDE;
    cts_val   = 20'h12345;
    cts_valid = 1'b1;
    #1;

    // CTS=0x12345: {4'h0,1}, 0x23, 0x45  N=0xABCDE: {4'h0,A}, 0xBC, 0xDE  reserved=0x00
    chk8("T4 sp0 pb[0] CTS[19:16]", pb[0], 8'h01);
    chk8("T4 sp0 pb[1] CTS[15:8]",  pb[1], 8'h23);
    chk8("T4 sp0 pb[2] CTS[7:0]",   pb[2], 8'h45);
    chk8("T4 sp0 pb[3] N[19:16]",   pb[3], 8'h0A);
    chk8("T4 sp0 pb[4] N[15:8]",    pb[4], 8'hBC);
    chk8("T4 sp0 pb[5] N[7:0]",     pb[5], 8'hDE);
    chk8("T4 sp0 pb[6] reserved",   pb[6], 8'h00);

    for (int sp = 1; sp < 4; sp++) begin
      for (int b = 0; b < 7; b++) begin
        chk8($sformatf("T4 sp%0d==sp0 byte%0d", sp, b), pb[sp*7+b], pb[b]);
      end
    end

    $display("");
    $display("%s (%0d failure%s)",
             fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
             fails, fails == 1 ? "" : "s");
    $finish;
  end

endmodule
