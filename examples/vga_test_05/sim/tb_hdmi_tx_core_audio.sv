`timescale 1ns/1ps
`default_nettype none

import hdmi_pkg::*;

// Parameterised testbench for hdmi_tx_core audio packet scenarios.
//
// Runs the same 32x10 mini-mode as tb_hdmi_tx_core_32x10 but with
// enable_audio_i=1.  Override parameters at sim time via vsim -G:
//
//   vsim -G ENABLE_ACR_PACKET=1 -G ENABLE_AUDIO_INFOFRAME=0 -G ENABLE_AUDIO_SAMPLE=0
//        -c -do "run -all; quit" tb_hdmi_tx_core_audio
//
// For every data island the test verifies:
//   1. DATA_PAYLOAD length = 32.
//   2. ch*_o during DATA_PAYLOAD = TERC4(formatter nibble delayed 3 cycles).
//   3. No DATA_PAYLOAD cycle overlaps de_r.
//   4. VIDEO_PREAMBLE = 8, VIDEO_GB = 2.
//
// Additionally counts islands per HB0 packet type and asserts:
//   - Enabled packet types appear at least once.
//   - Disabled packet types never appear.
//   - GCP and AVI always appear (unconditional per-frame sequence).
module tb_hdmi_tx_core_audio #(
  parameter bit ENABLE_ACR_PACKET      = 1,
  parameter bit ENABLE_AUDIO_INFOFRAME = 1,
  parameter bit ENABLE_AUDIO_SAMPLE    = 1
);

  // ── 32x10 timing ────────────────────────────────────────────────────────
  // H_BLANK = H_FP+H_SYNC+H_BP = 8+8+64 = 80
  // Needs: MIN_CTRL_PRE_ISLAND(12) + ISLAND_TOTAL(44) + VIDEO_TRIG(10) = 66 <= 80 ✓
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

  // 8 frames: enough for arbiter to cycle GCP->AVI->ACR->AudioIF->Sample.
  localparam int N_FRAMES = 8;

  // HB0 type codes
  localparam logic [7:0] HB0_GCP      = 8'h00;  // our GCP builder uses 0x00
  localparam logic [7:0] HB0_ACR      = 8'h01;
  localparam logic [7:0] HB0_SAMPLE   = 8'h02;
  localparam logic [7:0] HB0_AVI      = 8'h82;
  localparam logic [7:0] HB0_AUDIO_IF = 8'h84;

  // ── Clock / reset ────────────────────────────────────────────────────────
  logic pix_clk = 0;
  logic rst_n;

  always #12.5 pix_clk = ~pix_clk;  // 40 MHz

  initial begin
    rst_n = 1'b0;
    repeat (8) @(posedge pix_clk);
    @(negedge pix_clk);
    rst_n = 1'b1;
  end

  // ── Mini VTG ─────────────────────────────────────────────────────────────
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

  // ── Simulate vga_output_adapter register stage ───────────────────────────
  logic de_d1, hs_d1, vs_d1;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      de_d1 <= 1'b0; hs_d1 <= 1'b0; vs_d1 <= 1'b0;
    end else begin
      de_d1 <= vtg_de; hs_d1 <= vtg_hs; vs_d1 <= vtg_vs;
    end
  end

  // ── Pixel data ───────────────────────────────────────────────────────────
  logic [6:0] tb_col;
  logic [3:0] tb_row;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      tb_col <= '0; tb_row <= '0;
    end else begin
      if (tb_col == H_TOTAL - 1) begin
        tb_col <= '0;
        tb_row <= (tb_row == V_TOTAL - 1) ? '0 : tb_row + 1'b1;
      end else
        tb_col <= tb_col + 1'b1;
    end
  end
  wire [7:0] r8 = {1'b0, tb_col};
  wire [7:0] g8 = {4'h0, tb_row};
  wire [7:0] b8 = 8'hAA;

  // ── DUT ──────────────────────────────────────────────────────────────────
  tmds_word_t ch0, ch1, ch2;

  hdmi_tx_core #(
    .ENABLE_DATA_ISLAND    (1),
    .ENABLE_ACR_PACKET     (ENABLE_ACR_PACKET),
    .ENABLE_AUDIO_INFOFRAME(ENABLE_AUDIO_INFOFRAME),
    .ENABLE_AUDIO_SAMPLE   (ENABLE_AUDIO_SAMPLE),
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
    .enable_audio_i   (1'b1),
    .acr_n_i          (20'd6144),
    .acr_cts_i        (20'd40000),
    .acr_cts_valid_i  (1'b1),
    .ch0_o            (ch0),
    .ch1_o            (ch1),
    .ch2_o            (ch2)
  );

  // ── Signal probes ─────────────────────────────────────────────────────────
  wire hdmi_period_t w_period    = u_dut.period;
  wire hdmi_period_t w_period_d1 = u_dut.period_d1;
  wire               w_de_r      = u_dut.de_r;
  wire               w_pkt_start = u_dut.packet_start;
  wire [7:0]         w_arb_hb0   = u_dut.gen_data_island.arb_hb[0];

  wire [3:0] w_di_ch0 = u_dut.gen_data_island.di_ch0;
  wire [3:0] w_di_ch1 = u_dut.gen_data_island.di_ch1;
  wire [3:0] w_di_ch2 = u_dut.gen_data_island.di_ch2;

  // Pipeline delay chain (mirrors tb_hdmi_tx_core_32x10)
  logic w_de_r_d1, w_de_r_d2;
  hdmi_period_t w_period_d2;
  logic [3:0] di_ch0_d1, di_ch0_d2, di_ch0_d3;
  logic [3:0] di_ch1_d1, di_ch1_d2, di_ch1_d3;
  logic [3:0] di_ch2_d1, di_ch2_d2, di_ch2_d3;

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      w_de_r_d1 <= 1'b0; w_de_r_d2 <= 1'b0;
      w_period_d2 <= HDMI_PERIOD_CONTROL;
      di_ch0_d1 <= '0; di_ch0_d2 <= '0; di_ch0_d3 <= '0;
      di_ch1_d1 <= '0; di_ch1_d2 <= '0; di_ch1_d3 <= '0;
      di_ch2_d1 <= '0; di_ch2_d2 <= '0; di_ch2_d3 <= '0;
    end else begin
      w_de_r_d1 <= w_de_r;   w_de_r_d2 <= w_de_r_d1;
      w_period_d2 <= w_period_d1;
      di_ch0_d1 <= w_di_ch0; di_ch0_d2 <= di_ch0_d1; di_ch0_d3 <= di_ch0_d2;
      di_ch1_d1 <= w_di_ch1; di_ch1_d2 <= di_ch1_d1; di_ch1_d3 <= di_ch1_d2;
      di_ch2_d1 <= w_di_ch2; di_ch2_d2 <= di_ch2_d1; di_ch2_d3 <= di_ch2_d2;
    end
  end

  // TERC4 reference LUT
  function automatic tmds_word_t terc4_ref(input logic [3:0] n);
    case (n)
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

  // ── Cycle counter ─────────────────────────────────────────────────────────
  int sim_cycle;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) sim_cycle <= 0;
    else        sim_cycle <= sim_cycle + 1;
  end

  // ── Assertions and packet counting ────────────────────────────────────────
  int assert_fail_count;
  int island_count;
  int cnt_gcp, cnt_avi, cnt_acr, cnt_audio_if, cnt_sample;
  int data_payload_cnt, data_pre_cnt, data_gb_lead_cnt, data_gb_trail_cnt;
  int video_gb_cnt, video_pre_cnt;

  always @(posedge pix_clk) begin
    if (!rst_n) begin
      island_count      = 0;
      cnt_gcp           = 0;
      cnt_avi           = 0;
      cnt_acr           = 0;
      cnt_audio_if      = 0;
      cnt_sample        = 0;
      data_payload_cnt  = 0;
      data_pre_cnt      = 0;
      data_gb_lead_cnt  = 0;
      data_gb_trail_cnt = 0;
      video_gb_cnt      = 0;
      video_pre_cnt     = 0;
    end else if (sim_cycle > 20) begin

      // ── Packet type accounting ──────────────────────────────────────────
      if (w_pkt_start) begin
        island_count = island_count + 1;
        case (w_arb_hb0)
          HB0_GCP:      cnt_gcp      = cnt_gcp      + 1;
          HB0_AVI:      cnt_avi      = cnt_avi      + 1;
          HB0_ACR:      cnt_acr      = cnt_acr      + 1;
          HB0_AUDIO_IF: cnt_audio_if = cnt_audio_if + 1;
          HB0_SAMPLE:   cnt_sample   = cnt_sample   + 1;
          default: ;
        endcase
      end

      // ── DATA_PAYLOAD must not overlap de_r ──────────────────────────────
      if (w_period == HDMI_PERIOD_DATA_PAYLOAD && w_de_r) begin
        $error("ASSERT: DATA_PAYLOAD during de_r at cy=%0d", sim_cycle);
        assert_fail_count = assert_fail_count + 1;
      end

      // ── ch*_o payload content (period_d2 = output stage) ────────────────
      if (w_period_d2 == HDMI_PERIOD_DATA_PAYLOAD) begin
        if (ch0 !== terc4_ref(di_ch0_d3)) begin
          $error("ASSERT: ch0 mismatch cy=%0d got=%010b exp=%010b (nib=0x%0h)",
                 sim_cycle, ch0, terc4_ref(di_ch0_d3), di_ch0_d3);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch1 !== terc4_ref(di_ch1_d3)) begin
          $error("ASSERT: ch1 mismatch cy=%0d got=%010b exp=%010b (nib=0x%0h)",
                 sim_cycle, ch1, terc4_ref(di_ch1_d3), di_ch1_d3);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch2 !== terc4_ref(di_ch2_d3)) begin
          $error("ASSERT: ch2 mismatch cy=%0d got=%010b exp=%010b (nib=0x%0h)",
                 sim_cycle, ch2, terc4_ref(di_ch2_d3), di_ch2_d3);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      // ── Period length checks ────────────────────────────────────────────
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
  initial begin
    assert_fail_count = 0;
    $display("=== tb_hdmi_tx_core_audio: ACR=%0b IF=%0b SAMPLE=%0b ===",
             ENABLE_ACR_PACKET, ENABLE_AUDIO_INFOFRAME, ENABLE_AUDIO_SAMPLE);

    wait (rst_n === 1'b1);
    repeat (N_FRAMES * V_TOTAL * H_TOTAL + 50) @(posedge pix_clk);

    $display("--- Packet counts after %0d frames (H=%0d V=%0d) ---",
             N_FRAMES, H_TOTAL, V_TOTAL);
    $display("  GCP:       %0d (always expected >= 1)", cnt_gcp);
    $display("  AVI:       %0d (always expected >= 1)", cnt_avi);
    $display("  ACR:       %0d (enabled=%0b)", cnt_acr,      ENABLE_ACR_PACKET);
    $display("  Audio IF:  %0d (enabled=%0b)", cnt_audio_if, ENABLE_AUDIO_INFOFRAME);
    $display("  Sample:    %0d (enabled=%0b)", cnt_sample,   ENABLE_AUDIO_SAMPLE);
    $display("  Total:     %0d islands", island_count);

    // GCP and AVI are always sent once per frame.
    // Allow N_FRAMES-1 minimum: on a frame boundary the arbiter preempts any
    // in-progress AVI/ACR sequence with a new GCP, so the last frame of the
    // window may miss AVI/ACR if GCP fires on its final hblank slot.
    if (cnt_gcp < N_FRAMES - 1) begin
      $error("FAIL: GCP count=%0d (expected >= %0d)", cnt_gcp, N_FRAMES - 1);
      assert_fail_count = assert_fail_count + 1;
    end
    if (cnt_avi < N_FRAMES - 1) begin
      $error("FAIL: AVI count=%0d (expected >= %0d)", cnt_avi, N_FRAMES - 1);
      assert_fail_count = assert_fail_count + 1;
    end
    // Enabled audio packet types must appear at least once
    if (ENABLE_ACR_PACKET && cnt_acr < 1) begin
      $error("FAIL: ACR never sent with ENABLE_ACR_PACKET=1");
      assert_fail_count = assert_fail_count + 1;
    end
    if (ENABLE_AUDIO_INFOFRAME && cnt_audio_if < 1) begin
      $error("FAIL: AudioIF never sent with ENABLE_AUDIO_INFOFRAME=1");
      assert_fail_count = assert_fail_count + 1;
    end
    if (ENABLE_AUDIO_SAMPLE && cnt_sample < 1) begin
      $error("FAIL: Sample never sent with ENABLE_AUDIO_SAMPLE=1");
      assert_fail_count = assert_fail_count + 1;
    end
    // Disabled audio packet types must not appear
    if (!ENABLE_ACR_PACKET && cnt_acr > 0) begin
      $error("FAIL: ACR sent %0d times with ENABLE_ACR_PACKET=0", cnt_acr);
      assert_fail_count = assert_fail_count + 1;
    end
    if (!ENABLE_AUDIO_INFOFRAME && cnt_audio_if > 0) begin
      $error("FAIL: AudioIF sent %0d times with ENABLE_AUDIO_INFOFRAME=0", cnt_audio_if);
      assert_fail_count = assert_fail_count + 1;
    end
    if (!ENABLE_AUDIO_SAMPLE && cnt_sample > 0) begin
      $error("FAIL: Sample sent %0d times with ENABLE_AUDIO_SAMPLE=0", cnt_sample);
      assert_fail_count = assert_fail_count + 1;
    end

    $display("");
    if (assert_fail_count == 0) begin
      $display("ALL ASSERTIONS PASSED");
      $finish;
    end else begin
      $display("FAILED: %0d assertion(s)", assert_fail_count);
      $fatal(1);
    end
  end

endmodule
