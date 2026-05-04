`default_nettype none

import video_pkg::*;

// Aligns an RGB565 AXI-stream (with SOF/EOL/EOF metadata) to the video
// timing generator's pixel_req and frame_start strobes.
//
// FSM states:
//   ST_SEARCH_SOF        — draining stream until a SOF pixel arrives (SOF is
//                          NOT consumed; it waits in FIFO for STREAM_FRAME)
//   ST_WAIT_FRAME_START  — SOF seen in FIFO, waiting for timing generator's
//                          frame_start_o strobe
//   ST_STREAM_FRAME      — streaming: pass pixels to output on pixel_req
//   ST_DROP_BROKEN_FRAME — underflow or sync error; drain to next SOF
//
// Output pixel_o is registered (1-cycle latency from pixel_req_i).
// pixel_req_i must arrive 1 cycle before de_i (from video_timing_generator
// look-ahead pixel_req_o) so that the registered pixel_o is ready in time.
//
// underflow_sticky_o latches until clear_errors_i is asserted.
module video_stream_frame_aligner #(
  parameter rgb565_t DEFAULT_COLOR = video_pkg::BLACK
)(
  input  logic clk_i,
  input  logic rst_ni,

  // From video_timing_generator (pixel_req_o fires 1 cycle before de_o)
  input  logic pixel_req_i,
  input  logic frame_start_i,
  input  logic de_i,
  input  logic last_active_x_i,      // optional: last active column (for EOL check)
  input  logic last_active_pixel_i,  // optional: last frame pixel (for EOF check)

  // Upstream stream (from FIFO)
  input  rgb565_t s_axis_data_i,
  input  logic    s_axis_valid_i,
  output logic    s_axis_ready_o,
  input  logic    s_axis_sof_i,
  input  logic    s_axis_eol_i,
  input  logic    s_axis_eof_i,

  // Output to display adapter
  output rgb565_t pixel_o,
  output logic    pixel_valid_o,

  // Status
  output logic synced_o,
  output logic underflow_o,         // pulse: one clock when underflow detected
  output logic underflow_sticky_o,  // latched; cleared by clear_errors_i
  output logic sync_error_o,        // pulse: unexpected SOF/EOL/EOF
  input  logic clear_errors_i
);

  typedef enum logic [1:0] {
    ST_SEARCH_SOF,
    ST_WAIT_FRAME_START,
    ST_STREAM_FRAME,
    ST_DROP_BROKEN_FRAME
  } state_t;

  state_t state, state_next;

  // ── FSM next-state logic ──────────────────────────────────────────────────
  always_comb begin
    state_next      = state;
    s_axis_ready_o  = 1'b0;
    underflow_o     = 1'b0;
    sync_error_o    = 1'b0;

    unique case (state)

      ST_SEARCH_SOF: begin
        // Drain non-SOF pixels; stop when SOF is at FIFO head (do not consume it)
        if (s_axis_valid_i) begin
          if (s_axis_sof_i) begin
            s_axis_ready_o = 1'b0;   // leave SOF in FIFO
            state_next     = ST_WAIT_FRAME_START;
          end else begin
            s_axis_ready_o = 1'b1;   // consume and discard non-SOF
          end
        end
      end

      ST_WAIT_FRAME_START: begin
        // SOF pixel is waiting at FIFO head.
        // If frame_start and pixel_req arrive simultaneously (look-ahead timing),
        // allow consuming the SOF pixel immediately so it is not missed.
        s_axis_ready_o = 1'b0;
        if (frame_start_i) begin
          state_next     = ST_STREAM_FRAME;
          s_axis_ready_o = pixel_req_i;
        end
      end

      ST_STREAM_FRAME: begin
        if (pixel_req_i) begin
          if (s_axis_valid_i) begin
            s_axis_ready_o = 1'b1;
            // Unexpected SOF mid-frame means stream and timing are out of sync
            if (s_axis_sof_i && !frame_start_i) begin
              sync_error_o = 1'b1;
              state_next   = ST_DROP_BROKEN_FRAME;
            end
          end else begin
            // Pixel requested but stream has nothing — underflow
            underflow_o  = 1'b1;
            state_next   = ST_DROP_BROKEN_FRAME;
          end
        end
      end

      ST_DROP_BROKEN_FRAME: begin
        // Drain until next SOF appears; do not consume the SOF itself
        if (s_axis_valid_i) begin
          if (s_axis_sof_i) begin
            s_axis_ready_o = 1'b0;
            state_next     = ST_WAIT_FRAME_START;
          end else begin
            s_axis_ready_o = 1'b1;
          end
        end
      end

    endcase
  end

  // ── State register ────────────────────────────────────────────────────────
  always_ff @(posedge clk_i) begin
    if (!rst_ni) state <= ST_SEARCH_SOF;
    else         state <= state_next;
  end

  // ── Output register ───────────────────────────────────────────────────────
  wire pixel_take = pixel_req_i && (state_next == ST_STREAM_FRAME) && s_axis_valid_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pixel_o       <= DEFAULT_COLOR;
      pixel_valid_o <= 1'b0;
    end else begin
      // pixel_valid_o is valid only when a real pixel was produced for DE
      pixel_valid_o <= pixel_take && de_i;
      if (pixel_req_i)
        pixel_o <= pixel_take ? s_axis_data_i : DEFAULT_COLOR;
      else if (!de_i)
        pixel_o <= DEFAULT_COLOR;
    end
  end

  // ── Status signals ────────────────────────────────────────────────────────
  assign synced_o = (state == ST_STREAM_FRAME);

  always_ff @(posedge clk_i) begin
    if (!rst_ni)
      underflow_sticky_o <= 1'b0;
    else if (underflow_o)
      underflow_sticky_o <= 1'b1;
    else if (clear_errors_i)
      underflow_sticky_o <= 1'b0;
  end

endmodule
