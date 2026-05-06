`default_nettype none

import hdmi_pkg::*;

// HDMI period scheduler FSM.
//
// In DVI-compatible mode (ENABLE_DATA_ISLAND=0) the FSM only switches
// between CONTROL and VIDEO.  With ENABLE_DATA_ISLAND=1 it inserts the
// full preamble → leading-guard → payload → trailing-guard sequence during
// horizontal blanking when a packet is pending.
//
// blank_remaining_i guards data island insertion: a data island is started
// only if there are enough blanking cycles left to complete it before DE.
//
// Data-island timing (pixel clocks):
//   preamble     : 8 symbols
//   leading GB   : 2 symbols
//   payload      : 32 symbols
//   trailing GB  : 2 symbols
//   total        : 44 symbols
module hdmi_period_scheduler #(
  parameter bit ENABLE_DATA_ISLAND = 1
)(
  input  logic clk_i,
  input  logic rst_ni,

  // From video stream
  input  logic        de_i,               // display enable (active video)
  input  logic        hblank_i,           // horizontal blank (de=0 and not vblank)
  input  logic        vblank_i,           // vertical blank

  // Blanking budget guard (from video_timing_generator.blank_remaining_o)
  input  logic [15:0] blank_remaining_i,  // pixel clocks until next active video

  // Data-island handshake
  input  logic packet_pending_i,  // a packet is ready to send
  output logic packet_start_o,    // pulse: begin reading packet data
  output logic packet_pop_o,      // pulse: advance packet read pointer

  // Current HDMI period
  output hdmi_period_t period_o
);

  localparam int PREAMBLE_LEN  = 8;
  localparam int GUARD_LEN     = 2;
  localparam int PAYLOAD_LEN   = 32;
  // Total data-island budget: preamble + 2×guard + payload
  localparam int ISLAND_TOTAL  = PREAMBLE_LEN + 2 * GUARD_LEN + PAYLOAD_LEN; // 44

  generate

  // ── DVI-only fast path ────────────────────────────────────────────────────
  if (!ENABLE_DATA_ISLAND) begin : gen_dvi
    always_ff @(posedge clk_i) begin
      if (!rst_ni)
        period_o <= HDMI_PERIOD_CONTROL;
      else
        period_o <= de_i ? HDMI_PERIOD_VIDEO : HDMI_PERIOD_CONTROL;
    end
    assign packet_start_o = 1'b0;
    assign packet_pop_o   = 1'b0;
  end

  // ── Full HDMI scheduler ───────────────────────────────────────────────────
  if (ENABLE_DATA_ISLAND) begin : gen_hdmi

    // Video preamble budget: 8-symbol preamble + 2-symbol guard band = 10 scheduler cycles.
    localparam int VIDEO_PRE_TOTAL = PREAMBLE_LEN + GUARD_LEN;  // 10

    // Pipeline from blank_remaining_rr (scheduler input) to ch*_o:
    //   state_next → state / period_o (1 reg)
    //   period_o → period_d1 (1 reg)
    //   period_d1 → channel_mux output / ch*_o (1 reg)
    //   Total scheduler-to-output: 3 cycles
    //
    // Pipeline from blank_remaining_comb to blank_remaining_rr:
    //   blank_remaining_comb → blank_remaining_o (vtg reg, 1)
    //   blank_remaining_o → blank_remaining_r (hdmi stage-1, 1)
    //   blank_remaining_r → blank_remaining_rr (align reg, 1)
    //   Total: 3 cycles — so blank_remaining_rr = N means N+3 posedges until de_comb rises.
    //
    // Video data path from de_comb to first valid TMDS at ch*_o:
    //   de_comb → de_o (vtg, 1) → active_video_o (vga_output_adapter, 1)
    //   → de_r (stage-1, 1) → encoder stage-1 (1) → encoder stage-2 (1)
    //   → channel_mux / ch*_o (1) = 6 cycles
    //
    // At blank_remaining_rr = VIDEO_TRIG (trigger posedge T):
    //   de_comb rises at T + VIDEO_TRIG + 3 posedges (3 lag from blank_remaining pipeline)
    //   Preamble+GB = VIDEO_PRE_TOTAL = 10 scheduler cycles → ch*_o shows VIDEO at T + 10 + 3
    //   TMDS(pixel[0]) arrives at ch*_o at de_comb_rise + 6 = T + VIDEO_TRIG + 3 + 6
    //
    // For alignment: T + 10 + 3 = T + VIDEO_TRIG + 9
    //   → VIDEO_TRIG = 10 + 3 - 9 = 4? No — let's count from first principles.
    //
    // Concrete trace (800×600, H_TOTAL=1056):
    //   P_{1049}: blank_remaining_rr becomes 10; de_comb is still 0; triggers VIDEO_PREAMBLE.
    //   Preamble runs P_{1049}..P_{1056}=P0 (8 cyc), GB runs P0,P1 (2 cyc): VIDEO at ch*_o at P0+3.
    //   de_comb=1 at P0; TMDS(pixel[0]) at ch*_o at P0+6.
    //   VIDEO too early by 3 cycles → VIDEO_TRIG=10 was wrong.
    //
    //   With blank_remaining_rr = 9 at P_{1050}:
    //   Preamble P_{1050}..P_{1057}=P1 (8 cyc), GB P1,P2 (2 cyc): VIDEO at ch*_o at P1+3 = P4? No.
    //   Actually preamble lasts 8 registered cycles, counted by sym_cnt 7→0.
    //   Trigger at T=P_{1050}: state→VIDEO_PREAMBLE, period_o=VIDEO_PREAMBLE at P_{1051},
    //   period_d1=VIDEO_PREAMBLE at P_{1052}, ch*_o=PREAMBLE at P_{1053}.
    //   sym_cnt counts 7→0 over 8 cycles; ST_VIDEO_GB entered at T+8=P_{1058}=P2.
    //   period_o=VIDEO_GB at P2+1=P3, period_d1 at P4, ch*_o VIDEO_GB at P5.
    //   sym_cnt 1→0 for GB (2 cycles); ST_VIDEO entered at T+10=P_{1060}=P4.
    //   period_o=VIDEO at P5, period_d1 at P6, ch*_o VIDEO at P6.
    //   TMDS(pixel[0]) = encoder(de_r=1 at P2) out at P2+2=P4, ch*_o at P5? No, mux adds 1 → P6.
    //   Wait: de_comb=1 at P0; de_o=1 at P1; vga_out=1 at P2; de_r=1 at P3;
    //         enc stage-1 at P4; enc stage-2=tmds_o at P5; ch*_o at P6.
    //   VIDEO period at ch*_o = P6; TMDS(pixel[0]) at ch*_o = P6 → ALIGNED.
    //
    // Therefore VIDEO_TRIG = VIDEO_PRE_TOTAL - 1 = 9.
    localparam int PIPELINE_DELAY  = 6;
    // Trigger threshold: blank_remaining_i <= VIDEO_TRIG starts preamble FSM.
    // VIDEO_TRIG = VIDEO_PRE_TOTAL - 1 = 9.  See pipeline trace above.
    localparam int VIDEO_TRIG      = VIDEO_PRE_TOTAL - 1;  // 9

    typedef enum logic [2:0] {
      ST_CONTROL,
      ST_VIDEO_PREAMBLE,
      ST_VIDEO_GB,
      ST_VIDEO,
      ST_DATA_PREAMBLE,
      ST_DATA_GUARD_LEAD,
      ST_DATA_PAYLOAD,
      ST_DATA_GUARD_TRAIL
    } sched_state_t;

    sched_state_t state, state_next;
    logic [5:0]   sym_cnt, sym_cnt_next;

    always_comb begin
      state_next    = state;
      sym_cnt_next  = sym_cnt;
      packet_start_o = 1'b0;
      packet_pop_o   = 1'b0;

      unique case (state)

        ST_CONTROL: begin
          if (de_i) begin
            // Arrived at DE without preamble (shouldn't happen in normal flow,
            // but handle gracefully — e.g. first frame after reset)
            state_next = ST_VIDEO;
          end else if (hblank_i && packet_pending_i &&
                       blank_remaining_i >= 16'(ISLAND_TOTAL + VIDEO_TRIG)) begin
            // Start data island only if enough room remains for island + video preamble
            state_next     = ST_DATA_PREAMBLE;
            sym_cnt_next   = PREAMBLE_LEN - 1;
            packet_start_o = 1'b1;
          end else if (hblank_i &&
                       blank_remaining_i != 16'd0 &&
                       blank_remaining_i <= 16'(VIDEO_TRIG)) begin
            // VIDEO_TRIG cycles before h_cnt=0: enter video preamble.
            // Use <= (not ==) so the trigger fires even when a data island ends
            // one cycle late (blank_remaining passes through VIDEO_TRIG by 1
            // and the scheduler re-enters ST_CONTROL at VIDEO_TRIG-1).
            // blank_remaining != 0 guards against spurious trigger during active video.
            state_next   = ST_VIDEO_PREAMBLE;
            sym_cnt_next = PREAMBLE_LEN - 1;
          end
        end

        ST_VIDEO_PREAMBLE: begin
          if (sym_cnt == 0) begin
            state_next   = ST_VIDEO_GB;
            sym_cnt_next = GUARD_LEN - 1;
          end else begin
            sym_cnt_next = sym_cnt - 1;
          end
        end

        ST_VIDEO_GB: begin
          if (sym_cnt == 0)
            state_next = ST_VIDEO;
          else
            sym_cnt_next = sym_cnt - 1;
        end

        ST_VIDEO: begin
          if (!de_i)
            state_next = ST_CONTROL;
        end

        ST_DATA_PREAMBLE: begin
          if (sym_cnt == 0) begin
            state_next   = ST_DATA_GUARD_LEAD;
            sym_cnt_next = GUARD_LEN - 1;
          end else begin
            sym_cnt_next = sym_cnt - 1;
          end
        end

        ST_DATA_GUARD_LEAD: begin
          if (sym_cnt == 0) begin
            state_next   = ST_DATA_PAYLOAD;
            sym_cnt_next = PAYLOAD_LEN - 1;
          end else begin
            sym_cnt_next = sym_cnt - 1;
          end
        end

        ST_DATA_PAYLOAD: begin
          packet_pop_o = 1'b1;
          if (sym_cnt == 0) begin
            state_next   = ST_DATA_GUARD_TRAIL;
            sym_cnt_next = GUARD_LEN - 1;
          end else begin
            sym_cnt_next = sym_cnt - 1;
          end
        end

        ST_DATA_GUARD_TRAIL: begin
          if (sym_cnt == 0)
            state_next = ST_CONTROL;
          else
            sym_cnt_next = sym_cnt - 1;
        end

      endcase
    end

    always_ff @(posedge clk_i) begin
      if (!rst_ni) begin
        state   <= ST_CONTROL;
        sym_cnt <= '0;
      end else begin
        state   <= state_next;
        sym_cnt <= sym_cnt_next;
      end
    end

    // Map FSM state to period type
    always_ff @(posedge clk_i) begin
      if (!rst_ni) begin
        period_o <= HDMI_PERIOD_CONTROL;
      end else begin
        unique case (state_next)
          ST_CONTROL:         period_o <= HDMI_PERIOD_CONTROL;
          ST_VIDEO_PREAMBLE:  period_o <= HDMI_PERIOD_VIDEO_PREAMBLE;
          ST_VIDEO_GB:        period_o <= HDMI_PERIOD_VIDEO_GB;
          ST_VIDEO:           period_o <= HDMI_PERIOD_VIDEO;
          ST_DATA_PREAMBLE:   period_o <= HDMI_PERIOD_DATA_PREAMBLE;
          ST_DATA_GUARD_LEAD: period_o <= HDMI_PERIOD_DATA_GB_LEAD;
          ST_DATA_PAYLOAD:    period_o <= HDMI_PERIOD_DATA_PAYLOAD;
          ST_DATA_GUARD_TRAIL:period_o <= HDMI_PERIOD_DATA_GB_TRAIL;
          default:            period_o <= HDMI_PERIOD_CONTROL;
        endcase
      end
    end

  end // gen_hdmi

  endgenerate

endmodule
