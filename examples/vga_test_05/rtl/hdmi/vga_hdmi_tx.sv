`ifndef VGA_HDMI_TX_SV
`define VGA_HDMI_TX_SV

`default_nettype none

import hdmi_pkg::*;

// RGB565 VGA stream → HDMI bridge.
//
// Accepts RGB565 + HS/VS/DE + explicit blanking signals from video_timing_generator.
// Internally converts RGB565 → RGB888 (MSB-repeat) and feeds hdmi_tx_core.
//
// Explicit timing inputs (hblank_i, vblank_i, frame_start_i, blank_remaining_i)
// replace the incorrect vblank=vsync derivation in hdmi_tx_core.  The period
// scheduler uses blank_remaining_i to guard data island insertion.
//
// RGB565 → RGB888:
//   R: {r[4:0], r[4:2]}
//   G: {g[5:0], g[5:4]}
//   B: {b[4:0], b[4:2]}
module vga_hdmi_tx #(
  parameter bit ENABLE_DATA_ISLAND = 0
)(
  input  logic       clk_i,    // pixel clock
  input  logic       clk_x_i,  // 5× pixel clock (DDR serializer)
  input  logic       rst_ni,

  // Individual RGB565 + sync signals
  input  logic [4:0] vga_r_i,
  input  logic [5:0] vga_g_i,
  input  logic [4:0] vga_b_i,
  input  logic       vga_hs_i,
  input  logic       vga_vs_i,
  input  logic       vga_de_i,

  // Explicit blanking timing from video_timing_generator
  input  logic        hblank_i,          // horizontal blank
  input  logic        vblank_i,          // vertical blank
  input  logic        frame_start_i,     // first pixel of each frame
  input  logic [15:0] blank_remaining_i, // cycles until next active video

  // HDMI TMDS output (positive side of differential pairs)
  // [0]=Blue, [1]=Green, [2]=Red, [3]=Clock
  output logic [3:0] hdmi_p_o
);

  // ── RGB565 → RGB888 ────────────────────────────────────────────────────────
  wire [7:0] r8 = {vga_r_i, vga_r_i[4:2]};
  wire [7:0] g8 = {vga_g_i, vga_g_i[5:4]};
  wire [7:0] b8 = {vga_b_i, vga_b_i[4:2]};

  // ── HDMI TX core → 10-bit TMDS words ──────────────────────────────────────
  tmds_word_t ch0, ch1, ch2;

  hdmi_tx_core #(
    .ENABLE_DATA_ISLAND(ENABLE_DATA_ISLAND)
  ) u_core (
    .pix_clk_i        (clk_i),
    .rst_ni           (rst_ni),
    .red_i            (r8),
    .grn_i            (g8),
    .blu_i            (b8),
    .de_i             (vga_de_i),
    .hsync_i          (vga_hs_i),
    .vsync_i          (vga_vs_i),
    .hblank_i         (hblank_i),
    .vblank_i         (vblank_i),
    .frame_start_i    (frame_start_i),
    .blank_remaining_i(blank_remaining_i),
    .info_cfg_i       ('0),
    .color_fmt_i      (COLOR_FORMAT_RGB),
    .aspect_ratio_i   (ASPECT_RATIO_4_3),
    .quant_range_i    (QUANT_RANGE_FULL),
    .vic_code_i       (8'd0),
    .ch0_o            (ch0),
    .ch1_o            (ch1),
    .ch2_o            (ch2)
  );

  // ── PHY: word-aligned DDR serializer (ch0=B, ch1=G, ch2=R, ch3=CLK) ──────
  localparam tmds_word_t TMDS_CLK = 10'b1111100000;

  tmds_phy_ddr_aligned u_phy (
    .clk_x_i  (clk_x_i),
    .rst_ni   (rst_ni),
    .ch0_i    (ch0),
    .ch1_i    (ch1),
    .ch2_i    (ch2),
    .clk_ch_i (TMDS_CLK),
    .hdmi_p_o (hdmi_p_o)
  );

endmodule

`endif
