`default_nettype none

import hdmi_pkg::*;

// HDMI TX core — pixel-clock domain only.
//
// Inputs:  RGB888 + DE + HSYNC + VSYNC + explicit blanking signals
// Outputs: 3 × 10-bit TMDS words per pixel clock (ch0=B, ch1=G, ch2=R)
//
// hblank_i / vblank_i / frame_start_i / blank_remaining_i come from
// video_timing_generator directly.  This avoids the incorrect derivation
// vblank = vsync_r (a sync pulse is not the full blanking interval) and gives
// the period scheduler an accurate blank_remaining budget.
//
// Pipeline (all stages in pix_clk_i domain):
//   Cycle N   : rgb_i / de_i / hsync_i / vsync_i / hblank_i / … presented
//   Cycle N+1 : stage-1 registers; period_scheduler sees inputs
//   Cycle N+2 : TMDS/TERC4 words available at encoder outputs
//   Cycle N+3 : channel_mux registered output → ch0_o / ch1_o / ch2_o
//
// Total latency = 3 pixel clocks.
//
// ENABLE_DATA_ISLAND=0 → DVI-compatible (no InfoFrames, no TERC4).
module hdmi_tx_core #(
  parameter bit ENABLE_DATA_ISLAND = 0,
  parameter bit ENABLE_AVI         = 1,
  parameter bit ENABLE_SPD         = 0,
  parameter bit ENABLE_AUDIO_IF    = 0
)(
  input  logic pix_clk_i,
  input  logic rst_ni,

  // Timed video stream
  input  logic [7:0] red_i,
  input  logic [7:0] grn_i,
  input  logic [7:0] blu_i,
  input  logic       de_i,
  input  logic       hsync_i,
  input  logic       vsync_i,

  // Explicit blanking timing from video_timing_generator
  input  logic        hblank_i,          // horizontal blank (not vblank, not de)
  input  logic        vblank_i,          // vertical blank (v_cnt >= V_ACTIVE)
  input  logic        frame_start_i,     // first pixel_req of each frame
  input  logic [15:0] blank_remaining_i, // cycles until next active video

  // InfoFrame configuration (static or quasi-static)
  input  hdmi_info_cfg_t  info_cfg_i,
  input  color_format_e   color_fmt_i,
  input  aspect_ratio_e   aspect_ratio_i,
  input  quant_range_e    quant_range_i,
  input  logic [7:0]      vic_code_i,

  // Output: 10-bit TMDS words, one per pixel clock
  output tmds_word_t ch0_o,   // Blue channel
  output tmds_word_t ch1_o,   // Green channel
  output tmds_word_t ch2_o    // Red channel
);

  // ── Stage 1 input registers ───────────────────────────────────────────────
  logic [7:0]  red_r, grn_r, blu_r;
  logic        de_r, hsync_r, vsync_r;
  logic        hblank_r, vblank_r;
  logic [15:0] blank_remaining_r;

  always_ff @(posedge pix_clk_i) begin
    if (!rst_ni) begin
      red_r             <= '0;  grn_r  <= '0;  blu_r  <= '0;
      de_r              <= 1'b0; hsync_r <= 1'b0; vsync_r <= 1'b0;
      hblank_r          <= 1'b0;
      vblank_r          <= 1'b0;
      blank_remaining_r <= '0;
    end else begin
      red_r             <= red_i;   grn_r  <= grn_i;  blu_r  <= blu_i;
      de_r              <= de_i;    hsync_r <= hsync_i; vsync_r <= vsync_i;
      hblank_r          <= hblank_i;
      vblank_r          <= vblank_i;
      blank_remaining_r <= blank_remaining_i;
    end
  end

  // ── Period scheduler ──────────────────────────────────────────────────────
  hdmi_period_t period;
  logic         packet_pending;
  logic         packet_start, packet_pop;

  hdmi_period_scheduler #(
    .ENABLE_DATA_ISLAND(ENABLE_DATA_ISLAND)
  ) u_sched (
    .clk_i              (pix_clk_i),
    .rst_ni             (rst_ni),
    .de_i               (de_r),
    .hblank_i           (hblank_r),
    .vblank_i           (vblank_r),
    .blank_remaining_i  (blank_remaining_r),
    .packet_pending_i   (packet_pending),
    .packet_start_o     (packet_start),
    .packet_pop_o       (packet_pop),
    .period_o           (period)
  );

  // ── TMDS video encoders (latency = 2) ─────────────────────────────────────
  tmds_word_t video_ch2, video_ch1, video_ch0;

  tmds_video_encoder u_enc_r (
    .clk_i  (pix_clk_i), .rst_ni(rst_ni),
    .de_i   (de_r),       .data_i(red_r), .tmds_o(video_ch2)
  );
  tmds_video_encoder u_enc_g (
    .clk_i  (pix_clk_i), .rst_ni(rst_ni),
    .de_i   (de_r),       .data_i(grn_r), .tmds_o(video_ch1)
  );
  tmds_video_encoder u_enc_b (
    .clk_i  (pix_clk_i), .rst_ni(rst_ni),
    .de_i   (de_r),       .data_i(blu_r), .tmds_o(video_ch0)
  );

  // ── TMDS control encoders (latency = 2, matching video) ───────────────────
  // Channel 0 carries {vsync, hsync}; channels 1 & 2 carry 2'b00.
  tmds_word_t ctrl_ch2, ctrl_ch1, ctrl_ch0;

  tmds_control_encoder u_ctrl_r (
    .clk_i(pix_clk_i), .rst_ni(rst_ni),
    .ctrl_i(2'b00),            .tmds_o(ctrl_ch2)
  );
  tmds_control_encoder u_ctrl_g (
    .clk_i(pix_clk_i), .rst_ni(rst_ni),
    .ctrl_i(2'b00),            .tmds_o(ctrl_ch1)
  );
  tmds_control_encoder u_ctrl_b (
    .clk_i(pix_clk_i), .rst_ni(rst_ni),
    .ctrl_i({vsync_r, hsync_r}), .tmds_o(ctrl_ch0)
  );

  // ── Delay period by 1 cycle to align with encoder outputs ─────────────────
  // Encoders have LATENCY=2 from red_r/de_r.  With 1 delay stage:
  //   period_d1[T+3] = f(de_r[T+1]) = f(de_i[T])
  //   video_ch*[T+3] = encoded(red_r[T+1]) = encoded(red_i[T])
  hdmi_period_t period_d1;
  always_ff @(posedge pix_clk_i) begin
    if (!rst_ni)
      period_d1 <= HDMI_PERIOD_CONTROL;
    else
      period_d1 <= period;
  end

  // ── Data-island TERC4 path (only when ENABLE_DATA_ISLAND) ─────────────────
  tmds_word_t data_ch2, data_ch1, data_ch0;

  generate
  if (ENABLE_DATA_ISLAND) begin : gen_data_island

    // InfoFrame builders
    logic [7:0] hdr_avi[3], pl_avi[32];
    int         len_avi_int;
    logic [5:0] len_avi;

    infoframe_builder #(.IF_TYPE(INFO_AVI)) u_avi_builder (
      .color_format_i  (color_fmt_i),
      .aspect_ratio_i  (aspect_ratio_i),
      .quant_range_i   (quant_range_i),
      .vic_code_i      (vic_code_i),
      .vendor_name_i   ('0),
      .product_desc_i  ('0),
      .source_device_i ('0),
      .audio_channels_i(3'd0),
      .header_o        (hdr_avi),
      .payload_o       (pl_avi),
      .payload_len_o   (len_avi_int)
    );
    assign len_avi = len_avi_int[5:0];

    // Trigger packet scheduler on vsync rising edge (once per frame)
    logic vsync_prev;
    logic eof_pulse;
    always_ff @(posedge pix_clk_i) vsync_prev <= vsync_r;
    assign eof_pulse = vsync_r & ~vsync_prev;

    logic [7:0] pkt_byte;
    logic       pkt_ready;
    logic       pkt_last;

    packet_scheduler #(.MAX_PAYLOAD(32)) u_pkt_sched (
      .clk_i         (pix_clk_i),
      .rst_ni        (rst_ni),
      .eof_i         (eof_pulse),
      .header_avi    (hdr_avi),
      .payload_avi   (pl_avi),
      .len_avi       (len_avi),
      .header_spd    ('{default:'0}),
      .payload_spd   ('{default:'0}),
      .len_spd       (6'd0),
      .header_audio  ('{default:'0}),
      .payload_audio ('{default:'0}),
      .len_audio     (6'd0),
      .packet_o      (pkt_byte),
      .packet_ready_o(pkt_ready),
      .packet_last_o (pkt_last),
      .consume_i     (packet_pop)
    );

    assign packet_pending = pkt_ready;

    // TERC4 encoders: nibble mapping (ch0 lower nibble, ch1 upper nibble)
    terc4_encoder u_terc4_ch0 (
      .clk_i   (pix_clk_i), .rst_ni(rst_ni),
      .nibble_i(pkt_byte[3:0]), .tmds_o(data_ch0)
    );
    terc4_encoder u_terc4_ch1 (
      .clk_i   (pix_clk_i), .rst_ni(rst_ni),
      .nibble_i(pkt_byte[7:4]), .tmds_o(data_ch1)
    );
    terc4_encoder u_terc4_ch2 (
      .clk_i   (pix_clk_i), .rst_ni(rst_ni),
      .nibble_i(4'h0), .tmds_o(data_ch2)
    );

  end else begin : gen_no_data_island
    assign packet_pending = 1'b0;
    assign data_ch0 = ctrl_ch0;
    assign data_ch1 = ctrl_ch1;
    assign data_ch2 = ctrl_ch2;
  end
  endgenerate

  // ── Channel mux (adds 1 more register stage) ──────────────────────────────
  hdmi_channel_mux u_mux (
    .clk_i     (pix_clk_i),
    .rst_ni    (rst_ni),
    .period_i  (period_d1),
    .video_ch2_i(video_ch2), .video_ch1_i(video_ch1), .video_ch0_i(video_ch0),
    .ctrl_ch2_i (ctrl_ch2),  .ctrl_ch1_i (ctrl_ch1),  .ctrl_ch0_i (ctrl_ch0),
    .data_ch2_i (data_ch2),  .data_ch1_i (data_ch1),  .data_ch0_i (data_ch0),
    .ch2_o     (ch2_o),
    .ch1_o     (ch1_o),
    .ch0_o     (ch0_o)
  );

endmodule
