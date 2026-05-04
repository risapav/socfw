`default_nettype none

import hdmi_pkg::*;

// Registered 3-channel TMDS mux.  Selects video, control, or data-island
// symbols for each of the three TMDS channels based on period_i.
//
// All inputs must be already latency-aligned (same pipeline depth).
module hdmi_channel_mux (
  input  logic clk_i,
  input  logic rst_ni,

  input  hdmi_period_t period_i,

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

  // Guard-band symbols (HDMI spec, section 5.2.2)
  localparam tmds_word_t GB_VIDEO  = 10'b1011001100;
  localparam tmds_word_t GB_DATA_0 = 10'b0100110011;  // ch0 leading/trailing GB
  localparam tmds_word_t GB_DATA_N = 10'b0100110011;  // ch1/ch2 leading/trailing GB

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
      HDMI_PERIOD_VIDEO_GB: begin
        // Video guard band: fixed symbols per HDMI spec
        ch2_next = GB_VIDEO;
        ch1_next = GB_VIDEO;
        ch0_next = ctrl_ch0_i;  // ch0 carries control during VGB
      end
      HDMI_PERIOD_DATA_PREAMBLE: begin
        // During preamble ch0 carries control, ch1/ch2 fixed preamble value
        ch2_next = ctrl_ch2_i;
        ch1_next = ctrl_ch1_i;
        ch0_next = ctrl_ch0_i;
      end
      HDMI_PERIOD_DATA_GB_LEAD,
      HDMI_PERIOD_DATA_GB_TRAIL: begin
        ch2_next = GB_DATA_N;
        ch1_next = GB_DATA_N;
        ch0_next = GB_DATA_0;
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
