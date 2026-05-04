`default_nettype none

import video_pkg::*;

// Counter-based video timing generator.
//
// pixel_req_o is asserted one cycle AHEAD of de_o so that a downstream
// frame aligner (with 1-cycle output register) has time to fetch the pixel
// before it is needed.  frame_start_o fires in the same cycle as the first
// pixel_req_o of a new frame.
//
// Additional outputs for HDMI scheduler and debug:
//   hblank_o          — horizontal blanking (any non-active column, v_active)
//   vblank_o          — vertical blanking (v_cnt >= V_ACTIVE)
//   last_active_x_o   — last column of each active line
//   last_active_pixel_o — last pixel of the frame
//   h_cnt_o / v_cnt_o — full raster counters
module video_timing_generator #(
  parameter int H_ACTIVE   = 800,
  parameter int H_FP       = 40,
  parameter int H_SYNC     = 128,
  parameter int H_BP       = 88,
  parameter int V_ACTIVE   = 600,
  parameter int V_FP       = 1,
  parameter int V_SYNC     = 4,
  parameter int V_BP       = 23,
  parameter bit HSYNC_POL  = 1'b1,   // 1 = active-high
  parameter bit VSYNC_POL  = 1'b1
)(
  input  logic clk_i,
  input  logic rst_ni,

  // Primary outputs (registered, 1-cycle latency from counters)
  output logic de_o,
  output logic hsync_o,
  output logic vsync_o,
  output logic pixel_req_o,     // 1 cycle ahead of de_o (look-ahead request)
  output logic frame_start_o,   // fires with first pixel_req_o of each frame
  output logic line_start_o,    // fires with first pixel_req_o of each active line
  output logic [$clog2(H_ACTIVE)-1:0] x_o,
  output logic [$clog2(V_ACTIVE)-1:0] y_o,

  // Extended outputs for HDMI scheduler and frame aligner sync checks
  output logic hblank_o,
  output logic vblank_o,
  output logic last_active_x_o,      // last active column (registered, same phase as de_o)
  output logic last_active_pixel_o,  // last active pixel of frame
  output logic [$clog2(H_ACTIVE + H_FP + H_SYNC + H_BP)-1:0] h_cnt_o,
  output logic [$clog2(V_ACTIVE + V_FP + V_SYNC + V_BP)-1:0] v_cnt_o
);

  localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
  localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

  logic [$clog2(H_TOTAL)-1:0] h_cnt;
  logic [$clog2(V_TOTAL)-1:0] v_cnt;

  // ── Counters ──────────────────────────────────────────────────────────────
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      h_cnt <= '0;
      v_cnt <= '0;
    end else begin
      if (h_cnt == H_TOTAL - 1) begin
        h_cnt <= '0;
        if (v_cnt == V_TOTAL - 1)
          v_cnt <= '0;
        else
          v_cnt <= v_cnt + 1;
      end else begin
        h_cnt <= h_cnt + 1;
      end
    end
  end

  // ── Combinational windows (current counters) ──────────────────────────────
  wire h_active = (h_cnt < H_ACTIVE);
  wire v_active = (v_cnt < V_ACTIVE);
  wire de       = h_active && v_active;

  wire hsync_active = (h_cnt >= H_ACTIVE + H_FP) && (h_cnt < H_ACTIVE + H_FP + H_SYNC);
  wire vsync_active = (v_cnt >= V_ACTIVE + V_FP) && (v_cnt < V_ACTIVE + V_FP + V_SYNC);

  // ── Look-ahead: next-cycle counter values ─────────────────────────────────
  logic [$clog2(H_TOTAL)-1:0] h_next;
  logic [$clog2(V_TOTAL)-1:0] v_next;

  always_comb begin
    if (h_cnt == H_TOTAL - 1) begin
      h_next = '0;
      v_next = (v_cnt == V_TOTAL - 1) ? '0 : v_cnt + 1'b1;
    end else begin
      h_next = h_cnt + 1'b1;
      v_next = v_cnt;
    end
  end

  wire de_next          = (h_next < H_ACTIVE) && (v_next < V_ACTIVE);
  wire frame_start_next = (h_next == '0) && (v_next == '0);
  wire line_start_next  = (h_next == '0) && (v_next < V_ACTIVE);

  // ── Registered outputs ────────────────────────────────────────────────────
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      de_o                <= 1'b0;
      hsync_o             <= ~HSYNC_POL;
      vsync_o             <= ~VSYNC_POL;
      pixel_req_o         <= 1'b0;
      frame_start_o       <= 1'b0;
      line_start_o        <= 1'b0;
      hblank_o            <= 1'b0;
      vblank_o            <= 1'b0;
      last_active_x_o     <= 1'b0;
      last_active_pixel_o <= 1'b0;
      x_o                 <= '0;
      y_o                 <= '0;
      h_cnt_o             <= '0;
      v_cnt_o             <= '0;
    end else begin
      de_o                <= de;
      hsync_o             <= hsync_active ? HSYNC_POL : ~HSYNC_POL;
      vsync_o             <= vsync_active ? VSYNC_POL : ~VSYNC_POL;
      pixel_req_o         <= de_next;
      frame_start_o       <= frame_start_next;
      line_start_o        <= line_start_next;
      hblank_o            <= ~de && v_active;
      vblank_o            <= ~v_active;
      last_active_x_o     <= de && (h_cnt == H_ACTIVE - 1);
      last_active_pixel_o <= de && (h_cnt == H_ACTIVE - 1) && (v_cnt == V_ACTIVE - 1);
      x_o                 <= h_active ? h_cnt[$clog2(H_ACTIVE)-1:0] : '0;
      y_o                 <= v_active ? v_cnt[$clog2(V_ACTIVE)-1:0] : '0;
      h_cnt_o             <= h_cnt;
      v_cnt_o             <= v_cnt;
    end
  end

endmodule
