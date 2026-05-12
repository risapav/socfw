`ifndef HDMI_PACKET_ARBITER_SV
`define HDMI_PACKET_ARBITER_SV

`default_nettype none

// HDMI packet arbiter — serialises multiple packet sources into one
// data_island_formatter slot per frame.
//
// Packet order each frame (triggered by vsync_i rising edge):
//   1. GCP  (General Control Packet)
//   2. AVI  InfoFrame
//   3. ACR  (Audio Clock Regeneration) — only if valid_acr_i is high
//
// The arbiter presents the current packet's hb/pb on its outputs and
// asserts packet_valid_o.  The scheduler fires packet_start_i to begin
// each data island; the arbiter then advances to the next packet.
//
// All hb/pb inputs are combinational (from static builders); the arbiter
// simply muxes them based on current state.
module hdmi_packet_arbiter (
  input  logic clk_i,
  input  logic rst_ni,

  // Sync for per-frame trigger (in pix_clk domain, already registered)
  input  logic vsync_i,

  // Packet sources (combinational)
  input  logic [7:0] hb_gcp_i [0:2],
  input  logic [7:0] pb_gcp_i [0:27],
  input  logic [7:0] hb_avi_i [0:2],
  input  logic [7:0] pb_avi_i [0:27],
  input  logic [7:0] hb_acr_i [0:2],
  input  logic [7:0] pb_acr_i [0:27],
  input  logic       valid_acr_i,

  // Handshake with hdmi_period_scheduler
  output logic       packet_valid_o,  // a packet is ready; drives packet_pending_i
  input  logic       packet_start_i,  // pulse: scheduler accepted the packet (DATA_PREAMBLE entry)

  // Muxed outputs to data_island_formatter
  output logic [7:0] hb_o [0:2],
  output logic [7:0] pb_o [0:27]
);

  // ── Per-frame trigger ─────────────────────────────────────────────────────
  logic vsync_prev;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) vsync_prev <= 1'b0;
    else         vsync_prev <= vsync_i;
  end
  wire vsync_rise = vsync_i && !vsync_prev;

  // ── FSM ───────────────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    ARB_IDLE,     // no packets pending this frame
    ARB_GCP,      // GCP pending / being presented
    ARB_AVI,      // AVI pending / being presented
    ARB_ACR       // ACR pending / being presented (only when valid_acr_i)
  } arb_state_t;

  arb_state_t state;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state <= ARB_IDLE;
    end else begin
      case (state)
        ARB_IDLE: begin
          if (vsync_rise)
            state <= ARB_GCP;
        end

        ARB_GCP: begin
          if (packet_start_i)
            state <= ARB_AVI;
        end

        ARB_AVI: begin
          if (packet_start_i)
            state <= valid_acr_i ? ARB_ACR : ARB_IDLE;
        end

        ARB_ACR: begin
          if (packet_start_i)
            state <= ARB_IDLE;
        end

        default: state <= ARB_IDLE;
      endcase
    end
  end

  // ── Packet mux ────────────────────────────────────────────────────────────
  always_comb begin
    case (state)
      ARB_GCP: begin
        hb_o           = hb_gcp_i;
        pb_o           = pb_gcp_i;
        packet_valid_o = 1'b1;
      end
      ARB_AVI: begin
        hb_o           = hb_avi_i;
        pb_o           = pb_avi_i;
        packet_valid_o = 1'b1;
      end
      ARB_ACR: begin
        hb_o           = hb_acr_i;
        pb_o           = pb_acr_i;
        packet_valid_o = 1'b1;
      end
      default: begin
        hb_o           = '{default: 8'h00};
        pb_o           = '{default: 8'h00};
        packet_valid_o = 1'b0;
      end
    endcase
  end

endmodule

`endif
