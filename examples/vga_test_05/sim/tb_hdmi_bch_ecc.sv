`timescale 1ns/1ps

// Standalone testbench for hdmi_bch_ecc.
//
// BCH parameters: polynomial x^8+x^4+x^3+x^2+1, initial LFSR 0xFF,
// bits processed LSB-first per byte in byte order HB0..HBn / PB0..PBn.
//
// Reference values computed by Python BCH model; cross-checked with the
// HDMI 1.3 spec requirement that all-zero 7-byte subpackets produce 0xF5.
//
// Run with:
//   vlog -sv -suppress 2892 ../rtl/hdmi/hdmi_bch_ecc.sv tb_hdmi_bch_ecc.sv
//   vsim -c -do "run -all; quit" tb_hdmi_bch_ecc
module tb_hdmi_bch_ecc;

  logic [23:0] hdr_data;
  logic [7:0]  hdr_ecc;
  hdmi_bch_ecc #(.DATA_BITS(24)) u_hdr (.data_i(hdr_data), .ecc_o(hdr_ecc));

  logic [55:0] sp_data;
  logic [7:0]  sp_ecc;
  hdmi_bch_ecc #(.DATA_BITS(56)) u_sp  (.data_i(sp_data),  .ecc_o(sp_ecc));

  int fails = 0;

  task chk_hdr(input logic [23:0] d, input logic [7:0] exp, input string lbl);
    hdr_data = d; #1;
    if (hdr_ecc !== exp) begin
      $display("FAIL %s: got 0x%02X expected 0x%02X", lbl, hdr_ecc, exp);
      fails++;
    end else
      $display("PASS %s: ECC=0x%02X", lbl, hdr_ecc);
  endtask

  task chk_sp(input logic [55:0] d, input logic [7:0] exp, input string lbl);
    sp_data = d; #1;
    if (sp_ecc !== exp) begin
      $display("FAIL %s: got 0x%02X expected 0x%02X", lbl, sp_ecc, exp);
      fails++;
    end else
      $display("PASS %s: ECC=0x%02X", lbl, sp_ecc);
  endtask

  initial begin
    hdr_data = '0; sp_data = '0;

    // Header tests: data_i = {HB2, HB1, HB0}
    chk_hdr(24'h0D_02_82, 8'h67, "AVI hdr {0x82,0x02,0x0D}");
    chk_hdr(24'h00_00_00, 8'h0E, "header all-zeros");
    chk_hdr(24'h00_00_03, 8'hAE, "GCP hdr {0x03,0x00,0x00}");

    // Subpacket tests: data_i = {PB6, PB5, PB4, PB3, PB2, PB1, PB0}
    chk_sp(56'h00_00_00_00_00_00_00, 8'hF5, "SP all-zeros (7 bytes)");
    chk_sp({8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h6F}, 8'h8F,
           "SP0 PB0=0x6F (AVI checksum, rest zeros)");

    $display("");
    $display("%s (%0d failure%s)",
             fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
             fails, fails == 1 ? "" : "s");
    $finish;
  end

endmodule
