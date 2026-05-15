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
//   3. DATA_PAYLOAD length = 32; ch*_o carries TERC4(di_ch*) cycle-accurately
//   4. DATA_PREAMBLE length = 8; ch1 == PRE_DATA_CH1; ch2 == ctrl(00)
//   5. DATA_GB_{LEAD,TRAIL} length = 2; ch1/ch2 == GB_DATA_N; ch0 == TERC4({1,1,vs,hs})
//   6. VIDEO_PREAMBLE length = 8; ch1 == PRE_VIDEO_CH1; ch2 == ctrl(00)
//   7. VIDEO_GB length = 2; ch1/ch2 == GB_VIDEO
//   8. 2A: no data-island periods when GCP=0 AND AVI=0
//   9. GCP/AVI packet counts match ENABLE_GCP_PACKET / ENABLE_AVI_PACKET
//
// Logs every period transition with cycle count and duration.
//
// Override ENABLE_GCP_PACKET / ENABLE_AVI_PACKET via -G for isolation scenarios:
//   make di_isolation   (runs 2A/2B/2C/2D in sequence)
module tb_hdmi_tx_core_32x10;

  // ── Packet isolation parameters (overridable with vsim -G) ───────────────
  parameter bit ENABLE_GCP_PACKET = 1;
  parameter bit ENABLE_AVI_PACKET = 1;

  // ── Tiny timing parameters ────────────────────────────────────────────────
  // H_BLANK = H_FP+H_SYNC+H_BP = 8+8+64 = 80
  // Needs: MIN_CTRL_PRE_ISLAND(12) + ISLAND_TOTAL(44) + VIDEO_TRIG(10) = 66 <= 80 ✓
  // CONTROL cycles after island: 80-12-44-10 = 14 ✓
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
    .ENABLE_GCP_PACKET     (ENABLE_GCP_PACKET),
    .ENABLE_AVI_PACKET     (ENABLE_AVI_PACKET),
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

  // Formatter nibble outputs (combinational from data_island_formatter)
  wire [3:0] w_di_ch0 = u_dut.gen_data_island.di_ch0;
  wire [3:0] w_di_ch1 = u_dut.gen_data_island.di_ch1;
  wire [3:0] w_di_ch2 = u_dut.gen_data_island.di_ch2;

  // vsync_enc / hsync_enc: 2 cycles after vsync_r in the DUT, already at the
  // channel_mux input phase. One more register aligns with ch*_o output (w_vsync_ch).
  wire w_vsync_enc = u_dut.vsync_enc;
  wire w_hsync_enc = u_dut.hsync_enc;
  logic w_vsync_ch, w_hsync_ch;

  // Pipeline-aligned de_r delays for pipeline-stage assertions.
  // period_o is registered from state_next, so it is 1 cycle behind de_r:
  //   period_o VIDEO = de_r_d1 VIDEO range  (both D+1..D+H_ACTIVE)
  //   period_d1 VIDEO = de_r_d2 VIDEO range (both D+2..D+H_ACTIVE+1)
  logic w_de_r_d1, w_de_r_d2;
  // period_d2: period_d1 delayed by 1 — aligns with ch*_o output stage.
  // When period_d2 == DATA_PAYLOAD the ch*_o bus carries TERC4 payload symbols.
  hdmi_period_t w_period_d2;

  // di_ch* delayed 3 cycles to align with ch*_o.
  // ch*_o = TERC4(di_ch* at T-3), so di_ch*_d3 at cycle T == nibble for ch*_o at T.
  logic [3:0] di_ch0_d1, di_ch0_d2, di_ch0_d3;
  logic [3:0] di_ch1_d1, di_ch1_d2, di_ch1_d3;
  logic [3:0] di_ch2_d1, di_ch2_d2, di_ch2_d3;

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      w_de_r_d1   <= 1'b0;
      w_de_r_d2   <= 1'b0;
      w_period_d2 <= HDMI_PERIOD_CONTROL;
      w_vsync_ch  <= 1'b0;
      w_hsync_ch  <= 1'b0;
      di_ch0_d1  <= '0; di_ch0_d2 <= '0; di_ch0_d3 <= '0;
      di_ch1_d1  <= '0; di_ch1_d2 <= '0; di_ch1_d3 <= '0;
      di_ch2_d1  <= '0; di_ch2_d2 <= '0; di_ch2_d3 <= '0;
    end else begin
      w_de_r_d1   <= w_de_r;
      w_de_r_d2   <= w_de_r_d1;
      w_period_d2 <= w_period_d1;
      w_vsync_ch  <= w_vsync_enc;
      w_hsync_ch  <= w_hsync_enc;
      di_ch0_d1  <= w_di_ch0; di_ch0_d2 <= di_ch0_d1; di_ch0_d3 <= di_ch0_d2;
      di_ch1_d1  <= w_di_ch1; di_ch1_d2 <= di_ch1_d1; di_ch1_d3 <= di_ch1_d2;
      di_ch2_d1  <= w_di_ch2; di_ch2_d2 <= di_ch2_d1; di_ch2_d3 <= di_ch2_d2;
    end
  end

  // Packet arbiter output — to count packet types as they are scheduled
  wire [7:0] w_arb_hb0  = u_dut.gen_data_island.arb_hb[0];
  wire [7:0] w_arb_hb1  = u_dut.gen_data_island.arb_hb[1];
  wire [7:0] w_arb_hb2  = u_dut.gen_data_island.arb_hb[2];
  wire [7:0] w_arb_pb0  = u_dut.gen_data_island.arb_pb[0];
  wire       w_pkt_start = u_dut.packet_start;
  // Formatter BCH parity wires (combinational, valid at packet_start cycle)
  wire [7:0] w_fmt_bch_hdr = u_dut.gen_data_island.u_formatter.bch_hdr;
  wire [7:0] w_fmt_bch_sp0 = u_dut.gen_data_island.u_formatter.bch_sp[0];

  // ── Fixed TMDS symbols — must match hdmi_channel_mux.sv exactly ──────────
  localparam tmds_word_t CTRL_00       = 10'b1101010100;  // ctrl(2'b00)
  localparam tmds_word_t PRE_VIDEO_CH1 = 10'b0010101011;  // ctrl(2'b01) — video preamble ch1
  localparam tmds_word_t PRE_DATA_CH1  = 10'b1010101011;  // ctrl(2'b11) — data preamble ch1
  localparam tmds_word_t GB_VIDEO      = 10'b1011001100;  // TERC4(0x8) — video guard ch1/ch2
  localparam tmds_word_t GB_DATA_N     = 10'b0100110011;  // fixed — data island guard ch1/ch2

  // TERC4 reference LUT — must match terc4_encoder.sv exactly.
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
  int cnt_gcp, cnt_avi;
  int data_payload_cnt, data_pre_cnt, data_gb_lead_cnt, data_gb_trail_cnt;
  int video_gb_cnt, video_pre_cnt;

  always @(posedge pix_clk) begin
    if (!rst_n) begin
      cnt_gcp           = 0;
      cnt_avi           = 0;
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

      // ── DATA_PAYLOAD ch*_o content (period_d2 = output stage) ───────────
      // ch*_o at cycle T == TERC4(di_ch* at cycle T-3).
      // di_ch*_d3 is di_ch* delayed by 3 cycles, so it matches ch*_o now.
      // This catches symbol-0 duplication and other payload misalignments.
      if (w_period_d2 == HDMI_PERIOD_DATA_PAYLOAD) begin
        if (ch0 !== terc4_ref(di_ch0_d3)) begin
          $error("ASSERT: ch0 payload mismatch at cy=%0d: got=%010b exp=%010b (nibble=0x%0h)",
                 sim_cycle, ch0, terc4_ref(di_ch0_d3), di_ch0_d3);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch1 !== terc4_ref(di_ch1_d3)) begin
          $error("ASSERT: ch1 payload mismatch at cy=%0d: got=%010b exp=%010b (nibble=0x%0h)",
                 sim_cycle, ch1, terc4_ref(di_ch1_d3), di_ch1_d3);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch2 !== terc4_ref(di_ch2_d3)) begin
          $error("ASSERT: ch2 payload mismatch at cy=%0d: got=%010b exp=%010b (nibble=0x%0h)",
                 sim_cycle, ch2, terc4_ref(di_ch2_d3), di_ch2_d3);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      // ── DATA_PREAMBLE ch1/ch2 symbols ───────────────────────────────────
      if (w_period_d2 == HDMI_PERIOD_DATA_PREAMBLE) begin
        if (ch1 !== PRE_DATA_CH1) begin
          $error("ASSERT: DATA_PREAMBLE ch1=%010b exp=%010b at cy=%0d",
                 ch1, PRE_DATA_CH1, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch2 !== CTRL_00) begin
          $error("ASSERT: DATA_PREAMBLE ch2=%010b exp=%010b at cy=%0d",
                 ch2, CTRL_00, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      // ── DATA guard band ch0/ch1/ch2 symbols ─────────────────────────────
      if (w_period_d2 == HDMI_PERIOD_DATA_GB_LEAD ||
          w_period_d2 == HDMI_PERIOD_DATA_GB_TRAIL) begin
        if (ch1 !== GB_DATA_N) begin
          $error("ASSERT: DATA_GB ch1=%010b exp=%010b at cy=%0d",
                 ch1, GB_DATA_N, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch2 !== GB_DATA_N) begin
          $error("ASSERT: DATA_GB ch2=%010b exp=%010b at cy=%0d",
                 ch2, GB_DATA_N, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        // ch0 = TERC4({1,1,VSYNC,HSYNC}) per HDMI spec Table 5-4
        begin
          automatic tmds_word_t exp_ch0;
          exp_ch0 = terc4_ref({1'b1, 1'b1, w_vsync_ch, w_hsync_ch});
          if (ch0 !== exp_ch0) begin
            $error("ASSERT: DATA_GB ch0=%010b exp=%010b (vs=%b hs=%b) at cy=%0d",
                   ch0, exp_ch0, w_vsync_ch, w_hsync_ch, sim_cycle);
            assert_fail_count = assert_fail_count + 1;
          end
        end
      end

      // ── VIDEO_PREAMBLE ch1/ch2 symbols ──────────────────────────────────
      if (w_period_d2 == HDMI_PERIOD_VIDEO_PREAMBLE) begin
        if (ch1 !== PRE_VIDEO_CH1) begin
          $error("ASSERT: VIDEO_PREAMBLE ch1=%010b exp=%010b at cy=%0d",
                 ch1, PRE_VIDEO_CH1, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch2 !== CTRL_00) begin
          $error("ASSERT: VIDEO_PREAMBLE ch2=%010b exp=%010b at cy=%0d",
                 ch2, CTRL_00, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      // ── VIDEO_GB ch1/ch2 symbols ─────────────────────────────────────────
      if (w_period_d2 == HDMI_PERIOD_VIDEO_GB) begin
        if (ch1 !== GB_VIDEO) begin
          $error("ASSERT: VIDEO_GB ch1=%010b exp=%010b at cy=%0d",
                 ch1, GB_VIDEO, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
        if (ch2 !== GB_VIDEO) begin
          $error("ASSERT: VIDEO_GB ch2=%010b exp=%010b at cy=%0d",
                 ch2, GB_VIDEO, sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      // ── 2A: no data-island periods when both packets disabled ────────────
      if (!ENABLE_GCP_PACKET && !ENABLE_AVI_PACKET) begin
        if (w_period == HDMI_PERIOD_DATA_PREAMBLE ||
            w_period == HDMI_PERIOD_DATA_GB_LEAD  ||
            w_period == HDMI_PERIOD_DATA_PAYLOAD  ||
            w_period == HDMI_PERIOD_DATA_GB_TRAIL) begin
          $error("ASSERT 2A: data period %s with GCP=0 AVI=0 at cy=%0d",
                 period_name(w_period), sim_cycle);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      // ── Packet content + BCH checks at packet_start ──────────────────────
      if (w_pkt_start) begin
        $display("PKT_START cy=%0d col=%0d row=%0d blank_rem=%0d vblank=%0b hb=%02X %02X %02X",
                 sim_cycle, tb_col, tb_row, vtg_blank_remaining, vtg_vblank,
                 w_arb_hb0, w_arb_hb1, w_arb_hb2);
        if (w_arb_hb0 == 8'h00) begin
          // GCP packet: HB={00,00,00}, PB0=00
          // BCH_HDR for all-zero 3-byte header (init=0xFF) = 0x0E
          // BCH_SP0 for all-zero 7-byte subpacket (init=0xFF) = 0xF5
          cnt_gcp = cnt_gcp + 1;
          $display("  GCP at cy=%0d: HB={%02X %02X %02X} PB0=%02X BCH_HDR=%02X BCH_SP0=%02X",
                   sim_cycle, w_arb_hb0, w_arb_hb1, w_arb_hb2, w_arb_pb0,
                   w_fmt_bch_hdr, w_fmt_bch_sp0);
          if (w_arb_hb1 !== 8'h00) begin
            $error("ASSERT GCP: HB1=0x%02X exp 0x00 at cy=%0d", w_arb_hb1, sim_cycle);
            assert_fail_count = assert_fail_count + 1;
          end
          if (w_arb_hb2 !== 8'h00) begin
            $error("ASSERT GCP: HB2=0x%02X exp 0x00 at cy=%0d", w_arb_hb2, sim_cycle);
            assert_fail_count = assert_fail_count + 1;
          end
          if (w_arb_pb0 !== 8'h00) begin
            $error("ASSERT GCP: PB0=0x%02X exp 0x00 at cy=%0d", w_arb_pb0, sim_cycle);
            assert_fail_count = assert_fail_count + 1;
          end
          if (w_fmt_bch_hdr !== 8'h0E) begin
            $error("ASSERT GCP: BCH_HDR=0x%02X exp 0x0E at cy=%0d", w_fmt_bch_hdr, sim_cycle);
            assert_fail_count = assert_fail_count + 1;
          end
          if (w_fmt_bch_sp0 !== 8'hF5) begin
            $error("ASSERT GCP: BCH_SP0=0x%02X exp 0xF5 at cy=%0d", w_fmt_bch_sp0, sim_cycle);
            assert_fail_count = assert_fail_count + 1;
          end
        end
        if (w_arb_hb0 == 8'h82) cnt_avi = cnt_avi + 1;
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
    cnt_gcp = 0;
    cnt_avi = 0;
    $display("=== tb_hdmi_tx_core_32x10: H_TOTAL=%0d V_TOTAL=%0d ===", H_TOTAL, V_TOTAL);
    $display("=== ENABLE_DATA_ISLAND=1 GCP=%0b AVI=%0b AUDIO=0 ===",
             ENABLE_GCP_PACKET, ENABLE_AVI_PACKET);
    $display("--- Period transitions (start_cy / period / len) ---");

    wait (rst_n === 1'b1);
    repeat (4 * V_TOTAL * H_TOTAL + 50) @(posedge pix_clk);

    $display("--- End of simulation at cycle %0d ---", sim_cycle);
    $display("  GCP packets: %0d  (ENABLE_GCP_PACKET=%0b)", cnt_gcp, ENABLE_GCP_PACKET);
    $display("  AVI packets: %0d  (ENABLE_AVI_PACKET=%0b)", cnt_avi, ENABLE_AVI_PACKET);

    if (ENABLE_GCP_PACKET && cnt_gcp == 0) begin
      $error("ASSERT: GCP enabled but cnt_gcp=0");
      assert_fail_count = assert_fail_count + 1;
    end
    if (!ENABLE_GCP_PACKET && cnt_gcp != 0) begin
      $error("ASSERT: GCP disabled but cnt_gcp=%0d", cnt_gcp);
      assert_fail_count = assert_fail_count + 1;
    end
    if (ENABLE_AVI_PACKET && cnt_avi == 0) begin
      $error("ASSERT: AVI enabled but cnt_avi=0");
      assert_fail_count = assert_fail_count + 1;
    end
    if (!ENABLE_AVI_PACKET && cnt_avi != 0) begin
      $error("ASSERT: AVI disabled but cnt_avi=%0d", cnt_avi);
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
