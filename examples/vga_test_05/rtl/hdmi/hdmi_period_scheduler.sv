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

    // Video preamble budget: 8-symbol preamble + 2-symbol guard band before DE
    localparam int VIDEO_PRE_TOTAL = PREAMBLE_LEN + GUARD_LEN;  // 10

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
                       blank_remaining_i >= 16'(ISLAND_TOTAL + VIDEO_PRE_TOTAL)) begin
            // Start data island only if enough room remains for island + video preamble
            state_next     = ST_DATA_PREAMBLE;
            sym_cnt_next   = PREAMBLE_LEN - 1;
            packet_start_o = 1'b1;
          end else if (hblank_i &&
                       blank_remaining_i == 16'(VIDEO_PRE_TOTAL)) begin
            // 10 cycles before DE: enter video preamble
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
