`default_nettype none

import hdmi_pkg::*;

// Testbench for terc4_encoder.
//
// Verified contract:
//   nibble_i sampled at cycle T appears as tmds_o at cycle T+2 (LATENCY=2).
//   Reset output is TERC4(0x0) = 10'b1010011100.
//
// Guards pipeline latency = 2 against regression and verifies all 16
// nibble -> TERC4 symbol mappings from HDMI 1.3 spec section 5.4.3.
//
// Scenarios:
//   1. Post-reset output = TERC4(0x0).
//   2. Pipeline latency = exactly 2 clock cycles.
//      Catches both 1-stage regression (output arrives 1 cycle early)
//      and 3-stage regression (output arrives 1 cycle late).
//   3. Exhaustive: all 16 nibbles produce the correct TMDS symbol.
module tb_terc4_encoder;

  localparam int LATENCY = 2;  // expected pipeline depth; fail if encoder changes it

  logic clk = 0;
  always #5 clk = ~clk;  // 10 ns / 100 MHz

  logic       rst_n;
  logic [3:0] nibble;
  tmds_word_t tmds;

  terc4_encoder dut (
    .clk_i   (clk),
    .rst_ni  (rst_n),
    .nibble_i(nibble),
    .tmds_o  (tmds)
  );

  bit error_flag;

  // Reference LUT -- mirrors terc4_encoder; divergence = test error.
  function automatic tmds_word_t ref_terc4(input logic [3:0] n);
    unique case (n)
      4'h0: return 10'b1010011100;
      4'h1: return 10'b1001100011;
      4'h2: return 10'b1011100100;
      4'h3: return 10'b1011100010;
      4'h4: return 10'b0101110001;
      4'h5: return 10'b0100011110;
      4'h6: return 10'b0110001110;
      4'h7: return 10'b0100111100;
      4'h8: return 10'b1011001100;
      4'h9: return 10'b0100111001;
      4'ha: return 10'b0110011100;
      4'hb: return 10'b1011000110;
      4'hc: return 10'b1010001110;
      4'hd: return 10'b1001110001;
      4'he: return 10'b0101100011;
      4'hf: return 10'b1011000011;
      default: return 10'b1010011100;
    endcase
  endfunction

  // ── Scenario 1: post-reset output ────────────────────────────────────────
  task automatic test_reset_output;
    $display("=== Scenario 1: post-reset output ===");
    rst_n  = 0;
    nibble = 4'hf;  // non-zero during reset; output must not follow it
    @(posedge clk); @(posedge clk);
    #1;
    if (tmds === ref_terc4(4'h0))
      $display("PASS: reset output = %010b = TERC4(0x0)", tmds);
    else begin
      $display("FAIL: reset output = %010b (expected %010b)", tmds, ref_terc4(4'h0));
      error_flag = 1;
    end
    rst_n = 1;
    @(posedge clk);
  endtask

  // ── Scenario 2: pipeline latency = exactly LATENCY cycles ─────────────────
  // Settle on nibble=0x0, then switch to 0xf.
  //   1 cycle after switch: tmds must still be TERC4(0x0)  -- stage-1 captured,
  //                         stage-2 not yet (catches latency shrank to 1).
  //   2 cycles after switch: tmds must be TERC4(0xf)       -- catches latency grew to 3.
  task automatic test_latency;
    tmds_word_t out_1, out_2;
    $display("=== Scenario 2: pipeline latency (expect %0d) ===", LATENCY);
    nibble = 4'h0;
    repeat (LATENCY) @(posedge clk);  // settle pipeline at TERC4(0x0)

    nibble = 4'hf;                    // switch (between posedge LATENCY and LATENCY+1)
    @(posedge clk); #1; out_1 = tmds; // 1 cycle after switch
    @(posedge clk); #1; out_2 = tmds; // 2 cycles after switch

    if (out_1 !== ref_terc4(4'h0)) begin
      $display("FAIL: output changed before LATENCY=%0d cycles (cycle 1: got %010b exp %010b)",
               LATENCY, out_1, ref_terc4(4'h0));
      error_flag = 1;
    end else if (out_2 !== ref_terc4(4'hf)) begin
      $display("FAIL: output not ready at LATENCY=%0d cycles (cycle 2: got %010b exp %010b)",
               LATENCY, out_2, ref_terc4(4'hf));
      error_flag = 1;
    end else
      $display("PASS: pipeline latency = %0d cycles verified", LATENCY);
  endtask

  // ── Scenario 3: exhaustive LUT (all 16 nibbles) ───────────────────────────
  // For each nibble, hold it constant for LATENCY cycles and check the output.
  task automatic test_exhaustive;
    int fail_count;
    $display("=== Scenario 3: exhaustive LUT ===");
    fail_count = 0;
    for (int n = 0; n < 16; n++) begin
      nibble = 4'(n);
      repeat (LATENCY) @(posedge clk);
      #1;
      if (tmds !== ref_terc4(4'(n))) begin
        $display("FAIL: nibble=0x%0h got %010b exp %010b", n, tmds, ref_terc4(4'(n)));
        fail_count++;
        error_flag = 1;
      end
    end
    if (fail_count == 0)
      $display("PASS: all 16 nibbles encode correctly");
    else
      $display("FAIL: %0d nibble(s) wrong", fail_count);
  endtask

  // ── Main ─────────────────────────────────────────────────────────────────
  initial begin
    error_flag = 0;
    test_reset_output();
    test_latency();
    test_exhaustive();
    $display("---");
    if (!error_flag) begin
      $display("ALL TESTS PASSED");
      $finish;
    end else begin
      $display("SOME TESTS FAILED");
      $fatal(1);
    end
  end

endmodule
