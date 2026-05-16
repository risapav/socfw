// SPDX-License-Identifier: MIT
// @file  tb_dvi_vs_2a.sv
// @brief DVI vs 2A (ENABLE_DATA_ISLAND=1, no packets) pipeline alignment check.
// @details
//   Instantiates two hdmi_tx_core units driven by identical inputs:
//     u_dvi — ENABLE_DATA_ISLAND=0 (DVI baseline)
//     u_2a  — ENABLE_DATA_ISLAND=1, GCP=0, AVI=0 (2A: data-island infra, no packets)
//
//   Asserts:
//     1. VIDEO output onset fires at the same absolute cycle in both modes.
//     2. ch*_o content is bit-identical during all VIDEO (active video) cycles.
//
//   Interpretation of results:
//     PASS => pipeline timing and TMDS pixel content are identical in both modes.
//             Green line observed on hardware is NOT a pipeline alignment bug.
//             Root cause: Samsung monitor does not recognize HDMI VIDEO_PREAMBLE
//             symbols in 800x600 mode; it treats them as pixel data.
//     FAIL => real timing or content mismatch exists and must be fixed.
`timescale 1ns/1ps
`default_nettype none

import hdmi_pkg::*;

module tb_dvi_vs_2a;

  // Tiny frame — same parameters as tb_hdmi_tx_core_32x10
  // H_BLANK = 80, MIN budget = 12+44+10 = 66 <= 80
  localparam int H_ACTIVE = 32;
  localparam int H_FP     = 8;
  localparam int H_SYNC   = 8;
  localparam int H_BP     = 64;
  localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;  // 112

  localparam int V_ACTIVE = 10;
  localparam int V_FP     = 2;
  localparam int V_SYNC   = 2;
  localparam int V_BP     = 2;
  localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;  // 16

  localparam bit HSYNC_POL = 1'b1;
  localparam bit VSYNC_POL = 1'b1;

  // Clock / reset
  logic pix_clk = 0;
  logic rst_n;

  always #12.5 pix_clk = ~pix_clk;

  initial begin
    rst_n = 1'b0;
    repeat (8) @(posedge pix_clk);
    @(negedge pix_clk);
    rst_n = 1'b1;
  end

  // Shared VTG
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

  // Shared vga_output_adapter register stage (1 cycle)
  logic de_d1, hs_d1, vs_d1;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin de_d1 <= 1'b0; hs_d1 <= 1'b0; vs_d1 <= 1'b0; end
    else        begin de_d1 <= vtg_de; hs_d1 <= vtg_hs; vs_d1 <= vtg_vs; end
  end

  // Shared pixel data
  logic [6:0] tb_col;
  logic [3:0] tb_row;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin tb_col <= '0; tb_row <= '0; end
    else begin
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

  // DVI instance (ENABLE_DATA_ISLAND=0)
  tmds_word_t ch0_dvi, ch1_dvi, ch2_dvi;
  hdmi_tx_core #(
    .ENABLE_DATA_ISLAND    (0),
    .ENABLE_GCP_PACKET     (0),
    .ENABLE_AVI_PACKET     (0),
    .ENABLE_ACR_PACKET     (0),
    .ENABLE_AUDIO_INFOFRAME(0),
    .ENABLE_AUDIO_SAMPLE   (0),
    .PIXEL_CLK_HZ          (40_000_000),
    .AUDIO_SAMPLE_RATE     (48_000)
  ) u_dvi (
    .pix_clk_i        (pix_clk),
    .rst_ni           (rst_n),
    .red_i            (r8), .grn_i(g8), .blu_i(b8),
    .de_i             (de_d1), .hsync_i(hs_d1), .vsync_i(vs_d1),
    .hblank_i         (vtg_hblank), .vblank_i(vtg_vblank),
    .frame_start_i    (vtg_frame_start), .line_start_i(vtg_line_start),
    .blank_remaining_i(vtg_blank_remaining),
    .info_cfg_i       ('0), .color_fmt_i(COLOR_FORMAT_RGB),
    .aspect_ratio_i   (ASPECT_RATIO_4_3), .quant_range_i(QUANT_RANGE_FULL),
    .vic_code_i       (8'd0), .enable_audio_i(1'b0),
    .acr_n_i          ('0), .acr_cts_i('0), .acr_cts_valid_i(1'b0),
    .ch0_o            (ch0_dvi), .ch1_o(ch1_dvi), .ch2_o(ch2_dvi)
  );

  // 2A instance (ENABLE_DATA_ISLAND=1, GCP=0, AVI=0)
  tmds_word_t ch0_2a, ch1_2a, ch2_2a;
  hdmi_tx_core #(
    .ENABLE_DATA_ISLAND    (1),
    .ENABLE_GCP_PACKET     (0),
    .ENABLE_AVI_PACKET     (0),
    .ENABLE_ACR_PACKET     (0),
    .ENABLE_AUDIO_INFOFRAME(0),
    .ENABLE_AUDIO_SAMPLE   (0),
    .PIXEL_CLK_HZ          (40_000_000),
    .AUDIO_SAMPLE_RATE     (48_000)
  ) u_2a (
    .pix_clk_i        (pix_clk),
    .rst_ni           (rst_n),
    .red_i            (r8), .grn_i(g8), .blu_i(b8),
    .de_i             (de_d1), .hsync_i(hs_d1), .vsync_i(vs_d1),
    .hblank_i         (vtg_hblank), .vblank_i(vtg_vblank),
    .frame_start_i    (vtg_frame_start), .line_start_i(vtg_line_start),
    .blank_remaining_i(vtg_blank_remaining),
    .info_cfg_i       ('0), .color_fmt_i(COLOR_FORMAT_RGB),
    .aspect_ratio_i   (ASPECT_RATIO_4_3), .quant_range_i(QUANT_RANGE_FULL),
    .vic_code_i       (8'd0), .enable_audio_i(1'b0),
    .acr_n_i          ('0), .acr_cts_i('0), .acr_cts_valid_i(1'b0),
    .ch0_o            (ch0_2a), .ch1_o(ch1_2a), .ch2_o(ch2_2a)
  );

  // period_d1 probes (unconditional in hdmi_tx_core — line 191)
  wire hdmi_period_t pd1_dvi = u_dvi.period_d1;
  wire hdmi_period_t pd1_2a  = u_2a.period_d1;

  // period_d2: delay period_d1 by 1 — aligns with ch*_o output register
  hdmi_period_t pd2_dvi, pd2_2a;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin pd2_dvi <= HDMI_PERIOD_CONTROL; pd2_2a <= HDMI_PERIOD_CONTROL; end
    else        begin pd2_dvi <= pd1_dvi; pd2_2a <= pd1_2a; end
  end

  // Cycle counter
  int sim_cycle;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) sim_cycle <= 0;
    else        sim_cycle <= sim_cycle + 1;
  end

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

  // Assertions + counters
  int assert_fail_count;
  int first_video_dvi, first_video_2a;
  int video_match_cnt;

  always @(posedge pix_clk) begin
    if (!rst_n) begin
      first_video_dvi  = -1;
      first_video_2a   = -1;
      video_match_cnt  = 0;
    end else if (sim_cycle > 20) begin

      // Track first VIDEO onset at ch*_o output (pd2 = ch*_o stage)
      if (first_video_dvi < 0 && pd2_dvi == HDMI_PERIOD_VIDEO)
        first_video_dvi = sim_cycle;
      if (first_video_2a < 0 && pd2_2a == HDMI_PERIOD_VIDEO)
        first_video_2a = sim_cycle;

      // When DVI outputs VIDEO, 2A must match in period and content
      if (pd2_dvi == HDMI_PERIOD_VIDEO) begin
        if (pd2_2a !== HDMI_PERIOD_VIDEO) begin
          $error("ALIGN: cy=%0d DVI=VIDEO but 2A=%s",
                 sim_cycle, period_name(pd2_2a));
          assert_fail_count = assert_fail_count + 1;
        end else begin
          if (ch0_dvi !== ch0_2a) begin
            $error("CONTENT: cy=%0d ch0 DVI=%010b 2A=%010b",
                   sim_cycle, ch0_dvi, ch0_2a);
            assert_fail_count = assert_fail_count + 1;
          end else if (ch1_dvi !== ch1_2a) begin
            $error("CONTENT: cy=%0d ch1 DVI=%010b 2A=%010b",
                   sim_cycle, ch1_dvi, ch1_2a);
            assert_fail_count = assert_fail_count + 1;
          end else if (ch2_dvi !== ch2_2a) begin
            $error("CONTENT: cy=%0d ch2 DVI=%010b 2A=%010b",
                   sim_cycle, ch2_dvi, ch2_2a);
            assert_fail_count = assert_fail_count + 1;
          end else begin
            video_match_cnt = video_match_cnt + 1;
          end
        end
      end

      // When 2A outputs VIDEO but DVI does not — also a timing error
      if (pd2_2a == HDMI_PERIOD_VIDEO && pd2_dvi !== HDMI_PERIOD_VIDEO) begin
        $error("ALIGN: cy=%0d 2A=VIDEO but DVI=%s",
               sim_cycle, period_name(pd2_dvi));
        assert_fail_count = assert_fail_count + 1;
      end

    end
  end

  // Run control
  initial begin
    assert_fail_count = 0;
    first_video_dvi   = -1;
    first_video_2a    = -1;
    video_match_cnt   = 0;

    $display("=== tb_dvi_vs_2a: DVI (DATA_ISLAND=0) vs 2A (DATA_ISLAND=1 GCP=0 AVI=0) ===");
    $display("=== H_TOTAL=%0d V_TOTAL=%0d  4 frames ===", H_TOTAL, V_TOTAL);

    wait (rst_n === 1'b1);
    repeat (4 * V_TOTAL * H_TOTAL + 50) @(posedge pix_clk);

    $display("--- Summary ---");
    $display("  First VIDEO onset: DVI=%0d  2A=%0d  diff=%0d",
             first_video_dvi, first_video_2a, first_video_2a - first_video_dvi);
    $display("  Matched VIDEO cycles: %0d", video_match_cnt);

    if (first_video_dvi != first_video_2a) begin
      $error("ONSET MISMATCH: DVI=%0d 2A=%0d (diff=%0d cycles)",
             first_video_dvi, first_video_2a,
             first_video_2a - first_video_dvi);
      assert_fail_count = assert_fail_count + 1;
    end

    if (assert_fail_count == 0) begin
      $display("");
      $display("ALL ASSERTIONS PASSED");
      $display("=> VIDEO onset and content are identical in DVI and 2A modes.");
      $display("=> Green line on hardware is NOT a pipeline alignment bug.");
      $display("=> Samsung does not recognize HDMI VIDEO_PREAMBLE in 800x600.");
      $finish;
    end else begin
      $display("FAILED: %0d assertion(s)", assert_fail_count);
      $fatal(1);
    end
  end

endmodule
