`default_nettype none

import hdmi_pkg::*;

// HDMI packet scheduler FSM.
//
// Triggered by eof_i (end of frame), it serialises the queued packets
// (GCP + AVI InfoFrame + SPD InfoFrame + Audio InfoFrame) one byte at a
// time during vertical blanking.
//
// Fixes vs old packet_streamer:
//   - byte counter is logic[5:0] (not int), synthesises cleanly
//   - zero-length protection: skip packet if len == 0
//   - packet_ready_o indicates a byte is available for the data-island path
//   - packet_last_o pulses on the very last byte of the whole sequence
module packet_scheduler #(
  parameter int MAX_PAYLOAD = 32
)(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic eof_i,   // trigger: end of frame (start sending in vblank)

  // Pre-built packet inputs (from infoframe_builder instances)
  input  logic [7:0] header_avi  [3],
  input  logic [7:0] payload_avi [MAX_PAYLOAD],
  input  logic [5:0] len_avi,    // payload_len from builder (AVI_LENGTH+1)

  input  logic [7:0] header_spd  [3],
  input  logic [7:0] payload_spd [MAX_PAYLOAD],
  input  logic [5:0] len_spd,

  input  logic [7:0] header_audio[3],
  input  logic [7:0] payload_audio[MAX_PAYLOAD],
  input  logic [5:0] len_audio,

  // Output stream
  output logic [7:0] packet_o,
  output logic       packet_ready_o,
  output logic       packet_last_o,

  // Handshake: period_scheduler asserts consume_i during DATA_PAYLOAD to
  // advance the byte pointer by one position each clock cycle.
  input  logic       consume_i
);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_GCP_HEADER,
    ST_AVI_HEADER,  ST_AVI_PAYLOAD,
    ST_SPD_HEADER,  ST_SPD_PAYLOAD,
    ST_AUDIO_HEADER,ST_AUDIO_PAYLOAD
  } sched_state_t;

  sched_state_t  state, state_next;
  logic [5:0]    idx,   idx_next;

  // GCP header byte (General Control Packet, AVMUTE off)
  localparam logic [7:0] GCP_HEADER = 8'h03;
  localparam logic [7:0] GCP_BYTE0  = 8'h00;

  // ── Next-state / output logic ─────────────────────────────────────────────
  always_comb begin
    state_next     = state;
    idx_next       = idx;
    packet_o       = 8'h00;
    packet_ready_o = 1'b0;
    packet_last_o  = 1'b0;

    unique case (state)

      ST_IDLE: begin
        if (eof_i)
          state_next = ST_GCP_HEADER;
      end

      ST_GCP_HEADER: begin
        packet_ready_o = 1'b1;
        packet_o       = (idx == 0) ? GCP_HEADER : GCP_BYTE0;
        if (idx == 1) begin
          idx_next   = 6'd0;
          // Skip AVI header+payload entirely if disabled
          if      (len_avi   > 0) state_next = ST_AVI_HEADER;
          else if (len_spd   > 0) state_next = ST_SPD_HEADER;
          else if (len_audio > 0) state_next = ST_AUDIO_HEADER;
          else                    state_next = ST_IDLE;
        end else begin
          idx_next = idx + 1;
        end
      end

      ST_AVI_HEADER: begin
        packet_ready_o = 1'b1;
        packet_o       = header_avi[idx[1:0]];
        if (idx == 2) begin
          idx_next   = 6'd0;
          state_next = (len_avi > 0) ? ST_AVI_PAYLOAD :
                       (len_spd > 0) ? ST_SPD_HEADER :
                       (len_audio > 0) ? ST_AUDIO_HEADER : ST_IDLE;
        end else begin
          idx_next = idx + 1;
        end
      end

      ST_AVI_PAYLOAD: begin
        packet_ready_o = 1'b1;
        packet_o       = payload_avi[idx];
        if (idx == len_avi - 1) begin
          idx_next   = 6'd0;
          // Skip SPD header+payload if disabled
          if      (len_spd   > 0) state_next = ST_SPD_HEADER;
          else if (len_audio > 0) state_next = ST_AUDIO_HEADER;
          else                    state_next = ST_IDLE;
        end else begin
          idx_next = idx + 1;
        end
      end

      ST_SPD_HEADER: begin
        packet_ready_o = 1'b1;
        packet_o       = header_spd[idx[1:0]];
        if (idx == 2) begin
          idx_next   = 6'd0;
          state_next = (len_spd > 0) ? ST_SPD_PAYLOAD :
                       (len_audio > 0) ? ST_AUDIO_HEADER : ST_IDLE;
        end else begin
          idx_next = idx + 1;
        end
      end

      ST_SPD_PAYLOAD: begin
        packet_ready_o = 1'b1;
        packet_o       = payload_spd[idx];
        if (idx == len_spd - 1) begin
          idx_next   = 6'd0;
          // Skip Audio header+payload if disabled
          state_next = (len_audio > 0) ? ST_AUDIO_HEADER : ST_IDLE;
        end else begin
          idx_next = idx + 1;
        end
      end

      ST_AUDIO_HEADER: begin
        packet_ready_o = 1'b1;
        packet_o       = header_audio[idx[1:0]];
        if (idx == 2) begin
          idx_next   = 6'd0;
          state_next = (len_audio > 0) ? ST_AUDIO_PAYLOAD : ST_IDLE;
        end else begin
          idx_next = idx + 1;
        end
      end

      ST_AUDIO_PAYLOAD: begin
        packet_ready_o = 1'b1;
        packet_o       = payload_audio[idx];
        if (idx == len_audio - 1) begin
          packet_last_o = 1'b1;
          idx_next      = 6'd0;
          state_next    = ST_IDLE;
        end else begin
          idx_next = idx + 1;
        end
      end

      default: state_next = ST_IDLE;

    endcase
  end

  // ── Registers ─────────────────────────────────────────────────────────────
  // State and index only advance when consume_i is asserted (or on eof_i trigger).
  // This ensures the scheduler holds the current byte until the period_scheduler
  // signals that it has been consumed during DATA_PAYLOAD.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state <= ST_IDLE;
      idx   <= 6'd0;
    end else if (eof_i && state == ST_IDLE) begin
      state <= ST_GCP_HEADER;
      idx   <= 6'd0;
    end else if (packet_ready_o && consume_i) begin
      state <= state_next;
      idx   <= (state_next != state) ? 6'd0 : idx_next;
    end
  end

endmodule
