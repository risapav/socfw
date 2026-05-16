`timescale 1ns/1ps
`default_nettype none

import hdmi_pkg::*;

// Black-box TERC4 decode testbench for hdmi_tx_core.
//
// Captures ch0/ch1/ch2 TERC4 output during each DATA_PAYLOAD phase, decodes
// back to packet bytes, and verifies:
//   1. Parity bit: ch0[3] == XOR of (ch0[2:0], ch1[3:0], ch2[3:0]).
//   2. BCH_hdr:    decoded field matches BCH recomputed from HB0-HB2.
//   3. BCH_sp0:    decoded field matches BCH recomputed from PB0-PB6.
//   4. GCP (HB0=0x00):  HB1=HB2=0, all PBx=0, BCH_hdr=0x0E, BCH_sp0=0xF5.
//   5. AVI (HB0=0x82):  sum(HB0..HB2, PB0..PB13) = 0 mod 256.
//
// Channel bit layout (data_island_formatter.sv, symbol period p=0..31):
//   ch0 nibble = { parity, hdr_bit[p], vsync, hsync }
//   ch1 nibble = { sp1[2p+1], sp1[2p], sp0[2p+1], sp0[2p] }
//   ch2 nibble = { sp3[2p+1], sp3[2p], sp2[2p+1], sp2[2p] }
//
// Uses the same 32x10 mini timing as tb_hdmi_tx_core_32x10.
module tb_hdmi_tmds_decode;

  // ── Timing ─────────────────────────────────────────────────────────────
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

  // ── Clock / reset ───────────────────────────────────────────────────────
  logic pix_clk = 0;
  logic rst_n;

  always #12.5 pix_clk = ~pix_clk;

  initial begin
    rst_n = 1'b0;
    repeat (8) @(posedge pix_clk);
    @(negedge pix_clk);
    rst_n = 1'b1;
  end

  // ── Mini VTG ────────────────────────────────────────────────────────────
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

  // ── vga_output_adapter pipeline stage ──────────────────────────────────
  logic de_d1, hs_d1, vs_d1;

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      de_d1 <= 1'b0; hs_d1 <= 1'b0; vs_d1 <= 1'b0;
    end else begin
      de_d1 <= vtg_de; hs_d1 <= vtg_hs; vs_d1 <= vtg_vs;
    end
  end

  // ── Pixel data ──────────────────────────────────────────────────────────
  logic [6:0] tb_col;
  logic [3:0] tb_row;

  always_ff @(posedge pix_clk) begin
    if (!rst_n) begin
      tb_col <= '0; tb_row <= '0;
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

  // ── DUT ─────────────────────────────────────────────────────────────────
  tmds_word_t ch0, ch1, ch2;

  hdmi_tx_core #(
    .ENABLE_DATA_ISLAND    (1),
    .ENABLE_GCP_PACKET     (1),
    .ENABLE_AVI_PACKET     (1),
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

  // ── Period probes (align with ch*_o — identical to tb_hdmi_tx_core_32x10) ─
  wire hdmi_period_t w_period_d1 = u_dut.period_d1;

  hdmi_period_t w_period_d2;
  always_ff @(posedge pix_clk) begin
    if (!rst_n) w_period_d2 <= HDMI_PERIOD_CONTROL;
    else        w_period_d2 <= w_period_d1;
  end

  // ── TERC4 reverse LUT ───────────────────────────────────────────────────
  function automatic logic [3:0] terc4_decode(input tmds_word_t w);
    case (w)
      10'b1010011100: return 4'h0;
      10'b1001100011: return 4'h1;
      10'b1011100100: return 4'h2;
      10'b1011100010: return 4'h3;
      10'b0101110001: return 4'h4;
      10'b0100011110: return 4'h5;
      10'b0110001110: return 4'h6;
      10'b0100111100: return 4'h7;
      10'b1011001100: return 4'h8;
      10'b0100111001: return 4'h9;
      10'b0110011100: return 4'ha;
      10'b1011000110: return 4'hb;
      10'b1010001110: return 4'hc;
      10'b1001110001: return 4'hd;
      10'b0101100011: return 4'he;
      10'b1011000011: return 4'hf;
      default:        return 4'hx;
    endcase
  endfunction

  // ── BCH ECC functions (match hdmi_bch_ecc.sv) ───────────────────────────
  // Polynomial x^8+x^4+x^3+x^2+1, init 0xFF, data processed LSB-first per byte.
  function automatic logic [7:0] bch_hdr_compute(
    input logic [7:0] hb0, hb1, hb2
  );
    logic [7:0]  lfsr;
    logic [23:0] d;
    lfsr = 8'hFF;
    d    = {hb2, hb1, hb0};
    for (int i = 0; i < 24; i++) begin
      if (d[i] ^ lfsr[7]) lfsr = {lfsr[6:0], 1'b0} ^ 8'h1D;
      else                 lfsr = {lfsr[6:0], 1'b0};
    end
    return lfsr;
  endfunction

  function automatic logic [7:0] bch_sp_compute(input logic [7:0] pb[7]);
    logic [7:0] lfsr;
    lfsr = 8'hFF;
    for (int b = 0; b < 7; b++) begin
      for (int i = 0; i < 8; i++) begin
        if (pb[b][i] ^ lfsr[7]) lfsr = {lfsr[6:0], 1'b0} ^ 8'h1D;
        else                     lfsr = {lfsr[6:0], 1'b0};
      end
    end
    return lfsr;
  endfunction

  // ── Packet capture storage ──────────────────────────────────────────────
  int          pkt_sym;
  logic [31:0] hdr_cap;     // header stream: [7:0]=HB0 [15:8]=HB1 [23:16]=HB2 [31:24]=BCH_hdr
  logic [63:0] sp_cap[4];   // subpacket streams: [55:0]=PB data [63:56]=BCH_sp

  int          assert_fail_count;
  int          cnt_gcp, cnt_avi, cnt_gb;

  // ── Packet verification ─────────────────────────────────────────────────
  task automatic verify_packet();
    logic [7:0]  HB[3];
    logic [7:0]  PB[28];
    logic [7:0]  bch_hdr_dec, bch_hdr_exp;
    logic [7:0]  bch_sp_dec[4], bch_sp0_exp;
    logic [7:0]  pb_sp[7];
    logic [15:0] chksum;

    HB[0] = hdr_cap[7:0];
    HB[1] = hdr_cap[15:8];
    HB[2] = hdr_cap[23:16];
    bch_hdr_dec = hdr_cap[31:24];

    for (int k = 0; k < 4; k++) begin
      for (int j = 0; j < 7; j++)
        PB[7*k+j] = sp_cap[k][8*j +: 8];
      bch_sp_dec[k] = sp_cap[k][63:56];
    end

    // Verify header BCH
    bch_hdr_exp = bch_hdr_compute(HB[0], HB[1], HB[2]);
    if (bch_hdr_dec !== bch_hdr_exp) begin
      $error("BCH_hdr: decoded=0x%02X computed=0x%02X HB={%02X %02X %02X}",
             bch_hdr_dec, bch_hdr_exp, HB[0], HB[1], HB[2]);
      assert_fail_count = assert_fail_count + 1;
    end

    // Verify subpacket-0 BCH
    for (int j = 0; j < 7; j++) pb_sp[j] = PB[j];
    bch_sp0_exp = bch_sp_compute(pb_sp);
    if (bch_sp_dec[0] !== bch_sp0_exp) begin
      $error("BCH_sp0: decoded=0x%02X computed=0x%02X PB0=0x%02X",
             bch_sp_dec[0], bch_sp0_exp, PB[0]);
      assert_fail_count = assert_fail_count + 1;
    end

    case (HB[0])
      8'h00: begin  // GCP
        cnt_gcp = cnt_gcp + 1;
        $display("PKT_DEC GCP #%0d  HB={%02X %02X %02X}  BCH_hdr=%02X  BCH_sp0=%02X",
                 cnt_gcp, HB[0], HB[1], HB[2], bch_hdr_dec, bch_sp_dec[0]);
        if (HB[1] !== 8'h00 || HB[2] !== 8'h00) begin
          $error("GCP: HB1=0x%02X HB2=0x%02X (exp 0x00)", HB[1], HB[2]);
          assert_fail_count = assert_fail_count + 1;
        end
        for (int i = 0; i < 28; i++) begin
          if (PB[i] !== 8'h00) begin
            $error("GCP: PB[%0d]=0x%02X (exp 0x00)", i, PB[i]);
            assert_fail_count = assert_fail_count + 1;
          end
        end
        if (bch_hdr_dec !== 8'h0E) begin
          $error("GCP: BCH_hdr=0x%02X (exp 0x0E)", bch_hdr_dec);
          assert_fail_count = assert_fail_count + 1;
        end
        if (bch_sp_dec[0] !== 8'hF5) begin
          $error("GCP: BCH_sp0=0x%02X (exp 0xF5)", bch_sp_dec[0]);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      8'h82: begin  // AVI InfoFrame
        cnt_avi = cnt_avi + 1;
        $display("PKT_DEC AVI #%0d  HB={%02X %02X %02X}  PB0=0x%02X PB1=0x%02X",
                 cnt_avi, HB[0], HB[1], HB[2], PB[0], PB[1]);
        chksum = 16'h0;
        chksum += {8'h0, HB[0]};
        chksum += {8'h0, HB[1]};
        chksum += {8'h0, HB[2]};
        for (int i = 0; i < 14; i++)
          chksum += {8'h0, PB[i]};
        if (chksum[7:0] !== 8'h00) begin
          $error("AVI checksum FAIL: sum=0x%04X (exp 0x00xx00) PB0=0x%02X PB1=0x%02X",
                 chksum, PB[0], PB[1]);
          assert_fail_count = assert_fail_count + 1;
        end
      end

      default: begin
        $display("PKT_DEC HB0=0x%02X (unverified packet type)", HB[0]);
      end
    endcase
  endtask

  // ── Decode nibbles at module level (avoid always-block local decl) ──────
  logic [3:0] dec_n0, dec_n1, dec_n2;
  logic       dec_parity;

  // ── Cycle-by-cycle TERC4 decode ─────────────────────────────────────────
  always @(posedge pix_clk) begin
    if (!rst_n) begin
      pkt_sym = 0;
    end else if (w_period_d2 == HDMI_PERIOD_DATA_PAYLOAD) begin
      dec_n0 = terc4_decode(ch0);
      dec_n1 = terc4_decode(ch1);
      dec_n2 = terc4_decode(ch2);

      // Parity: ch0[3] = XOR of the 8 data bits in this symbol
      dec_parity = dec_n0[2] ^ dec_n0[1] ^ dec_n0[0]
                 ^ dec_n1[3] ^ dec_n1[2] ^ dec_n1[1] ^ dec_n1[0]
                 ^ dec_n2[3] ^ dec_n2[2] ^ dec_n2[1] ^ dec_n2[0];
      if (dec_n0[3] !== dec_parity) begin
        $error("TERC4 parity fail sym=%0d  n0=%04b  exp_p=%b  ch0=%010b",
               pkt_sym, dec_n0, dec_parity, ch0);
        assert_fail_count = assert_fail_count + 1;
      end

      // Capture header stream bit (ch0[2] = hdr_bit per formatter spec)
      hdr_cap[pkt_sym] = dec_n0[2];

      // Capture subpacket stream bits
      sp_cap[0][2*pkt_sym]   = dec_n1[0];
      sp_cap[0][2*pkt_sym+1] = dec_n1[1];
      sp_cap[1][2*pkt_sym]   = dec_n1[2];
      sp_cap[1][2*pkt_sym+1] = dec_n1[3];
      sp_cap[2][2*pkt_sym]   = dec_n2[0];
      sp_cap[2][2*pkt_sym+1] = dec_n2[1];
      sp_cap[3][2*pkt_sym]   = dec_n2[2];
      sp_cap[3][2*pkt_sym+1] = dec_n2[3];

      pkt_sym = pkt_sym + 1;
      if (pkt_sym == 32) begin
        verify_packet();
        pkt_sym = 0;
      end
    end else if (w_period_d2 == HDMI_PERIOD_DATA_GB_LEAD ||
                 w_period_d2 == HDMI_PERIOD_DATA_GB_TRAIL) begin
      // HDMI 1.3 Table 5-8: Ch2=TERC4(4'hB), Ch1=TERC4(4'h4),
      // Ch0=TERC4({1,1,VSYNC,HSYNC})
      if (ch2 !== 10'b1011000110) begin
        $error("DATA_GB ch2=0b%010b exp TERC4(4'hB)=0b1011000110", ch2);
        assert_fail_count = assert_fail_count + 1;
      end
      if (ch1 !== 10'b0101110001) begin
        $error("DATA_GB ch1=0b%010b exp TERC4(4'h4)=0b0101110001", ch1);
        assert_fail_count = assert_fail_count + 1;
      end
      if (ch0 !== 10'b1010001110 && ch0 !== 10'b1001110001 &&
          ch0 !== 10'b0101100011 && ch0 !== 10'b1011000011) begin
        $error("DATA_GB ch0=0b%010b not a valid TERC4({1,1,VSYNC,HSYNC})", ch0);
        assert_fail_count = assert_fail_count + 1;
      end
      cnt_gb = cnt_gb + 1;
      pkt_sym = 0;
    end else begin
      pkt_sym = 0;
    end
  end

  // ── Run control ─────────────────────────────────────────────────────────
  initial begin
    assert_fail_count = 0;
    cnt_gcp           = 0;
    cnt_avi           = 0;
    cnt_gb            = 0;
    $display("=== tb_hdmi_tmds_decode: TERC4 black-box decode, GCP+AVI ===");

    wait (rst_n === 1'b1);
    repeat (4 * V_TOTAL * H_TOTAL + 50) @(posedge pix_clk);

    $display("--- GCP decoded: %0d  AVI decoded: %0d  guard bands: %0d ---",
             cnt_gcp, cnt_avi, cnt_gb);

    if (cnt_gcp == 0) begin
      $error("No GCP packets decoded"); assert_fail_count = assert_fail_count + 1;
    end
    if (cnt_avi == 0) begin
      $error("No AVI packets decoded"); assert_fail_count = assert_fail_count + 1;
    end
    if (cnt_gb == 0) begin
      $error("No data island guard bands seen"); assert_fail_count = assert_fail_count + 1;
    end

    if (assert_fail_count == 0) begin
      $display("ALL ASSERTIONS PASSED");
      $finish;
    end else begin
      $display("FAILED: %0d assertion(s)", assert_fail_count);
      $fatal(1);
    end
  end

endmodule
