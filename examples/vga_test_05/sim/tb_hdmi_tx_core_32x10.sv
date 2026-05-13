`timescale 1ns/1ps
`default_nettype none

import hdmi_pkg::*;

// Diagnostic testbench for hdmi_tx_core — tiny 32×10 mode.
//
// Drives a mini video_timing_generator and hdmi_tx_core directly (no PHY).
// Simulates the vga_output_adapter pipeline stage for de/hsync/vsync.
//
// Checks:
//   1. period_o == VIDEO  ↔  de_r == 1  (bidirectional alignment)
//   2. DATA_PAYLOAD never overlaps de_r
//   3. DATA_PAYLOAD length = 32
//   4. DATA_PREAMBLE length = 8
//   5. DATA_GB_{LEAD,TRAIL} length = 2
//   6. VIDEO_PREAMBLE length = 8
//   7. VIDEO_GB length = 2
//
// Logs every period transition with cycle count and duration.
//
// Run:
//   make tx_core_32x10
module tb_hdmi_tx_core_32x10;

  // ── Tiny timing parameters ────────────────────────────────────────────────
  // H_BLANK = H_FP+H_SYNC+H_BP = 8+8+48 = 64 (>= ISLAND_TOTAL+VIDEO_TRIG=54)
  // Chose H_BP=48 so there are ≥ 8 CONTROL cycles between data island
  // trailing guard and VIDEO_PREAMBLE (64-44-10=10 cycles of CONTROL). ✓
  localparam int H_ACTIVE = 32;
  localparam int H_FP     = 8;
  localparam int H_SYNC   = 8;
  localparam int H_BP     = 48;
  localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;  // 96

  localparam int V_ACTIVE = 10;
  localparam int V_FP     = 2;
  localparam int V_SYNC   = 2;
  localparam int V_BP     = 2;
  localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;  // 16

  localparam bit HSYNC_POL = 1'b1;
  localparam bit VSYNC_POL = 1'b1;

  // ── Clock / reset ─────────────────────────────────────────────────────────
  logic pix_clk = 0;
  logic rst_n;

  always #12.5 pix_clk = ~pix_clk;  // 40 MHz

  initial begin
    rst_n = 1'b0;
    repeat (8) @(posedge pix_clk);
    @(negedge pix_clk);
    rst_n = 1'b1;
  end

  // ── Mini VTG ──────────────────────────────────────────────────────────────
  logic        vtg_de, vtg_hs, vtg_vs;
  logic        vtg_hblank, vtg_vblank;
  logic        vtg_frame_start, vtg_line_start;
  logic [15:0] vtg_blank_remaining;

  video_timing_generator #(
    .H_ACTIVE  (H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
    .V_ACTIVE  (V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP),
    .HSYNC_POL (HSYNC_POL), .VSYNC_POL(VSYNC_POL)
  ) u_vtg (
    .clk_i                  (pix_clk),
    .rst_ni                 (rst_n),
    .de_o                   (vtg_de),
    .hsync_o                (vtg_hs),
    .vsync_o                (vtg_vs),
    .pixel_req_o            (),
    .frame_start_o          (vtg_frame_start),
    .line_start_o           (vtg_line_start),
    .x_o                    (),
    .y_o                    (),
    .hblank_o               (vtg_hblank),
    .vblank_o               (vtg_vblank),
    .last_active_x_req_o    (),
    .last_active_pixel_req_o(),
    .blank_remaining_o      (vtg_blank_remaining),
    .h_cnt_o                (),
    .v_cnt_o                ()
  );

  // ── Simulate vga_output_adapter register stage ────────────────────────────
  // In the real design, de/hsync/vsync go through vga_output_adapter (1 reg)
  // before reaching hdmi_tx_core.  This extra stage is essential for the
  // VIDEO_TRIG = 10 alignment to be correct:
  //   de_comb → vtg_de (vtg reg) → de_d1 (vga_adapter reg) → de_r (hdmi stage-1) = 3 stages
  //   blank_remaining_comb → vtg_blank_remaining → blank_remaining_r → blank_remaining_rr = 3 stages
  logic de_d1, hs_d1, vs_d1;

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      de_d1 <= 1'b0;
      hs_d1 <= 1'b0;
      vs_d1 <= 1'b0;
    end else begin
      de_d1 <= vtg_de;
      hs_d1 <= vtg_hs;
      vs_d1 <= vtg_vs;
    end
  end

  // ── Pixel data (column=R, row=G, B=0xAA) ─────────────────────────────────
  // Use a free-running counter aligned to VTG: col advances each cycle.
  // vtg_de is registered 1 cycle behind (vtg counter), so pixel data fed
  // as raw 8-bit to hdmi_tx_core.red_i will be registered inside stage-1.
  logic [6:0] tb_col;
  logic [3:0] tb_row;

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      tb_col <= '0;
      tb_row <= '0;
    end else begin
      if (tb_col == H_TOTAL - 1) begin
        tb_col <= '0;
        tb_row <= (tb_row == V_TOTAL - 1) ? '0 : tb_row + 1'b1;
      end else begin
        tb_col <= tb_col + 1'b1;
      end
    end
  end

  wire [7:0] r8 = {1'b0, tb_col};
  wire [7:0] g8 = {4'h0, tb_row};
  wire [7:0] b8 = 8'hAA;

  // ── DUT: hdmi_tx_core ─────────────────────────────────────────────────────
  tmds_word_t ch0, ch1, ch2;

  hdmi_tx_core #(
    .ENABLE_DATA_ISLAND    (1),
    .ENABLE_ACR_PACKET     (0),
    .ENABLE_AUDIO_INFOFRAME(0),
    .ENABLE_AUDIO_SAMPLE   (0),
    .PIXEL_CLK_HZ          (40_000_000),
    .AUDIO_SAMPLE_RATE     (48_000)
  ) u_dut (
    .pix_clk_i        (pix_clk),
    .rst_ni           (rst_n),
    .red_i            (r8),
    .grn_i            (g8),
    .blu_i            (b8),
    .de_i             (de_d1),
    .hsync_i          (hs_d1),
    .vsync_i          (vs_d1),
    .hblank_i         (vtg_hblank),
    .vblank_i         (vtg_vblank),
    .frame_start_i    (vtg_frame_start),
    .line_start_i     (vtg_line_start),
    .blank_remaining_i(vtg_blank_remaining),
    .info_cfg_i       ('0),
    .color_fmt_i      (COLOR_FORMAT_RGB),
    .aspect_ratio_i   (ASPECT_RATIO_4_3),
    .quant_range_i    (QUANT_RANGE_FULL),
    .vic_code_i       (8'd0),
    .enable_audio_i   (1'b0),
    .acr_n_i          ('0),
    .acr_cts_i        ('0),
    .acr_cts_valid_i  (1'b0),
    .ch0_o            (ch0),
    .ch1_o            (ch1),
    .ch2_o            (ch2)
  );

  // ── Internal signal probes ────────────────────────────────────────────────
  wire hdmi_period_t w_period    = u_dut.period;
  wire hdmi_period_t w_period_d1 = u_dut.period_d1;
  wire               w_de_r      = u_dut.de_r;

  // Pipeline-aligned de_r delays for pipeline-stage assertions.
  // period_o is registered from state_next, so it is 1 cycle behind de_r:
  //   period_o VIDEO = de_r_d1 VIDEO range  (both D+1..D+H_ACTIVE)
  //   period_d1 VIDEO = de_r_d2 VIDEO range (both D+2..D+H_ACTIVE+1)
  logic w_de_r_d1, w_de_r_d2;

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      w_de_r_d1 <= 1'b0;
      w_de_r_d2 <= 1'b0;
    end else begin
      w_de_r_d1 <= w_de_r;
      w_de_r_d2 <= w_de_r_d1;
    end
  end

  // ── Cycle counter and period logger ──────────────────────────────────────
  int           sim_cycle;
  hdmi_period_t period_prev;
  int           period_run;   // how many cycles current period has lasted

  function automatic string period_name(input hdmi_period_t p);
    case (p)
      HDMI_PERIOD_CONTROL:        return "CONTROL       ";
      HDMI_PERIOD_VIDEO_PREAMBLE: return "VIDEO_PREAMBLE";
      HDMI_PERIOD_VIDEO_GB:       return "VIDEO_GB      ";
      HDMI_PERIOD_VIDEO:          return "VIDEO         ";
      HDMI_PERIOD_DATA_PREAMBLE:  return "DATA_PREAMBLE ";
      HDMI_PERIOD_DATA_GB_LEAD:   return "DATA_GB_LEAD  ";
      HDMI_PERIOD_DATA_PAYLOAD:   return "DATA_PAYLOAD  ";
      HDMI_PERIOD_DATA_GB_TRAIL:  return "DATA_GB_TRAIL ";
      default:                    return "UNKNOWN       ";
    endcase
  endfunction

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      sim_cycle   <= 0;
      period_prev <= HDMI_PERIOD_CONTROL;
      period_run  <= 0;
    end else begin
      sim_cycle <= sim_cycle + 1;
      if (w_period != period_prev) begin
        if (sim_cycle > 0)
          $display("  cy=%5d  %-16s  len=%0d",
                   sim_cycle - period_run, period_name(period_prev), period_run);
        period_prev <= w_period;
        period_run  <= 1;
      end else begin
        period_run <= period_run + 1;
      end
    end
  end

  // ── All assertions and period-length checks — single always block ─────────
  int assert_fail_count;
  int data_payload_cnt, data_pre_cnt, data_gb_lead_cnt, data_gb_trail_cnt;
  int video_gb_cnt, video_pre_cnt;

  always @(posedge pix_clk) begin
    if (!rst_n) begin
      data_payload_cnt  = 0;
      data_pre_cnt      = 0;
      data_gb_lead_cnt  = 0;
      data_gb_trail_cnt = 0;
      video_gb_cnt      = 0;
      video_pre_cnt     = 0;
    end else if (sim_cycle > 20) begin

      // ── VIDEO ↔ de_r pipeline alignment ────────────────────────────────
      // period_o is driven from state_next (1-cycle lookahead), so it is
      // offset by exactly 1 cycle vs de_r.  The correct pairing is:
      //   period_o VIDEO  ↔ de_r_d1  (de_r from previous cycle)
      //   period_d1 VIDEO ↔ de_r_d2  (de_r two cycles back)
      // This ensures period_d1 at the channel_mux aligns with the 2-cycle
      // encoder latency, producing correct ch*_o output.
      if (w_period == HDMI_PERIOD_VIDEO && !w_de_r_d1) begin
        $error("ASSERT: period_o VIDEO outside de_r_d1 at cy=%0d", sim_cycle);
        assert_fail_count = assert_fail_count + 1;
      end
      if (w_period_d1 == HDMI_PERIOD_VIDEO && !w_de_r_d2) begin
        $error("ASSERT: period_d1 VIDEO outside de_r_d2 at cy=%0d", sim_cycle);
        assert_fail_count = assert_fail_count + 1;
      end
      if (w_period != HDMI_PERIOD_VIDEO && w_period != HDMI_PERIOD_VIDEO_GB &&
          w_period != HDMI_PERIOD_VIDEO_PREAMBLE && w_de_r) begin
        $error("ASSERT: de_r=1 during %s at cy=%0d",
               period_name(w_period), sim_cycle);
        assert_fail_count = assert_fail_count + 1;
      end

      // ── DATA_PAYLOAD must not overlap de_r ──────────────────────────────
      if (w_period == HDMI_PERIOD_DATA_PAYLOAD && w_de_r) begin
        $error("ASSERT: DATA_PAYLOAD during de_r at cy=%0d", sim_cycle);
        assert_fail_count = assert_fail_count + 1;
      end

      // ── Period-length checkers ───────────────────────────────────────────
      // DATA_PAYLOAD = 32
      if (w_period == HDMI_PERIOD_DATA_PAYLOAD)
        data_payload_cnt = data_payload_cnt + 1;
      else begin
        if (data_payload_cnt != 0 && data_payload_cnt != 32) begin
          $error("ASSERT: DATA_PAYLOAD len=%0d (exp 32) at cy=%0d",
                 data_payload_cnt, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        data_payload_cnt = 0;
      end

      // DATA_PREAMBLE = 8
      if (w_period == HDMI_PERIOD_DATA_PREAMBLE)
        data_pre_cnt = data_pre_cnt + 1;
      else begin
        if (data_pre_cnt != 0 && data_pre_cnt != 8) begin
          $error("ASSERT: DATA_PREAMBLE len=%0d (exp 8) at cy=%0d",
                 data_pre_cnt, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        data_pre_cnt = 0;
      end

      // DATA_GB_LEAD = 2
      if (w_period == HDMI_PERIOD_DATA_GB_LEAD)
        data_gb_lead_cnt = data_gb_lead_cnt + 1;
      else begin
        if (data_gb_lead_cnt != 0 && data_gb_lead_cnt != 2) begin
          $error("ASSERT: DATA_GB_LEAD len=%0d (exp 2) at cy=%0d",
                 data_gb_lead_cnt, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        data_gb_lead_cnt = 0;
      end

      // DATA_GB_TRAIL = 2
      if (w_period == HDMI_PERIOD_DATA_GB_TRAIL)
        data_gb_trail_cnt = data_gb_trail_cnt + 1;
      else begin
        if (data_gb_trail_cnt != 0 && data_gb_trail_cnt != 2) begin
          $error("ASSERT: DATA_GB_TRAIL len=%0d (exp 2) at cy=%0d",
                 data_gb_trail_cnt, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        data_gb_trail_cnt = 0;
      end

      // VIDEO_GB = 2
      if (w_period == HDMI_PERIOD_VIDEO_GB)
        video_gb_cnt = video_gb_cnt + 1;
      else begin
        if (video_gb_cnt != 0 && video_gb_cnt != 2) begin
          $error("ASSERT: VIDEO_GB len=%0d (exp 2) at cy=%0d",
                 video_gb_cnt, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        video_gb_cnt = 0;
      end

      // VIDEO_PREAMBLE = 8
      if (w_period == HDMI_PERIOD_VIDEO_PREAMBLE)
        video_pre_cnt = video_pre_cnt + 1;
      else begin
        if (video_pre_cnt != 0 && video_pre_cnt != 8) begin
          $error("ASSERT: VIDEO_PREAMBLE len=%0d (exp 8) at cy=%0d",
                 video_pre_cnt, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        video_pre_cnt = 0;
      end

    end
  end

  // ── Run control ───────────────────────────────────────────────────────────
  // 4 complete frames = 4 × (V_TOTAL × H_TOTAL) = 4 × 16 × 96 = 6144 cycles
  initial begin
    assert_fail_count = 0;
    $display("=== tb_hdmi_tx_core_32x10: H_TOTAL=%0d V_TOTAL=%0d ===", H_TOTAL, V_TOTAL);
    $display("=== ENABLE_DATA_ISLAND=1, ENABLE_AUDIO=0 ===");
    $display("--- Period transitions (start_cy / period / len) ---");

    wait (rst_n === 1'b1);
    repeat (4 * V_TOTAL * H_TOTAL + 50) @(posedge pix_clk);

    $display("--- End of simulation at cycle %0d ---", sim_cycle);
    $display("");
    if (assert_fail_count == 0)
      $display("ALL ASSERTIONS PASSED");
    else
      $display("FAILED: %0d assertion(s)", assert_fail_count);
    $finish;
  end

endmodule
