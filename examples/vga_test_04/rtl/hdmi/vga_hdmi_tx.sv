`ifndef VGA_HDMI_TX_SV
`define VGA_HDMI_TX_SV

`default_nettype none

import hdmi_pkg::*;

// RGB565 VGA stream → HDMI bridge.
//
// Accepts the same individual pin interface as the old vga_rgb565_stream output
// so that the auto-generated soc_top.sv does not need to change.
//
// Internally converts RGB565 → RGB888 (MSB-repeat) and feeds hdmi_tx_core,
// then passes the 3×10-bit TMDS words to the generic_serializer PHY.
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

  // Individual RGB565 + sync signals (matches old port interface)
  input  logic [4:0] vga_r_i,
  input  logic [5:0] vga_g_i,
  input  logic [4:0] vga_b_i,
  input  logic       vga_hs_i,
  input  logic       vga_vs_i,
  input  logic       vga_de_i,

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
    .pix_clk_i     (clk_i),
    .rst_ni        (rst_ni),
    .red_i         (r8),
    .grn_i         (g8),
    .blu_i         (b8),
    .de_i          (vga_de_i),
    .hsync_i       (vga_hs_i),
    .vsync_i       (vga_vs_i),
    .info_cfg_i    ('0),
    .color_fmt_i   (COLOR_FORMAT_RGB),
    .aspect_ratio_i(ASPECT_RATIO_4_3),
    .quant_range_i (QUANT_RANGE_FULL),
    .vic_code_i    (8'd0),
    .ch0_o         (ch0),
    .ch1_o         (ch1),
    .ch2_o         (ch2)
  );

  // ── PHY: 4-channel serializer (ch0=B, ch1=G, ch2=R, ch3=CLK) ─────────────
  localparam tmds_word_t TMDS_CLK = 10'b1111100000;

  logic [9:0] phy_words [4];
  assign phy_words[0] = ch0;
  assign phy_words[1] = ch1;
  assign phy_words[2] = ch2;
  assign phy_words[3] = TMDS_CLK;

  logic data_req;
  logic hdmi_p_unpacked [4];
  assign hdmi_p_o = {hdmi_p_unpacked[3], hdmi_p_unpacked[2],
                     hdmi_p_unpacked[1], hdmi_p_unpacked[0]};

  generic_serializer #(
    .DDRIO           (1),
    .NUM_PHY_CHANNELS(4),
    .WORD_WIDTH      (10),
    .LSB_FIRST       (1),
    .IDLE_WORD       ('0)
  ) u_phy (
    .rst_ni        (rst_ni),
    .enable_i      (1'b1),
    .clk_i         (clk_i),
    .clk_x_i       (clk_x_i),
    .word_i        (phy_words),
    .data_request_o(data_req),
    .phys_o        (hdmi_p_unpacked)
  );

endmodule

`endif
