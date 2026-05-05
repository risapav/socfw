`default_nettype none

import hdmi_pkg::*;

// Registered 3-channel TMDS mux.  Selects video, control, or data-island
// symbols for each of the three TMDS channels based on period_i.
//
// All inputs must be already latency-aligned (same pipeline depth).
//
// vsync_i / hsync_i must be the raw (non-TMDS-encoded) sync values at the
// same pipeline phase as ctrl_ch0_i.  They are used to compute the
// data-island guard-band ch0 symbol: TERC4({1, vsync, hsync, 1}) per
// HDMI 1.3 spec section 5.2.3.2.
module hdmi_channel_mux (
  input  logic clk_i,
  input  logic rst_ni,

  input  hdmi_period_t period_i,

  // Sync values aligned with ctrl_ch0_i (raw, not TMDS-encoded)
  input  logic vsync_i,
  input  logic hsync_i,

  // Video encoder outputs (channels 2=R, 1=G, 0=B)
  input  tmds_word_t video_ch2_i,
  input  tmds_word_t video_ch1_i,
  input  tmds_word_t video_ch0_i,

  // Control encoder outputs
  input  tmds_word_t ctrl_ch2_i,   // typically 2'b00
  input  tmds_word_t ctrl_ch1_i,   // typically 2'b00
  input  tmds_word_t ctrl_ch0_i,   // {vsync, hsync}

  // Data-island (TERC4) encoder outputs
  input  tmds_word_t data_ch2_i,
  input  tmds_word_t data_ch1_i,
  input  tmds_word_t data_ch0_i,

  // Output TMDS words
  output tmds_word_t ch2_o,
  output tmds_word_t ch1_o,
  output tmds_word_t ch0_o
);

  // Guard-band symbols (HDMI 1.3 spec, section 5.2.2)
  localparam tmds_word_t GB_VIDEO   = 10'b1011001100;  // TERC4(0b1000), ch1/ch2 video GB
  localparam tmds_word_t GB_DATA_N  = 10'b0100110011;  // fixed per spec, ch1/ch2 data island GB
  // ch0 data island GB: TERC4({1, vsync, hsync, 1}) — HDMI 1.3 spec section 5.2.3.2
  // nibble = {1, vsync, hsync, 1}: only {vsync,hsync} vary, so 4 possible values.
  tmds_word_t gb_data_ch0;
  always_comb begin
    unique case ({vsync_i, hsync_i})
      2'b00: gb_data_ch0 = 10'b0100111001;  // TERC4(4'b1001)
      2'b01: gb_data_ch0 = 10'b1011000110;  // TERC4(4'b1011)
      2'b10: gb_data_ch0 = 10'b1001110001;  // TERC4(4'b1101)
      2'b11: gb_data_ch0 = 10'b1011000011;  // TERC4(4'b1111)
    endcase
  end

  // Preamble type tokens: ch1 encodes {CTL3,CTL2} to signal what period follows.
  // ch0 carries {vsync,hsync} throughout; ch2 stays ctrl(2'b00).
  // HDMI 1.3 spec Table 5-7:
  //   video preamble:  CTL2=1, CTL3=0  → ctrl(2'b01) = 10'b0010101011
  //   data  preamble:  CTL2=1, CTL3=1  → ctrl(2'b11) = 10'b1010101011
  localparam tmds_word_t PRE_VIDEO_CH1 = 10'b0010101011;  // ctrl(2'b01)
  localparam tmds_word_t PRE_DATA_CH1  = 10'b1010101011;  // ctrl(2'b11)

  tmds_word_t ch2_next, ch1_next, ch0_next;

  always_comb begin
    ch2_next = ctrl_ch2_i;
    ch1_next = ctrl_ch1_i;
    ch0_next = ctrl_ch0_i;

    unique case (period_i)
      HDMI_PERIOD_VIDEO: begin
        ch2_next = video_ch2_i;
        ch1_next = video_ch1_i;
        ch0_next = video_ch0_i;
      end
      HDMI_PERIOD_VIDEO_PREAMBLE: begin
        // ch1 signals "video period follows"; ch0 carries {vsync,hsync}; ch2=ctrl(0)
        ch2_next = ctrl_ch2_i;
        ch1_next = PRE_VIDEO_CH1;
        ch0_next = ctrl_ch0_i;
      end
      HDMI_PERIOD_VIDEO_GB: begin
        // Video guard band: fixed TERC4(8) on ch1/ch2; ch0 carries control
        ch2_next = GB_VIDEO;
        ch1_next = GB_VIDEO;
        ch0_next = ctrl_ch0_i;
      end
      HDMI_PERIOD_DATA_PREAMBLE: begin
        // ch1 signals "data island follows"; ch0 carries {vsync,hsync}; ch2=ctrl(0)
        ch2_next = ctrl_ch2_i;
        ch1_next = PRE_DATA_CH1;
        ch0_next = ctrl_ch0_i;
      end
      HDMI_PERIOD_DATA_GB_LEAD,
      HDMI_PERIOD_DATA_GB_TRAIL: begin
        ch2_next = GB_DATA_N;
        ch1_next = GB_DATA_N;
        ch0_next = gb_data_ch0;
      end
      HDMI_PERIOD_DATA_PAYLOAD: begin
        ch2_next = data_ch2_i;
        ch1_next = data_ch1_i;
        ch0_next = data_ch0_i;
      end
      default: begin
        ch2_next = ctrl_ch2_i;
        ch1_next = ctrl_ch1_i;
        ch0_next = ctrl_ch0_i;
      end
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      ch2_o <= 10'b1101010100;
      ch1_o <= 10'b1101010100;
      ch0_o <= 10'b1101010100;
    end else begin
      ch2_o <= ch2_next;
      ch1_o <= ch1_next;
      ch0_o <= ch0_next;
    end
  end

endmodule
