// @file  tb_tmds_phy_loopback.sv
// @brief PHY serializer loopback testbench for tmds_phy_ddr_aligned.
//
// @details
//   Drives known 10-bit TMDS/TERC4 symbols into tmds_phy_ddr_aligned, then
//   deserializes hdmi_p_o back to 10-bit words and checks for bit-exact match.
//
//   Verified symbol types:
//     CTL symbols   - control period (blanking)
//     VIDEO_GB      - video guard band
//     DATA_GB       - data island guard band (TERC4 values per HDMI 1.3 Table 5-8)
//     TERC4 payload - data island payload
//     TMDS clock    - clock channel 1111100000
//
//   The DDR serializer outputs 2 bits per clk_x cycle, LSB-first.
//   pair_cnt 0..4: bits [1:0], [3:2], [5:4], [7:6], [9:8].
//   Symbol loaded at pair_cnt==4 is output starting at the next pair_cnt==0.
//
//   Clock ratios (simulation model):
//     clk_x  = 100 MHz (10 ns period)
//     Pixel  = 20 MHz  (50 ns) — implied by pair_cnt cycle of 5 × clk_x
//
//   Depends on ddio_out_sim.sv compiled before tmds_phy_ddr_aligned.sv.
//
//   Run with: vsim -c -do "run -all; quit" tb_tmds_phy_loopback

`default_nettype none

import hdmi_pkg::*;

module tb_tmds_phy_loopback;

  // ── Clock & reset ────────────────────────────────────────────────────────────
  logic clk_x  = 1'b0;
  logic rst_ni = 1'b0;

  always #5 clk_x = ~clk_x;   // 10 ns period (100 MHz model)

  // ── DUT inputs ───────────────────────────────────────────────────────────────
  tmds_word_t ch0_in = '0;
  tmds_word_t ch1_in = '0;
  tmds_word_t ch2_in = '0;

  // ── DUT ──────────────────────────────────────────────────────────────────────
  logic [3:0] hdmi_p;

  tmds_phy_ddr_aligned dut (
    .clk_x_i  (clk_x),
    .rst_ni   (rst_ni),
    .ch0_i    (ch0_in),
    .ch1_i    (ch1_in),
    .ch2_i    (ch2_in),
    .clk_ch_i (10'b1111100000),
    .hdmi_p_o (hdmi_p)
  );

  // ── Known TMDS / TERC4 symbols ───────────────────────────────────────────────
  localparam tmds_word_t CTL00        = 10'b1101010100;  // CTL {0,0}
  localparam tmds_word_t CTL01        = 10'b0010101011;  // CTL {0,1}
  localparam tmds_word_t CTL10        = 10'b0101010100;  // CTL {1,0}
  localparam tmds_word_t CTL11        = 10'b1010101011;  // CTL {1,1}
  localparam tmds_word_t VIDEO_GB     = 10'b1011001100;  // TERC4(4'h8)  video guard
  localparam tmds_word_t DI_GB_CH0LL  = 10'b1010001110;  // TERC4(4'hC)  {1,1,VS=0,HS=0}
  localparam tmds_word_t DI_GB_CH1    = 10'b0101110001;  // TERC4(4'h4)  data island GB ch1
  localparam tmds_word_t DI_GB_CH2    = 10'b1011000110;  // TERC4(4'hB)  data island GB ch2
  localparam tmds_word_t TERC4_0      = 10'b1010011100;  // TERC4(4'h0)
  localparam tmds_word_t TERC4_F      = 10'b1011000011;  // TERC4(4'hF)
  localparam tmds_word_t TMDS_CLK     = 10'b1111100000;  // clock channel

  // ── Failure counter ───────────────────────────────────────────────────────────
  int assert_fail_count = 0;
  int checks_run        = 0;

  // ── Task: advance until pair_cnt == n (reads pre-NBA pair_cnt value) ──────────
  task automatic wait_for_pair_cnt(input logic [2:0] n);
    @(posedge clk_x);
    while (dut.pair_cnt !== n) @(posedge clk_x);
  endtask

  // ── Task: collect 10-bit deserialized symbol from all 4 hdmi_p lanes.
  //    Must be called immediately after @(posedge clk_x) at pair_cnt==0.
  //    Advances through pair_cnt 0..4, ending after negedge of pair_cnt==4. ────
  task automatic collect_all(
    output logic [9:0] g0,
    output logic [9:0] g1,
    output logic [9:0] g2,
    output logic [9:0] g3
  );
    for (int i = 0; i < 5; i++) begin
      // Posedge bit: sample after DDIO model NBA completes
      #1;
      g0[2*i]   = hdmi_p[0];
      g1[2*i]   = hdmi_p[1];
      g2[2*i]   = hdmi_p[2];
      g3[2*i]   = hdmi_p[3];
      // Negedge bit
      @(negedge clk_x);
      #1;
      g0[2*i+1] = hdmi_p[0];
      g1[2*i+1] = hdmi_p[1];
      g2[2*i+1] = hdmi_p[2];
      g3[2*i+1] = hdmi_p[3];
      // Advance to next pair (skip after last pair)
      if (i < 4) @(posedge clk_x);
    end
  endtask

  // ── Task: helper to report a single channel check ────────────────────────────
  task automatic check_ch(
    input logic [9:0] got,
    input logic [9:0] exp,
    input string      ch_name,
    input string      label
  );
    checks_run++;
    if (got !== exp) begin
      $error("PHY %s [%s]: got 0b%010b  exp 0b%010b", ch_name, label, got, exp);
      assert_fail_count++;
    end
  endtask

  // ── Task: drive symbols into all channels, verify one pixel cycle of output ──
  //    s0/s1/s2 are ch0/ch1/ch2; clock channel is always TMDS_CLK (hardwired). ─
  task automatic check_symbols(
    input tmds_word_t s0,
    input tmds_word_t s1,
    input tmds_word_t s2,
    input string      label
  );
    logic [9:0] g0, g1, g2, g3;

    // Present new inputs — must be stable before the next pair_cnt==4
    ch0_in = s0;
    ch1_in = s1;
    ch2_in = s2;

    // Wait for PHY to latch at pair_cnt==4
    wait_for_pair_cnt(3'd4);

    // Advance to pair_cnt==0 — first output cycle of the just-loaded symbols
    @(posedge clk_x);

    collect_all(g0, g1, g2, g3);

    check_ch(g0, s0,       "ch0", label);
    check_ch(g1, s1,       "ch1", label);
    check_ch(g2, s2,       "ch2", label);
    check_ch(g3, TMDS_CLK, "clk", label);

    $display("PHY [%s]  ch0=%010b ch1=%010b ch2=%010b clk=%010b",
             label, g0, g1, g2, g3);
  endtask

  // ── Main test sequence ────────────────────────────────────────────────────────
  initial begin
    $display("=== tb_tmds_phy_loopback start ===");

    rst_ni = 1'b0;
    repeat (12) @(posedge clk_x);
    rst_ni = 1'b1;
    // Allow pair_cnt to reach a stable count (skip first partial pixel cycle)
    repeat (6) @(posedge clk_x);

    // Control symbols
    check_symbols(CTL00,    CTL01,     CTL10,     "CTL_mix");
    check_symbols(CTL11,    CTL11,     CTL11,     "CTL_11");

    // Video guard band (same symbol on all data channels)
    check_symbols(VIDEO_GB, VIDEO_GB,  VIDEO_GB,  "VIDEO_GB");

    // Data island guard band — HDMI 1.3 Table 5-8 (most critical path)
    check_symbols(DI_GB_CH0LL, DI_GB_CH1, DI_GB_CH2, "DATA_GB");

    // Data island payload (TERC4 samples)
    check_symbols(TERC4_0,  TERC4_0,   TERC4_0,   "TERC4_0");
    check_symbols(TERC4_F,  TERC4_F,   TERC4_F,   "TERC4_F");

    // Mixed: each channel carries a different symbol
    check_symbols(DI_GB_CH0LL, DI_GB_CH1, DI_GB_CH2, "GB_mixed");
    check_symbols(TERC4_0,  DI_GB_CH1, DI_GB_CH2, "PAYLOAD_ch0");

    repeat (5) @(posedge clk_x);
    $display("=== PHY loopback: %0d checks, %0d failure(s) ===",
             checks_run, assert_fail_count);
    if (assert_fail_count == 0)
      $display("PHY LOOPBACK PASS");
    else
      $display("PHY LOOPBACK FAIL");
    $finish;
  end

  // Timeout guard
  initial begin
    #200000;
    $fatal(1, "tb_tmds_phy_loopback: timeout");
  end

endmodule
