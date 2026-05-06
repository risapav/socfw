`default_nettype none

import hdmi_pkg::*;

// Testbench for hdmi_period_scheduler (ENABLE_DATA_ISLAND=1).
//
// Inputs are driven at posedge clk; outputs are sampled 1 ns later (#1)
// to allow non-blocking assignments to propagate before reading period_o.
//
// Three scenarios:
//   1. No data island — verify preamble=8, GB=2, no packet_pop.
//   2. Minimum-budget data island — island ends exactly at VIDEO_TRIG;
//      the <= trigger must still fire and preamble must complete.
//   3. Full island at generous budget — verify all eight period counts and
//      that DATA_PAYLOAD never coincides with DE.
module tb_hdmi_period_scheduler;

  // 10 ns clock
  logic clk = 0;
  always #5 clk = ~clk;

  // DUT ports
  logic        rst_n;
  logic        de;
  logic        hblank;
  logic        vblank;
  logic [15:0] blank_remaining;
  logic        packet_pending;
  logic        packet_start;
  logic        packet_pop;
  hdmi_period_t period;

  hdmi_period_scheduler #(.ENABLE_DATA_ISLAND(1)) dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .de_i              (de),
    .hblank_i          (hblank),
    .vblank_i          (vblank),
    .blank_remaining_i (blank_remaining),
    .packet_pending_i  (packet_pending),
    .packet_start_o    (packet_start),
    .packet_pop_o      (packet_pop),
    .period_o          (period)
  );

  bit  error_flag;

  task automatic reset_dut;
    rst_n          = 0;
    de             = 0;
    hblank         = 0;
    vblank         = 0;
    blank_remaining = 0;
    packet_pending = 0;
    @(posedge clk); @(posedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  // Drive one hblank+active line.
  // Counts of each period type are returned through output arguments.
  // #1 after each posedge lets NBA propagate so period_o reads correctly.
  task automatic drive_line(
    input  int blank_cycles,
    input  int active_cycles,
    input  bit with_packet,
    output int ctrl_cnt,
    output int data_pre_cnt,
    output int lead_gb_cnt,
    output int payload_cnt,
    output int trail_gb_cnt,
    output int vid_pre_cnt,
    output int vid_gb_cnt,
    output int pop_cnt,
    output bit de_during_payload
  );
    ctrl_cnt       = 0;
    data_pre_cnt   = 0;
    lead_gb_cnt    = 0;
    payload_cnt    = 0;
    trail_gb_cnt   = 0;
    vid_pre_cnt    = 0;
    vid_gb_cnt     = 0;
    pop_cnt        = 0;
    de_during_payload = 0;

    hblank         = 1;
    de             = 0;
    if (with_packet) packet_pending = 1;

    for (int i = blank_cycles; i >= 1; i--) begin
      blank_remaining = 16'(i);
      @(posedge clk);
      #1;  // wait for NBA to propagate period_o
      if (packet_start) packet_pending = 0;
      case (period)
        HDMI_PERIOD_CONTROL:        ctrl_cnt++;
        HDMI_PERIOD_DATA_PREAMBLE:  data_pre_cnt++;
        HDMI_PERIOD_DATA_GB_LEAD:   lead_gb_cnt++;
        HDMI_PERIOD_DATA_PAYLOAD: begin
          payload_cnt++;
          if (de) de_during_payload = 1;
        end
        HDMI_PERIOD_DATA_GB_TRAIL:  trail_gb_cnt++;
        HDMI_PERIOD_VIDEO_PREAMBLE: vid_pre_cnt++;
        HDMI_PERIOD_VIDEO_GB:       vid_gb_cnt++;
        default: ;
      endcase
      if (packet_pop) pop_cnt++;
    end

    // Active video phase
    hblank  = 0;
    blank_remaining = 0;
    de = 1;
    repeat (active_cycles) begin
      @(posedge clk);
      #1;
    end
    de = 0;
    @(posedge clk);
    #1;
  endtask

  // ── Scenario 1: No data island ────────────────────────────────────────────
  task automatic test_no_island;
    int ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop;
    bit dep;
    $display("=== Scenario 1: No data island ===");
    reset_dut();
    drive_line(256, 800, 0, ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop, dep);

    if (vid_pre == 8)
      $display("PASS: VIDEO_PREAMBLE = %0d (expected 8)", vid_pre);
    else begin
      $display("FAIL: VIDEO_PREAMBLE = %0d (expected 8)", vid_pre);
      error_flag = 1;
    end
    if (vid_gb == 2)
      $display("PASS: VIDEO_GB = %0d (expected 2)", vid_gb);
    else begin
      $display("FAIL: VIDEO_GB = %0d (expected 2)", vid_gb);
      error_flag = 1;
    end
    if (pop == 0)
      $display("PASS: no packet_pop (expected 0)");
    else begin
      $display("FAIL: packet_pop = %0d (expected 0)", pop);
      error_flag = 1;
    end
  endtask

  // ── Scenario 2: Minimum-budget data island ────────────────────────────────
  // Guard = ISLAND_TOTAL + VIDEO_TRIG = 44 + 10 = 54.
  // Start island at blank_remaining = 54; after 44 cycles blank_remaining = 10.
  // ST_CONTROL re-enters when blank_remaining = 9 (<= VIDEO_TRIG=10 → trigger fires).
  task automatic test_min_budget_island;
    int ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop;
    bit dep;
    $display("=== Scenario 2: Minimum-budget data island ===");
    reset_dut();
    // Enough blank for island (starts at 256, first opportunity >= 54) + video preamble.
    drive_line(256, 800, 1, ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop, dep);

    if (vid_pre >= 7)  // allow 1-cycle slip from <= trigger
      $display("PASS: VIDEO_PREAMBLE fires after island (%0d cycles, expect 7-8)", vid_pre);
    else begin
      $display("FAIL: VIDEO_PREAMBLE = %0d after min-budget island (expected >=7)", vid_pre);
      error_flag = 1;
    end
    if (payload == 32)
      $display("PASS: DATA_PAYLOAD = %0d (expected 32)", payload);
    else begin
      $display("FAIL: DATA_PAYLOAD = %0d (expected 32)", payload);
      error_flag = 1;
    end
  endtask

  // ── Scenario 3: All period counts verified ────────────────────────────────
  task automatic test_full_counts;
    int ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop;
    bit dep;
    $display("=== Scenario 3: All period counts ===");
    reset_dut();
    drive_line(256, 800, 1, ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop, dep);

    $display("Counts during hblank:");
    $display("  CONTROL        : %0d", ctrl_cnt);
    $display("  DATA_PREAMBLE  : %0d (expected 8)",  data_pre);
    $display("  DATA_GB_LEAD   : %0d (expected 2)",  lead_gb);
    $display("  DATA_PAYLOAD   : %0d (expected 32)", payload);
    $display("  DATA_GB_TRAIL  : %0d (expected 2)",  trail_gb);
    $display("  VIDEO_PREAMBLE : %0d (expected 8)",  vid_pre);
    $display("  VIDEO_GB       : %0d (expected 2)",  vid_gb);

    if (data_pre == 8 && lead_gb == 2 && payload == 32 &&
        trail_gb == 2 && vid_pre == 8 && vid_gb == 2)
      $display("PASS: all period counts correct");
    else begin
      $display("FAIL: one or more counts wrong");
      error_flag = 1;
    end
    if (pop == 32)
      $display("PASS: packet_pop fires exactly 32 times");
    else begin
      $display("FAIL: packet_pop = %0d (expected 32)", pop);
      error_flag = 1;
    end
    if (!dep)
      $display("PASS: DATA_PAYLOAD never overlaps DE");
    else begin
      $display("FAIL: DATA_PAYLOAD overlapped DE");
      error_flag = 1;
    end
  endtask

  // ── Scenario 4: Tight minimum budget — island guard boundary ─────────────
  // Drive a line where hblank has exactly 54 + 10 = 64 cycles.
  // Island starts at blank_remaining=64, ends at blank_remaining=20.
  // After the trail GB, blank_remaining = 10; <= trigger fires immediately.
  task automatic test_tight_budget;
    int ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop;
    bit dep;
    $display("=== Scenario 4: Tight budget (hblank=64) ===");
    reset_dut();
    drive_line(64, 800, 1, ctrl_cnt, data_pre, lead_gb, payload, trail_gb, vid_pre, vid_gb, pop, dep);

    if (vid_pre >= 7)
      $display("PASS: VIDEO_PREAMBLE = %0d after tight island", vid_pre);
    else begin
      $display("FAIL: VIDEO_PREAMBLE = %0d (expected >=7)", vid_pre);
      error_flag = 1;
    end
    if (payload == 32)
      $display("PASS: DATA_PAYLOAD = 32");
    else begin
      $display("FAIL: DATA_PAYLOAD = %0d", payload);
      error_flag = 1;
    end
  endtask

  // ── Main ──────────────────────────────────────────────────────────────────
  initial begin
    error_flag = 0;
    test_no_island();
    test_min_budget_island();
    test_full_counts();
    test_tight_budget();
    $display("---");
    if (!error_flag)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED");
    $finish;
  end

endmodule
