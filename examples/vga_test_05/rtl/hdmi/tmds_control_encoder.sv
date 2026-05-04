`default_nettype none

import hdmi_pkg::*;

// TMDS control encoder: maps 2-bit control value to the four TMDS control
// symbols defined by the DVI/HDMI spec.  Output is registered to match the
// 2-cycle latency of tmds_video_encoder (LATENCY = 2).
module tmds_control_encoder (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic [1:0] ctrl_i,   // {c1, c0}, e.g. {vsync, hsync} on channel 0

  output tmds_word_t tmds_o
);

  localparam int LATENCY = 2;

  // Stage 1 register
  logic [1:0] ctrl_r;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) ctrl_r <= 2'b00;
    else         ctrl_r <= ctrl_i;
  end

  // Stage 2: LUT + output register
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tmds_o <= 10'b1101010100;
    end else begin
      unique case (ctrl_r)
        2'b00: tmds_o <= 10'b1101010100;
        2'b01: tmds_o <= 10'b0010101011;
        2'b10: tmds_o <= 10'b0101010100;
        2'b11: tmds_o <= 10'b1010101011;
      endcase
    end
  end

endmodule
