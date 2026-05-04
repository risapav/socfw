`default_nettype none

import hdmi_pkg::*;

// Word-aligned TMDS DDR PHY for Cyclone IV (ALTDDIO_OUT based).
//
// pair_cnt counts 0..4 in the clk_x_i domain.  At pair_cnt==4 the current
// TMDS words are latched from the pixel-clock domain; serialization begins at
// pair_cnt==0 of the next pixel cycle, so the load always starts at bit 0.
//
// Timing requirements:
//   clk_x_i = 5 × pixel_clock (PLL co-generated, 0° offset).
//   ch*_i are registered outputs of hdmi_tx_core, stable for one full pixel
//   period (5 fast clocks).  Capture at pair_cnt==4 gives ~4×(T_pix/5) of
//   setup margin and 1×(T_pix/5) of hold margin — adequate at 200 MHz.
//   Declare a multicycle path (5 fast clocks) in timing constraints for the
//   ch*_i → sr_ch* paths if Quartus flags them.
//
// LSB-first serialization: bit 0 on posedge, bit 1 on negedge, …, bit 9 last.
module tmds_phy_ddr_aligned (
  input  logic       clk_x_i,     // 5× pixel clock for DDR (e.g. 200 MHz)
  input  logic       rst_ni,

  // 10-bit TMDS words from hdmi_tx_core (pixel-clock domain, stable 1 full period)
  input  tmds_word_t ch0_i,       // Blue channel
  input  tmds_word_t ch1_i,       // Green channel
  input  tmds_word_t ch2_i,       // Red channel
  input  tmds_word_t clk_ch_i,    // Clock channel (typically 10'b1111100000)

  // Serialized DDR output: [0]=Blue, [1]=Green, [2]=Red, [3]=Clock
  output logic [3:0] hdmi_p_o
);

  // ── Pair counter (clk_x domain) ───────────────────────────────────────────
  logic [2:0] pair_cnt;

  always_ff @(posedge clk_x_i) begin
    if (!rst_ni)
      pair_cnt <= 3'd0;
    else
      pair_cnt <= (pair_cnt == 3'd4) ? 3'd0 : pair_cnt + 3'd1;
  end

  // ── Shift registers (clk_x domain) ───────────────────────────────────────
  // pair_cnt==4 : latch new word (ALTDDIO sees old bits 8,9 at this posedge)
  // pair_cnt==0..3 : shift right by 2 (ALTDDIO sees bits 0,1 … 6,7)
  logic [9:0] sr_ch0, sr_ch1, sr_ch2, sr_clk;

  always_ff @(posedge clk_x_i) begin
    if (!rst_ni) begin
      sr_ch0 <= '0;
      sr_ch1 <= '0;
      sr_ch2 <= '0;
      sr_clk <= '0;
    end else if (pair_cnt == 3'd4) begin
      sr_ch0 <= ch0_i;
      sr_ch1 <= ch1_i;
      sr_ch2 <= ch2_i;
      sr_clk <= clk_ch_i;
    end else begin
      sr_ch0 <= {2'b00, sr_ch0[9:2]};
      sr_ch1 <= {2'b00, sr_ch1[9:2]};
      sr_ch2 <= {2'b00, sr_ch2[9:2]};
      sr_clk <= {2'b00, sr_clk[9:2]};
    end
  end

  // ── DDR output drivers (one ALTDDIO_OUT per channel) ─────────────────────
  // sr[0] → posedge output (first bit of pair), sr[1] → negedge output.
  logic p_unpacked [4];
  assign hdmi_p_o = {p_unpacked[3], p_unpacked[2], p_unpacked[1], p_unpacked[0]};

  ddio_out ddr_ch0 (
    .datain_h(sr_ch0[0]), .datain_l(sr_ch0[1]),
    .outclock(clk_x_i),   .dataout(p_unpacked[0])
  );
  ddio_out ddr_ch1 (
    .datain_h(sr_ch1[0]), .datain_l(sr_ch1[1]),
    .outclock(clk_x_i),   .dataout(p_unpacked[1])
  );
  ddio_out ddr_ch2 (
    .datain_h(sr_ch2[0]), .datain_l(sr_ch2[1]),
    .outclock(clk_x_i),   .dataout(p_unpacked[2])
  );
  ddio_out ddr_clk (
    .datain_h(sr_clk[0]), .datain_l(sr_clk[1]),
    .outclock(clk_x_i),   .dataout(p_unpacked[3])
  );

endmodule
