`default_nettype none

import hdmi_pkg::*;

// HDMI TX core — pixel-clock domain only.
//
// Inputs:  RGB888 + DE + HSYNC + VSYNC + explicit blanking signals
// Outputs: 3 × 10-bit TMDS words per pixel clock (ch0=B, ch1=G, ch2=R)
//
// hblank_i / vblank_i / frame_start_i / blank_remaining_i come from
// video_timing_generator.  The period scheduler uses blank_remaining_i to
// guard data island insertion against overrunning into active video.
//
// Pipeline (all stages in pix_clk_i domain):
//   Cycle N   : inputs presented; stage-1 registers sample
//   Cycle N+1 : period_scheduler and TMDS encoders see registered inputs
//   Cycle N+2 : encoder outputs ready
//   Cycle N+3 : channel_mux registered output → ch0_o / ch1_o / ch2_o
//
// ENABLE_DATA_ISLAND=0 → DVI-compatible (no InfoFrames, no TERC4).
// ENABLE_DATA_ISLAND=1 → full HDMI: AVI InfoFrame via data_island_formatter
//                         with correct BCH/ECC and HDMI channel mapping.
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
  input  logic        hblank_i,
  input  logic        vblank_i,
  input  logic        frame_start_i,
  input  logic [15:0] blank_remaining_i,

  // InfoFrame configuration (static or quasi-static)
  input  hdmi_info_cfg_t  info_cfg_i,
  input  color_format_e   color_fmt_i,
  input  aspect_ratio_e   aspect_ratio_i,
  input  quant_range_e    quant_range_i,
  input  logic [7:0]      vic_code_i,

  // Output: 10-bit TMDS words, one per pixel clock
  output tmds_word_t ch0_o,
  output tmds_word_t ch1_o,
  output tmds_word_t ch2_o
);

  // ── Stage 1 input registers ───────────────────────────────────────────────
  logic [7:0]  red_r, grn_r, blu_r;
  logic        de_r, hsync_r, vsync_r;
  logic        hblank_r, vblank_r;
  logic [15:0] blank_remaining_r;

  always_ff @(posedge pix_clk_i) begin
    if (!rst_ni) begin
      red_r             <= '0;   grn_r  <= '0;   blu_r  <= '0;
      de_r              <= 1'b0; hsync_r <= 1'b0; vsync_r <= 1'b0;
      hblank_r          <= 1'b0;
      vblank_r          <= 1'b0;
      blank_remaining_r <= '0;
    end else begin
      red_r             <= red_i;
      grn_r             <= grn_i;
      blu_r             <= blu_i;
      de_r              <= de_i;
      hsync_r           <= hsync_i;
      vsync_r           <= vsync_i;
      hblank_r          <= hblank_i;
      vblank_r          <= vblank_i;
      blank_remaining_r <= blank_remaining_i;
    end
  end

  // ── Extra pipeline stage to align blank_remaining with video data path ───────
  // blank_remaining from vtg has 2 register stages to de_r (vtg_reg + hdmi_stage1).
  // vga_de_i goes through vga_output_adapter (3 stages to de_r).  Without
  // alignment the VIDEO period switch leads valid TMDS by 5 symbols per line.
  // Adding one extra register makes both paths 3 stages deep.  VIDEO_TRIG in
  // the scheduler is then set to VIDEO_PRE_TOTAL so that VIDEO appears at
  // ch*_o exactly when the first valid TMDS word leaves the encoder.
  logic [15:0] blank_remaining_rr;
  logic        hblank_rr;

  always_ff @(posedge pix_clk_i) begin
    if (!rst_ni) begin
      blank_remaining_rr <= '0;
      hblank_rr          <= 1'b0;
    end else begin
      blank_remaining_rr <= blank_remaining_r;
      hblank_rr          <= hblank_r;
    end
  end

  // ── Period scheduler ──────────────────────────────────────────────────────
  hdmi_period_t period;
  logic         packet_pending;
  logic         packet_start, packet_pop;

  hdmi_period_scheduler #(
    .ENABLE_DATA_ISLAND(ENABLE_DATA_ISLAND)
  ) u_sched (
    .clk_i             (pix_clk_i),
    .rst_ni            (rst_ni),
    .de_i              (de_r),
    .hblank_i          (hblank_rr),
    .vblank_i          (vblank_r),
    .blank_remaining_i (blank_remaining_rr),
    .packet_pending_i  (packet_pending),
    .packet_start_o    (packet_start),
    .packet_pop_o      (packet_pop),
    .period_o          (period)
  );

  // ── TMDS video encoders (latency = 2) ─────────────────────────────────────
  tmds_word_t video_ch2, video_ch1, video_ch0;

  tmds_video_encoder u_enc_r (
    .clk_i(pix_clk_i), .rst_ni(rst_ni),
    .de_i(de_r), .data_i(red_r), .tmds_o(video_ch2)
  );
  tmds_video_encoder u_enc_g (
    .clk_i(pix_clk_i), .rst_ni(rst_ni),
    .de_i(de_r), .data_i(grn_r), .tmds_o(video_ch1)
  );
  tmds_video_encoder u_enc_b (
    .clk_i(pix_clk_i), .rst_ni(rst_ni),
    .de_i(de_r), .data_i(blu_r), .tmds_o(video_ch0)
  );

  // ── TMDS control encoders (latency = 2) ───────────────────────────────────
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

  // ── Delay period by 1 cycle to align with encoder latency-2 outputs ───────
  // At cycle T+3: period_d1=f(period[T+2])=f(de_i[T]), video_ch*=f(red_i[T])
  hdmi_period_t period_d1;
  always_ff @(posedge pix_clk_i) begin
    if (!rst_ni) period_d1 <= HDMI_PERIOD_CONTROL;
    else         period_d1 <= period;
  end

  // ── Sync signals aligned with ctrl encoder outputs (latency 2 from vsync_r) ──
  // hdmi_channel_mux needs raw vsync/hsync at the same pipeline phase as
  // ctrl_ch0_i so it can compute the guard-band ch0 = TERC4({1,vsync,hsync,1}).
  logic vsync_enc1, vsync_enc;
  logic hsync_enc1, hsync_enc;
  always_ff @(posedge pix_clk_i) begin
    if (!rst_ni) begin
      vsync_enc1 <= 1'b0; vsync_enc <= 1'b0;
      hsync_enc1 <= 1'b0; hsync_enc <= 1'b0;
    end else begin
      vsync_enc1 <= vsync_r;  vsync_enc <= vsync_enc1;
      hsync_enc1 <= hsync_r;  hsync_enc <= hsync_enc1;
    end
  end

  // ── Data-island TERC4 path ────────────────────────────────────────────────
  tmds_word_t data_ch2, data_ch1, data_ch0;

  generate
  if (ENABLE_DATA_ISLAND) begin : gen_data_island

    // AVI InfoFrame builder (combinational, static configuration)
    logic [7:0] hdr_avi [0:2];
    logic [7:0] pl_avi  [0:31];
    int         len_avi_int;

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

    // packet_pending: set on vsync rising edge (once per frame), cleared on
    // packet_start so only one data island per frame is scheduled.
    logic vsync_prev;
    always_ff @(posedge pix_clk_i) vsync_prev <= vsync_r;

    logic pending;
    always_ff @(posedge pix_clk_i) begin
      if (!rst_ni)       pending <= 1'b0;
      else if (vsync_r && !vsync_prev) pending <= 1'b1;
      else if (packet_start)           pending <= 1'b0;
    end
    assign packet_pending = pending;

    // Payload bytes for data_island_formatter: 4 subpackets × 7 bytes = 28 B.
    // Take pl_avi[0..27]; bytes past len_avi_int are zeroed.
    logic [7:0] pb_avi [0:27];
    always_comb begin
      for (int i = 0; i < 28; i++)
        pb_avi[i] = (i < len_avi_int) ? pl_avi[i] : 8'h00;
    end

    // Data island formatter: BCH/ECC + correct HDMI channel bit mapping
    logic [3:0] di_ch0, di_ch1, di_ch2;
    logic       di_active;

    data_island_formatter u_formatter (
      .clk_i    (pix_clk_i),
      .rst_ni   (rst_ni),
      .start_i  (packet_start),
      .advance_i(packet_pop),
      .hsync_i  (hsync_r),
      .vsync_i  (vsync_r),
      .hb       (hdr_avi),
      .pb       (pb_avi),
      .ch0_o    (di_ch0),
      .ch1_o    (di_ch1),
      .ch2_o    (di_ch2),
      .active_o (di_active),
      .done_o   ()
    );

    // TERC4 encoders — 2-cycle latency matches video encoder latency
    terc4_encoder u_terc4_ch0 (
      .clk_i   (pix_clk_i), .rst_ni(rst_ni),
      .nibble_i(di_ch0), .tmds_o(data_ch0)
    );
    terc4_encoder u_terc4_ch1 (
      .clk_i   (pix_clk_i), .rst_ni(rst_ni),
      .nibble_i(di_ch1), .tmds_o(data_ch1)
    );
    terc4_encoder u_terc4_ch2 (
      .clk_i   (pix_clk_i), .rst_ni(rst_ni),
      .nibble_i(di_ch2), .tmds_o(data_ch2)
    );

  end else begin : gen_no_data_island
    assign packet_pending = 1'b0;
    assign data_ch0 = ctrl_ch0;
    assign data_ch1 = ctrl_ch1;
    assign data_ch2 = ctrl_ch2;
  end
  endgenerate

  // ── Channel mux (adds 1 register stage) ───────────────────────────────────
  hdmi_channel_mux u_mux (
    .clk_i      (pix_clk_i),
    .rst_ni     (rst_ni),
    .period_i   (period_d1),
    .vsync_i    (vsync_enc),
    .hsync_i    (hsync_enc),
    .video_ch2_i(video_ch2), .video_ch1_i(video_ch1), .video_ch0_i(video_ch0),
    .ctrl_ch2_i (ctrl_ch2),  .ctrl_ch1_i (ctrl_ch1),  .ctrl_ch0_i (ctrl_ch0),
    .data_ch2_i (data_ch2),  .data_ch1_i (data_ch1),  .data_ch0_i (data_ch0),
    .ch2_o      (ch2_o),
    .ch1_o      (ch1_o),
    .ch0_o      (ch0_o)
  );

endmodule
