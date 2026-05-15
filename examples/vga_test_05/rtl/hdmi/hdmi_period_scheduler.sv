`ifndef HDMI_PERIOD_SCHEDULER_SV
`define HDMI_PERIOD_SCHEDULER_SV

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
  parameter bit ENABLE_DATA_ISLAND = 1,
  // Restrict data islands to vertical blanking only (debug: some monitors
  // reject data islands sent during active-line hblank periods).
  parameter bit VBLANK_ONLY        = 0,
  // T1/T2/T3 phase-isolation diagnostic (0=normal):
  //   1 = T1: preamble only      (no guard / payload)
  //   2 = T2: preamble + guards  (no payload)
  //   3 = T3: preamble + guards + 1 payload symbol
  parameter int DEBUG_ISLAND_PHASES = 0
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

    // Pipeline alignment: trigger T is the posedge when blank_remaining_rr = VIDEO_TRIG (N).
    //
    // blank_remaining path (3 stages, so blank_remaining_rr[T] = H_TOTAL - h_cnt[T-3]):
    //   blank_remaining_comb → blank_remaining_o (vtg reg, 1)
    //   blank_remaining_o    → blank_remaining_r  (hdmi stage-1, 1)
    //   blank_remaining_r    → blank_remaining_rr (align reg, 1)
    //   blank_remaining_rr[T] = N  →  de_comb = 1 at T+N-3  (h_cnt wraps N cycles after T-3)
    //
    // DE path to de_r (also 3 stages — same depth as blank_remaining):
    //   de_comb → de_o          (vtg reg, 1)
    //   de_o    → active_video_o (vga_output_adapter, 1)
    //   active_video_o → de_r   (hdmi stage-1, 1)
    //   de_r becomes 1 at T+N-3+3 = T+N  (stable value from posedge T+N)
    //
    // TMDS encoder sees de_r (stable, set at T+N) at encoder stage-1 posedge T+N+1:
    //   enc stage-1: tmds_o_stage1 registered at T+N+1
    //   enc stage-2: tmds_o = TMDS(pixel[0]) registered at T+N+2
    //   channel_mux (1 reg): ch*_o = TMDS(pixel[0]) registered at T+N+3
    //
    // Period FSM (independent of N): VIDEO appears at ch*_o at T+13:
    //   period_o=VIDEO_PREAMBLE registered at T+1 (8 preamble cycles: T+1..T+8)
    //   period_o=VIDEO_GB       registered at T+9 (2 GB cycles: T+9..T+10)
    //   period_o=VIDEO          registered at T+11
    //   period_d1=VIDEO         registered at T+12  (1 extra delay)
    //   ch*_o=VIDEO             registered at T+13  (channel_mux output reg)
    //
    // Alignment: ch*_o has VIDEO at T+13, TMDS(pixel[0]) at T+N+3.
    //   T+N+3 = T+13  →  N = 10  →  VIDEO_TRIG = 10.
    //
    // Concrete trace for 800×600 (H_TOTAL=1056), T = P_{1049}:
    //   blank_remaining_rr = 10 at P_{1049}; de_comb=1 at P_{1049}+7=P0 (h_cnt=0)
    //   de_r=1 at P3=T+10; TMDS(pixel[0]) at P5=T+12; ch*_o[VIDEO+pixel[0]] at P6=T+13.
    //   period_o=VIDEO at P4=T+11; period_d1=VIDEO at P5; ch*_o=VIDEO at P6.
    //   Both VIDEO and TMDS(pixel[0]) arrive at ch*_o at P6 → ALIGNED. ✓
    localparam int PIPELINE_DELAY  = 6;
    // Trigger threshold: blank_remaining_i <= VIDEO_TRIG starts preamble FSM.
    // VIDEO_TRIG = VIDEO_PRE_TOTAL = 10.  See pipeline trace above.
    localparam int VIDEO_TRIG      = VIDEO_PRE_TOTAL;  // 10

    // HDMI spec §5.2.3: each Data Island Preamble must be preceded by at least
    // 8 TMDS clock cycles of Control Period.  Use 12 for margin.
    localparam int MIN_CTRL_PRE_ISLAND = 12;

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
    logic [4:0]   r_ctrl_cnt;

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
                       r_ctrl_cnt >= 5'(MIN_CTRL_PRE_ISLAND) &&
                       (!VBLANK_ONLY || vblank_i) &&
                       blank_remaining_i >= 16'(ISLAND_TOTAL + VIDEO_TRIG)) begin
            // Start data island only if enough room remains for island + video preamble
            // and spec-required minimum CONTROL period has elapsed.
            state_next     = ST_DATA_PREAMBLE;
            sym_cnt_next   = ($bits(sym_cnt_next))'(PREAMBLE_LEN - 1);
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
            sym_cnt_next = ($bits(sym_cnt_next))'(PREAMBLE_LEN - 1);
          end
        end

        ST_VIDEO_PREAMBLE: begin
          if (sym_cnt == 0) begin
            state_next   = ST_VIDEO_GB;
            sym_cnt_next = ($bits(sym_cnt_next))'(GUARD_LEN - 1);
          end else begin
            sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
          end
        end

        ST_VIDEO_GB: begin
          if (sym_cnt == 0)
            state_next = ST_VIDEO;
          else
            sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
        end

        ST_VIDEO: begin
          if (!de_i)
            state_next = ST_CONTROL;
        end

        ST_DATA_PREAMBLE: begin
          if (sym_cnt == 0) begin
            if (DEBUG_ISLAND_PHASES == 1) begin
              // T1: preamble only — return to control, skip guard/payload
              state_next = ST_CONTROL;
            end else begin
              state_next   = ST_DATA_GUARD_LEAD;
              sym_cnt_next = ($bits(sym_cnt_next))'(GUARD_LEN - 1);
            end
          end else begin
            sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
          end
        end

        ST_DATA_GUARD_LEAD: begin
          if (sym_cnt == 0) begin
            if (DEBUG_ISLAND_PHASES == 2) begin
              // T2: guards only — skip payload, jump to trailing guard
              state_next   = ST_DATA_GUARD_TRAIL;
              sym_cnt_next = ($bits(sym_cnt_next))'(GUARD_LEN - 1);
            end else begin
              // T3 (==3): load 1-symbol payload; normal (==0): full payload.
              state_next   = ST_DATA_PAYLOAD;
              sym_cnt_next = (DEBUG_ISLAND_PHASES == 3) ?
                             6'd0 :
                             ($bits(sym_cnt_next))'(PAYLOAD_LEN - 1);
              // Lookahead advance: push formatter one cycle early so that
              // symbol 0 clears the 2-cycle TERC4 + 1-cycle mux pipeline
              // before the first DATA_PAYLOAD cycle appears on ch*_o.
              packet_pop_o = 1'b1;
            end
          end else begin
            sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
          end
        end

        ST_DATA_PAYLOAD: begin
          // Advance only while there is a next symbol to prepare.
          // The last symbol (sym_cnt==0) is already in the TERC4 pipeline
          // from the previous cycle's advance.
          // T3 has sym_cnt==0 from the start, so no advance is issued.
          packet_pop_o = (DEBUG_ISLAND_PHASES == 0) ? (sym_cnt > 6'd1) : 1'b0;
          if (sym_cnt == 0) begin
            state_next   = ST_DATA_GUARD_TRAIL;
            sym_cnt_next = ($bits(sym_cnt_next))'(GUARD_LEN - 1);
          end else begin
            sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
          end
        end

        ST_DATA_GUARD_TRAIL: begin
          if (sym_cnt == 0)
            state_next = ST_CONTROL;
          else
            sym_cnt_next = ($bits(sym_cnt_next))'(sym_cnt - 1);
        end

        default: begin
          state_next = ST_CONTROL;
        end

      endcase
    end

    always_ff @(posedge clk_i) begin
      if (!rst_ni) begin
        state      <= ST_CONTROL;
        sym_cnt    <= '0;
        r_ctrl_cnt <= '0;
      end else begin
        state   <= state_next;
        sym_cnt <= sym_cnt_next;
        if (state == ST_CONTROL)
          r_ctrl_cnt <= (r_ctrl_cnt < 5'(MIN_CTRL_PRE_ISLAND)) ?
                        r_ctrl_cnt + 1'b1 : r_ctrl_cnt;
        else
          r_ctrl_cnt <= '0;
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

`endif // HDMI_PERIOD_SCHEDULER_SV
