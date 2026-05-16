/**
 * @file hdmi_channel_mux.sv
 * @brief Multiplexor pre 3 TMDS kanály HDMI vysielača
 * @details Modul vyberá medzi video dátami, riadiacimi symbolmi a Data Island
 * paketmi na základe aktuálnej periódy (FSM).
 * @param clk_i Pixel clock
 * @param rst_ni Asynchrónny aktívne-low reset
 * @param period_i Aktuálny stav HDMI periódy
 * @param vsync_i Surový VSYNC signál
 * @param hsync_i Surový HSYNC signál
 * @param video_ch2_i TMDS video dáta pre kanál 2 (Červená)
 * @param video_ch1_i TMDS video dáta pre kanál 1 (Zelená)
 * @param video_ch0_i TMDS video dáta pre kanál 0 (Modrá)
 * @param ctrl_ch2_i TMDS riadiace dáta pre kanál 2
 * @param ctrl_ch1_i TMDS riadiace dáta pre kanál 1
 * @param ctrl_ch0_i TMDS riadiace dáta pre kanál 0
 * @param data_ch2_i TMDS Data Island dáta pre kanál 2
 * @param data_ch1_i TMDS Data Island dáta pre kanál 1
 * @param data_ch0_i TMDS Data Island dáta pre kanál 0
 * @param ch2_o Výstupný TMDS symbol pre kanál 2
 * @param ch1_o Výstupný TMDS symbol pre kanál 1
 * @param ch0_o Výstupný TMDS symbol pre kanál 0
 */

`ifndef HDMI_CHANNEL_MUX_SV
`define HDMI_CHANNEL_MUX_SV

`default_nettype none

import hdmi_pkg::*;

// Registered 3-channel TMDS mux.  Selects video, control, or data-island
// symbols for each of the three TMDS channels based on period_i.
//
// All inputs must be already latency-aligned (same pipeline depth).
//
// vsync_i / hsync_i must be the raw (non-TMDS-encoded) sync values at the
// same pipeline phase as ctrl_ch0_i.  They are used to compute the
// data-island guard-band ch0 symbol: TERC4({1,1,VSYNC,HSYNC}) per
// HDMI 1.3 spec Table 5-4 (CTL3=1 CTL2=1 CTL1=VSYNC CTL0=HSYNC).
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
  localparam tmds_word_t GB_VIDEO    = 10'b1011001100;  // TERC4(4'h8); Video GB Ch0+Ch2
  localparam tmds_word_t GB_DATA_N   = 10'b0100110011;  // Video GB Ch1 (complement of GB_VIDEO)
  localparam tmds_word_t GB_DATA_CH1 = 10'b0101110001;  // TERC4(4'h4); Data Island GB Ch1
  localparam tmds_word_t GB_DATA_CH2 = 10'b1011000110;  // TERC4(4'hB); Data Island GB Ch2
  // ch0 data island GB: TERC4({CTL3,CTL2,CTL1,CTL0}) = TERC4({1,1,VSYNC,HSYNC})
  // CTL3=1 CTL2=1 fixed; CTL1=VSYNC CTL0=HSYNC vary.
  tmds_word_t gb_data_ch0;

  always_comb begin
    unique case ({vsync_i, hsync_i})
      2'b00: gb_data_ch0 = 10'b1010001110;  // TERC4(4'b1100)
      2'b01: gb_data_ch0 = 10'b1001110001;  // TERC4(4'b1101)
      2'b10: gb_data_ch0 = 10'b0101100011;  // TERC4(4'b1110)
      2'b11: gb_data_ch0 = 10'b1011000011;  // TERC4(4'b1111)
      default: gb_data_ch0 = 10'b1010001110;
    endcase
  end

  // Preamble type tokens per HDMI 1.3 spec Table 5-7.
  // Ch0 always carries {vsync,hsync}; ch1={CTL1,CTL0}; ch2={CTL3,CTL2}.
  //   video preamble: CTL0=1 CTL1=0 CTL2=0 CTL3=0
  //     ch1=ctrl(2'b01)  ch2=ctrl(2'b00)
  //   data  preamble: CTL0=1 CTL1=0 CTL2=1 CTL3=0
  //     ch1=ctrl(2'b01)  ch2=ctrl(2'b01)   <-- both channels identical
  localparam tmds_word_t PRE_VIDEO_CH1 = 10'b0010101011;  // ctrl(2'b01)

  tmds_word_t ch2_next;
  tmds_word_t ch1_next;
  tmds_word_t ch0_next;

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
        // HDMI 1.3 spec 5.2.3.3: Ch0/Ch2 = GB_VIDEO, Ch1 = GB_DATA_N
        ch2_next = GB_VIDEO;
        ch1_next = GB_DATA_N;
        ch0_next = GB_VIDEO;
      end

      HDMI_PERIOD_DATA_PREAMBLE: begin
        // HDMI 1.3 Table 5-7: CTL0=1 CTL1=0 CTL2=1 CTL3=0
        // ch1={CTL1=0,CTL0=1}=ctrl(2'b01)  ch2={CTL3=0,CTL2=1}=ctrl(2'b01)
        ch2_next = PRE_VIDEO_CH1;
        ch1_next = PRE_VIDEO_CH1;
        ch0_next = ctrl_ch0_i;
      end

      HDMI_PERIOD_DATA_GB_LEAD,
      HDMI_PERIOD_DATA_GB_TRAIL: begin
        ch2_next = GB_DATA_CH2;
        ch1_next = GB_DATA_CH1;
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

`endif // HDMI_CHANNEL_MUX_SV
