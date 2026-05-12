`default_nettype none
`ifndef HDMI_AUDIO_TEST_SRC_SV
`define HDMI_AUDIO_TEST_SRC_SV

// Internal 1 kHz square-wave test tone for HDMI audio bring-up.
//
// Uses a phase accumulator (exact long-term rate) to divide the pixel clock
// down to SAMPLE_RATE.  Accumulates 4 L/R pairs before asserting valid_o.
// Deasserts valid_o and resets the accumulator on consume_i.
//
// Amplitude: ±0x4000 (25% of full scale) to avoid clipping artefacts.
// Both channels carry the same signal (mono tone routed to L and R).
module hdmi_audio_test_src #(
  parameter int PIXEL_CLK_HZ = 40_000_000,
  parameter int SAMPLE_RATE  = 48_000,
  parameter int TONE_FREQ    = 1_000
)(
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       consume_i,   // one-cycle pulse: consume current 4-sample batch

  output logic [15:0] l0_o, r0_o,
  output logic [15:0] l1_o, r1_o,
  output logic [15:0] l2_o, r2_o,
  output logic [15:0] l3_o, r3_o,
  output logic        valid_o     // 4-sample batch ready
);

  // ── Sample-rate phase accumulator ─────────────────────────────────────────
  // Advances by SAMPLE_RATE each cycle.  When it would reach PIXEL_CLK_HZ,
  // it wraps and asserts emit_sample.  Both add paths stay within PHASE_W bits.
  localparam int PHASE_W = $clog2(PIXEL_CLK_HZ);  // 26 for 40 MHz

  logic [PHASE_W-1:0] r_phase;
  logic               r_emit;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      r_phase <= '0;
      r_emit  <= 1'b0;
    end else begin
      r_emit <= 1'b0;
      if (r_phase >= PHASE_W'(PIXEL_CLK_HZ - SAMPLE_RATE)) begin
        r_phase <= r_phase - PHASE_W'(PIXEL_CLK_HZ - SAMPLE_RATE);
        r_emit  <= 1'b1;
      end else begin
        r_phase <= r_phase + PHASE_W'(SAMPLE_RATE);
      end
    end
  end

  // ── 1 kHz square wave ─────────────────────────────────────────────────────
  localparam int SAMPLES_PER_PERIOD = SAMPLE_RATE / TONE_FREQ;  // 48
  localparam int HALF_PERIOD        = SAMPLES_PER_PERIOD / 2;   // 24
  localparam int TONE_CNT_W         = $clog2(SAMPLES_PER_PERIOD);  // 6

  logic [TONE_CNT_W-1:0] r_tone_cnt;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      r_tone_cnt <= '0;
    end else if (r_emit) begin
      r_tone_cnt <= (r_tone_cnt == TONE_CNT_W'(SAMPLES_PER_PERIOD - 1))
                  ? '0
                  : r_tone_cnt + 1'b1;
    end
  end

  wire [15:0] w_tone = (r_tone_cnt < TONE_CNT_W'(HALF_PERIOD))
                     ? 16'h4000    // +16384
                     : 16'hC000;  // -16384

  // ── 4-sample accumulator ──────────────────────────────────────────────────
  logic [15:0] r_buf_l [0:3];
  logic [15:0] r_buf_r [0:3];
  logic [2:0]  r_fill;  // 0..4; valid when == 4

  assign valid_o = (r_fill == 3'd4);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      r_fill  <= '0;
      r_buf_l <= '{default: '0};
      r_buf_r <= '{default: '0};
    end else if (consume_i) begin
      r_fill <= '0;
    end else if (r_emit && r_fill < 3'd4) begin
      r_buf_l[r_fill[1:0]] <= w_tone;
      r_buf_r[r_fill[1:0]] <= w_tone;
      r_fill <= r_fill + 1'b1;
    end
  end

  assign l0_o = r_buf_l[0];  assign r0_o = r_buf_r[0];
  assign l1_o = r_buf_l[1];  assign r1_o = r_buf_r[1];
  assign l2_o = r_buf_l[2];  assign r2_o = r_buf_r[2];
  assign l3_o = r_buf_l[3];  assign r3_o = r_buf_r[3];

endmodule
`endif
