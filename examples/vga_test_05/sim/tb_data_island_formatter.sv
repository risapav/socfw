`timescale 1ns/1ps
`default_nettype none

// Standalone testbench for data_island_formatter.
//
// Scenario 1: AVI InfoFrame, hsync=0 vsync=0 throughout.
//   HB = {0x82, 0x02, 0x0D}
//   PB[0] = 0x57 (checksum), PB[1]=0x10, PB[2]=0x08, PB[3..27]=0x00
//   Expected nibbles computed by Python reference model.
//
// Scenario 2: same packet, hsync=1 vsync=0 throughout.
//   ch0[0] becomes 1; parity flips (P_n includes CTL0=HSYNC per spec).
//   Verifies that parity = XOR(hdr_bit, vsync, hsync, sp_bits) is correct.
//
// Parity correctness is verified independently each cycle for both scenarios.
//
// Run:
//   vlog -sv -suppress 2892 ../rtl/hdmi/hdmi_bch_ecc.sv \
//                           ../rtl/hdmi/data_island_formatter.sv \
//                           tb_data_island_formatter.sv
//   vsim -c -do "run -all; quit" tb_data_island_formatter
module tb_data_island_formatter;

  logic       clk, rst_ni;
  logic       start_i, advance_i;
  logic       hsync_i, vsync_i;
  logic [7:0] hb [0:2];
  logic [7:0] pb [0:27];
  logic [3:0] ch0_o, ch1_o, ch2_o;
  logic       active_o, done_o;

  data_island_formatter u_dut (
    .clk_i    (clk),
    .rst_ni   (rst_ni),
    .start_i  (start_i),
    .advance_i(advance_i),
    .hsync_i  (hsync_i),
    .vsync_i  (vsync_i),
    .hb       (hb),
    .pb       (pb),
    .ch0_o    (ch0_o),
    .ch1_o    (ch1_o),
    .ch2_o    (ch2_o),
    .active_o (active_o),
    .done_o   (done_o)
  );

  always #5 clk = ~clk;

  // ── Reference nibbles (Python BCH model, vsync=0, hsync=0) ─────────────────
  // AVI: HB={0x82,0x02,0x0D}, PB0=0x57, PB1=0x10, PB2=0x08, rest=0
  logic [3:0] exp_ch0 [0:31] = '{
    4'h0, 4'h4, 4'h8, 4'h8, 4'h0, 4'h0, 4'h8, 4'hC,
    4'h0, 4'h4, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,
    4'hC, 4'h0, 4'hC, 4'hC, 4'h0, 4'h0, 4'h0, 4'h0,
    4'hC, 4'hC, 4'hC, 4'h0, 4'h0, 4'hC, 4'h4, 4'h8
  };
  logic [3:0] exp_ch1 [0:31] = '{
    4'h3, 4'h1, 4'h1, 4'h1, 4'h0, 4'h0, 4'h1, 4'h0,
    4'h0, 4'h2, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,
    4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,
    4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h6, 4'hE, 4'hD
  };
  logic [3:0] exp_ch2 [0:31] = '{
    4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,
    4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,
    4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,
    4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'hF, 4'hF
  };

  // Scenario 2: hsync=1, vsync=0.  ch0 = old ^ 4'b1001 (bit[0]=hsync, bit[3]=parity flips).
  logic [3:0] exp_ch0_2 [0:31] = '{
    4'h9, 4'hD, 4'h1, 4'h1, 4'h9, 4'h9, 4'h1, 4'h5,
    4'h9, 4'hD, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9,
    4'h5, 4'h9, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9,
    4'h5, 4'h5, 4'h5, 4'h9, 4'h9, 4'h5, 4'hD, 4'h1
  };

  int fails = 0;

  task automatic check_sym(input int p,
                            input logic [3:0] e0, e1, e2);
    logic par;
    // Parity = XOR(hdr_bit=ch0[2], vsync=ch0[1], hsync=ch0[0], ch1[3:0], ch2[3:0])
    // per HDMI spec Table 5-11.
    par = ch0_o[2] ^ ch0_o[1] ^ ch0_o[0];
    for (int b = 0; b < 4; b++) par ^= ch1_o[b] ^ ch2_o[b];
    if (par !== ch0_o[3]) begin
      $display("FAIL p=%0d: parity mismatch — computed=%b, ch0[3]=%b", p, par, ch0_o[3]);
      fails++;
    end
    if (ch0_o !== e0) begin
      $display("FAIL p=%0d: ch0 got 0x%X expected 0x%X", p, ch0_o, e0);
      fails++;
    end
    if (ch1_o !== e1) begin
      $display("FAIL p=%0d: ch1 got 0x%X expected 0x%X", p, ch1_o, e1);
      fails++;
    end
    if (ch2_o !== e2) begin
      $display("FAIL p=%0d: ch2 got 0x%X expected 0x%X", p, ch2_o, e2);
      fails++;
    end
    if (ch0_o === e0 && ch1_o === e1 && ch2_o === e2)
      $display("  p=%2d  ch0=0x%X ch1=0x%X ch2=0x%X  OK", p, ch0_o, ch1_o, ch2_o);
  endtask

  initial begin
    clk = 0; rst_ni = 0; start_i = 0; advance_i = 0;
    hsync_i = 0; vsync_i = 0;

    // AVI InfoFrame: HB={0x82,0x02,0x0D}, PB0=checksum=0x57, PB1=0x10, PB2=0x08
    hb[0] = 8'h82; hb[1] = 8'h02; hb[2] = 8'h0D;
    pb[0] = 8'h57; pb[1] = 8'h10; pb[2] = 8'h08;
    for (int i = 3; i < 28; i++) pb[i] = 8'h00;

    repeat(3) @(posedge clk);
    rst_ni = 1;
    @(posedge clk);

    // ── Scenario 1: vsync=0, hsync=0 ────────────────────────────────────────
    $display("=== Scenario 1: vsync=0 hsync=0 ===");
    hsync_i = 0; vsync_i = 0;
    start_i = 1;
    @(posedge clk);
    start_i = 0;
    #1;
    check_sym(0, exp_ch0[0], exp_ch1[0], exp_ch2[0]);

    for (int p = 1; p < 32; p++) begin
      advance_i = 1;
      @(posedge clk);
      advance_i = 0;
      #1;
      check_sym(p, exp_ch0[p], exp_ch1[p], exp_ch2[p]);
    end

    advance_i = 1;
    @(posedge clk);
    advance_i = 0;
    #1;
    if (active_o !== 1'b0) begin
      $display("FAIL: active_o should be 0 after 32nd advance");
      fails++;
    end else
      $display("  active_o=0 after 32nd advance  OK");

    // ── Scenario 2: vsync=0, hsync=1 — catches missing CTL0 in parity ───────
    // parity must flip for every symbol vs scenario 1.
    $display("=== Scenario 2: vsync=0 hsync=1 ===");
    hsync_i = 1; vsync_i = 0;
    @(posedge clk);
    start_i = 1;
    @(posedge clk);
    start_i = 0;
    #1;
    check_sym(0, exp_ch0_2[0], exp_ch1[0], exp_ch2[0]);

    for (int p = 1; p < 32; p++) begin
      advance_i = 1;
      @(posedge clk);
      advance_i = 0;
      #1;
      check_sym(p, exp_ch0_2[p], exp_ch1[p], exp_ch2[p]);
    end

    $display("");
    $display("%s (%0d failure%s)",
             fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
             fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
