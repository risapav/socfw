/**
 * @file  xfcp_stream_mux.sv
 * @brief XFCP 2-way stream demux/mux -- routes fabric AXIS port to one of 2 adapters by stream_id.
 *
 * @details
 *   Sits between xfcp_fabric_endpoint (single AXIS port) and two xfcp_axis_adapter
 *   instances.  Routes each transaction to adapter[stream_id]; stream_id is taken
 *   from fab_req_hdr_i.addr[7:0].
 *
 *   If stream_id >= 2, the request is routed to adapter 0 which will reject it
 *   with UNSUPPORTED (because its STREAM_ID parameter != stream_id).
 *   The adapter also drains any STREAM_WRITE payload, so the endpoint stays
 *   in a consistent state.
 *
 *   At most one AXIS transaction is in flight at a time (enforced by
 *   xfcp_fabric_endpoint.axis_busy_q).  Therefore a single active_q register
 *   is sufficient to track which adapter is currently serving a request.
 *
 * @param CLK_W  Unused width placeholder kept for tool compatibility.
 */

`ifndef XFCP_STREAM_MUX_SV
`define XFCP_STREAM_MUX_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_stream_mux (
  input wire clk,
  input wire rst_n,

  // ── Fabric-side (connects to xfcp_fabric_endpoint) ─────────────
  input  logic          fab_req_valid_i,
  output logic          fab_req_ready_o,
  input  xfcp_req_hdr_t fab_req_hdr_i,

  input  logic [31:0]   fab_wdata_i,
  input  logic          fab_wdata_valid_i,
  output logic          fab_wdata_ready_o,

  output logic [31:0]   fab_rdata_o,
  output logic          fab_rdata_valid_o,
  input  logic          fab_rdata_ready_i,

  output logic          fab_resp_done_o,
  output logic [7:0]    fab_resp_status_o,

  // ── Adapter 0 (stream_id = 0) ────────────────────────────────────
  output logic          a0_req_valid_o,
  input  logic          a0_req_ready_i,
  output xfcp_req_hdr_t a0_req_hdr_o,

  output logic [31:0]   a0_wdata_o,
  output logic          a0_wdata_valid_o,
  input  logic          a0_wdata_ready_i,

  input  logic [31:0]   a0_rdata_i,
  input  logic          a0_rdata_valid_i,
  output logic          a0_rdata_ready_o,

  input  logic          a0_resp_done_i,
  input  logic [7:0]    a0_resp_status_i,

  // ── Adapter 1 (stream_id = 1) ────────────────────────────────────
  output logic          a1_req_valid_o,
  input  logic          a1_req_ready_i,
  output xfcp_req_hdr_t a1_req_hdr_o,

  output logic [31:0]   a1_wdata_o,
  output logic          a1_wdata_valid_o,
  input  logic          a1_wdata_ready_i,

  input  logic [31:0]   a1_rdata_i,
  input  logic          a1_rdata_valid_i,
  output logic          a1_rdata_ready_o,

  input  logic          a1_resp_done_i,
  input  logic [7:0]    a1_resp_status_i
);

  // ── Routing ────────────────────────────────────────────────────────
  // sel_w: which adapter handles the incoming request.
  // stream_id is in addr[7:0].  For sid>=2, route to adapter 0 (will UNSUPPORTED).
  wire [7:0] req_sid_w = fab_req_hdr_i.addr[7:0];
  wire       sel_w     = (req_sid_w == 8'd1) ? 1'b1 : 1'b0;

  // active_q: adapter selected for the transaction currently in flight.
  // Updated when a request is accepted (fab_req_valid && fab_req_ready).
  logic active_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      active_q <= 1'b0;
    else if (fab_req_valid_i && fab_req_ready_o)
      active_q <= sel_w;
  end

  // ── REQ dispatch (combinational, sel_w from current req header) ──
  assign a0_req_valid_o = fab_req_valid_i && !sel_w;
  assign a1_req_valid_o = fab_req_valid_i &&  sel_w;
  assign fab_req_ready_o = sel_w ? a1_req_ready_i : a0_req_ready_i;

  assign a0_req_hdr_o = fab_req_hdr_i;
  assign a1_req_hdr_o = fab_req_hdr_i;

  // ── WDATA dispatch (active_q set on cycle AFTER req accepted) ────
  // wdata always starts at least 1 cycle after req acceptance, so
  // active_q is stable when the first wdata word arrives.
  assign a0_wdata_o       = fab_wdata_i;
  assign a1_wdata_o       = fab_wdata_i;
  assign a0_wdata_valid_o = fab_wdata_valid_i && !active_q;
  assign a1_wdata_valid_o = fab_wdata_valid_i &&  active_q;
  assign fab_wdata_ready_o = active_q ? a1_wdata_ready_i : a0_wdata_ready_i;

  // ── RDATA mux (from active adapter back to fabric) ─────────────
  assign fab_rdata_o        = active_q ? a1_rdata_i        : a0_rdata_i;
  assign fab_rdata_valid_o  = active_q ? a1_rdata_valid_i  : a0_rdata_valid_i;
  assign a0_rdata_ready_o   = fab_rdata_ready_i && !active_q;
  assign a1_rdata_ready_o   = fab_rdata_ready_i &&  active_q;

  // ── RESP mux (only one adapter fires resp_done at a time) ────────
  // fab_resp_status_o uses active_q (not resp_done) because the fabric endpoint
  // samples status one cycle after resp_done; active_q stays stable through both.
  assign fab_resp_done_o   = a0_resp_done_i | a1_resp_done_i;
  assign fab_resp_status_o = active_q ? a1_resp_status_i : a0_resp_status_i;

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (fab_req_valid_i && fab_req_ready_o)
        $display("[%0t] %m: REQ dispatch sid=%0d -> adp%0d",
                 $time, req_sid_w, sel_w);
      if (a0_resp_done_i)
        $display("[%0t] %m: RESP adp0 status=0x%02h", $time, a0_resp_status_i);
      if (a1_resp_done_i)
        $display("[%0t] %m: RESP adp1 status=0x%02h", $time, a1_resp_status_i);
    end
  end
  // synthesis translate_on

endmodule : xfcp_stream_mux

`endif // XFCP_STREAM_MUX_SV
