`ifndef HDMI_PACKET_ARBITER_SV
`define HDMI_PACKET_ARBITER_SV

`default_nettype none

// HDMI packet arbiter — serialises packet sources into data_island_formatter.
//
// Per-frame sequence (triggered by frame_start_i one-cycle pulse):
//   GCP → AVI → ACR (if valid_acr_i) → Audio IF (if valid_audio_if_i)
//
// In ARB_IDLE state the arbiter presents audio sample packets whenever
// valid_sample_i is high.  This covers the remainder of each hblank period
// throughout the frame (not just the vsync blanking window).
// sample_consume_o fires for one cycle when an audio sample packet is accepted.
//
// All hb/pb inputs are combinational; the arbiter only muxes them.
module hdmi_packet_arbiter (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic frame_start_i,   // one-cycle pulse at start of frame (from vtg)

  // Packet sources (combinational)
  input  logic [7:0] hb_gcp_i [0:2],
  input  logic [7:0] pb_gcp_i [0:27],
  input  logic       valid_gcp_i,   // 0 = skip GCP this frame (debug)

  input  logic [7:0] hb_avi_i [0:2],
  input  logic [7:0] pb_avi_i [0:27],
  input  logic       valid_avi_i,   // 0 = skip AVI this frame (debug)

  input  logic [7:0] hb_acr_i [0:2],
  input  logic [7:0] pb_acr_i [0:27],
  input  logic       valid_acr_i,

  input  logic [7:0] hb_audio_if_i [0:2],
  input  logic [7:0] pb_audio_if_i [0:27],
  input  logic       valid_audio_if_i,

  input  logic [7:0] hb_sample_i [0:2],
  input  logic [7:0] pb_sample_i [0:27],
  input  logic       valid_sample_i,

  // Handshake with hdmi_period_scheduler
  output logic       packet_valid_o,   // drives packet_pending_i
  input  logic       packet_start_i,   // pulse: packet accepted (DATA_PREAMBLE entry)

  // Audio sample feedback
  output logic       sample_consume_o, // one-cycle pulse: advance audio sample FIFO

  // Muxed outputs to data_island_formatter
  output logic [7:0] hb_o [0:2],
  output logic [7:0] pb_o [0:27]
);

  // ── FSM ───────────────────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    ARB_IDLE,       // also presents audio sample packets when valid_sample_i
    ARB_GCP,
    ARB_AVI,
    ARB_ACR,
    ARB_AUDIO_IF
  } arb_state_t;

  arb_state_t r_state;

  // ── Audio-ready guard ─────────────────────────────────────────────────────
  // Prevents audio sample packets from being inserted before the first
  // complete per-frame sequence has been sent (ACR+AudioIF needed before
  // samples so the monitor has clock and format context).
  logic r_audio_ready;

  always_ff @(posedge clk_i) begin
    if (!rst_ni)
      r_audio_ready <= 1'b0;
    else if (!r_audio_ready) begin
      // Set after the highest-priority per-frame state that was enabled
      // completes (AudioIF → ACR-only → AVI-only fallback).
      // Also triggers when AVI is skipped (!valid_avi_i) with no audio path.
      if (r_state == ARB_AUDIO_IF && packet_start_i)
        r_audio_ready <= 1'b1;
      else if (r_state == ARB_ACR && packet_start_i && !valid_audio_if_i)
        r_audio_ready <= 1'b1;
      else if (r_state == ARB_AVI && (packet_start_i || !valid_avi_i) &&
               !valid_acr_i && !valid_audio_if_i)
        r_audio_ready <= 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      r_state <= ARB_IDLE;
    end else begin
      case (r_state)

        ARB_IDLE: begin
          // frame_start_i pulse starts the per-frame packet sequence (takes
          // priority over any in-progress audio sample)
          if (frame_start_i)
            r_state <= ARB_GCP;
          // else: stay in IDLE (audio sample packets handled combinatorially)
        end

        ARB_GCP: begin
          // Skip immediately when GCP is disabled; otherwise wait for acceptance.
          if (!valid_gcp_i || packet_start_i)
            r_state <= ARB_AVI;
        end

        ARB_AVI: begin
          // Skip immediately when AVI is disabled; otherwise wait for acceptance.
          if (!valid_avi_i || packet_start_i) begin
            if      (valid_acr_i)      r_state <= ARB_ACR;
            else if (valid_audio_if_i) r_state <= ARB_AUDIO_IF;
            else                       r_state <= ARB_IDLE;
          end
        end

        ARB_ACR: begin
          if (packet_start_i) begin
            if (valid_audio_if_i) r_state <= ARB_AUDIO_IF;
            else                  r_state <= ARB_IDLE;
          end
        end

        ARB_AUDIO_IF: begin
          if (packet_start_i)
            r_state <= ARB_IDLE;
        end

        default: r_state <= ARB_IDLE;
      endcase
    end
  end

  // ── Packet mux ────────────────────────────────────────────────────────────
  always_comb begin
    // Defaults
    hb_o           = '{default: 8'h00};
    pb_o           = '{default: 8'h00};
    packet_valid_o = 1'b0;
    sample_consume_o = 1'b0;

    case (r_state)
      ARB_IDLE: begin
        // Present audio sample packet only after per-frame init sequence done
        hb_o             = hb_sample_i;
        pb_o             = pb_sample_i;
        packet_valid_o   = valid_sample_i && r_audio_ready;
        sample_consume_o = packet_start_i;
      end
      ARB_GCP: begin
        hb_o           = hb_gcp_i;
        pb_o           = pb_gcp_i;
        packet_valid_o = valid_gcp_i;
      end
      ARB_AVI: begin
        hb_o           = hb_avi_i;
        pb_o           = pb_avi_i;
        packet_valid_o = valid_avi_i;
      end
      ARB_ACR: begin
        hb_o           = hb_acr_i;
        pb_o           = pb_acr_i;
        packet_valid_o = 1'b1;
      end
      ARB_AUDIO_IF: begin
        hb_o           = hb_audio_if_i;
        pb_o           = pb_audio_if_i;
        packet_valid_o = 1'b1;
      end
      default: ;
    endcase
  end

endmodule
`endif
