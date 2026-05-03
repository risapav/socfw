/**
 * @file        vga_hdmi_tx.sv
 * @brief       VGA RGB565 → HDMI TMDS bridge.
 * @details
 * Táto vrstva spája výstup VGA kontroléra (vga_rgb565_stream) s HDMI vysielačom
 * (hdmi_tx_top). Vykonáva:
 *   1. Konverziu RGB565 → RGB888 (rozšírením MSB bitov)
 *   2. Priame prepojenie HS/VS/DE signálov
 *   3. Inštanciu hdmi_tx_top v DDR režime (5× pixel clock)
 *
 * RGB565 → RGB888 konverzia (MSB repeat):
 *   R: {r[4:0], r[4:2]}  — 5 bitov + 3 MSB → 8 bitov
 *   G: {g[5:0], g[5:4]}  — 6 bitov + 2 MSB → 8 bitov
 *   B: {b[4:0], b[4:2]}  — 5 bitov + 3 MSB → 8 bitov
 *
 * @param[in]  clk_i     Pixel clock (napr. 40 MHz pre 800×600 @ 60 Hz)
 * @param[in]  clk_x_i   5× pixel clock pre DDR TMDS serializáciu (napr. 200 MHz)
 * @param[in]  rst_ni    Synchrónny reset aktívny v L (pixel clock doména)
 * @param[in]  vga_r_i   Červená zložka RGB565 [4:0]
 * @param[in]  vga_g_i   Zelená zložka RGB565 [5:0]
 * @param[in]  vga_b_i   Modrá zložka RGB565 [4:0]
 * @param[in]  vga_hs_i  HSYNC z VGA kontroléra
 * @param[in]  vga_vs_i  VSYNC z VGA kontroléra
 * @param[in]  vga_de_i  Data Enable (active_video) z VGA kontroléra
 * @param[out] hdmi_p_o  TMDS výstup — 4 bity (kladné piny dif. párov):
 *                       [0]=Blue, [1]=Green, [2]=Red, [3]=Clock
 */

`ifndef VGA_HDMI_TX_SV
`define VGA_HDMI_TX_SV

`default_nettype none
import hdmi_pkg::*;

module vga_hdmi_tx (
  input  logic        clk_i,
  input  logic        clk_x_i,
  input  logic        rst_ni,

  // VGA výstupy z vga_rgb565_stream
  input  logic [4:0]  vga_r_i,
  input  logic [5:0]  vga_g_i,
  input  logic [4:0]  vga_b_i,
  input  logic        vga_hs_i,
  input  logic        vga_vs_i,
  input  logic        vga_de_i,

  // HDMI TMDS výstup (kladné strany dif. párov)
  output logic [3:0]  hdmi_p_o
);

  // RGB565 → RGB888 (MSB repeat — lineárna aproximácia bez LUT)
  rgb888_t video;
  always_comb begin
    video.red = {vga_r_i,        vga_r_i[4:2]};   // 5b → 8b
    video.grn = {vga_g_i,        vga_g_i[5:4]};   // 6b → 8b
    video.blu = {vga_b_i,        vga_b_i[4:2]};   // 5b → 8b
  end

  hdmi_tx_top #(
    .DDRIO(1)   // DDR: vyžaduje clk_x_i = 5× clk_i
  ) u_hdmi_tx (
    .clk_i         (clk_i),
    .clk_x_i       (clk_x_i),
    .rst_ni        (rst_ni),
    .hsync_i       (vga_hs_i),
    .vsync_i       (vga_vs_i),
    .video_i       (video),
    .video_valid_i (vga_de_i),
    .audio_i       ('0),
    .audio_valid_i (1'b0),
    .packet_i      ('0),
    .packet_valid_i(1'b0),
    .hdmi_p_o      (hdmi_p_o)
  );

endmodule

`endif // VGA_HDMI_TX_SV
