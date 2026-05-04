`default_nettype none

import video_pkg::*;

// Registered RGB565 → VGA physical output adapter.
// Simply drives VGA pins from the timed video stream.
module vga_output_adapter (
  input  logic clk_i,
  input  logic rst_ni,

  input  rgb565_t pixel_i,
  input  logic    de_i,
  input  logic    hsync_i,
  input  logic    vsync_i,

  output logic [4:0] vga_r_o,
  output logic [5:0] vga_g_o,
  output logic [4:0] vga_b_o,
  output logic       vga_hs_o,
  output logic       vga_vs_o,
  output logic       active_video_o
);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      vga_r_o        <= '0;
      vga_g_o        <= '0;
      vga_b_o        <= '0;
      vga_hs_o       <= 1'b0;
      vga_vs_o       <= 1'b0;
      active_video_o <= 1'b0;
    end else begin
      vga_r_o        <= de_i ? pixel_i.red : 5'b0;
      vga_g_o        <= de_i ? pixel_i.grn : 6'b0;
      vga_b_o        <= de_i ? pixel_i.blu : 5'b0;
      vga_hs_o       <= hsync_i;
      vga_vs_o       <= vsync_i;
      active_video_o <= de_i;
    end
  end

endmodule
