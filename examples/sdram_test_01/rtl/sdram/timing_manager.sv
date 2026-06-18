/**
 * @file timing_manager.sv  (v160)
 * @brief Per-bank timing manager s bank_can_rw výstupom pre pipeline.
 *
 * Zmeny oproti v150:
 *  [NEW] bank_can_rw[3:0] — per-bank can_readwrite signál
 *        Scheduler potrebuje vedieť či konkrétna banka má splnené
 *        tRCD bez ohľadu na to ktorá banka je aktuálne vybraná (bank port).
 *        Používa sa pre bank pipeline lookahead v memory_scheduler.
 */

`ifndef TIMING_MANAGER_SV
`define TIMING_MANAGER_SV

`default_nettype none

import sdram_pkg::*;

module timing_manager #(
  parameter int BANKS = 4,
  parameter int T_RCD = T_RCD_CYCLES,
  parameter int T_RP  = T_RP_CYCLES,
  parameter int T_RFC = T_RFC_CYCLES,
  parameter int T_RAS = T_RAS_CYCLES,
  parameter int T_WR  = 2,
  parameter int T_RDL = CAS_LATENCY + 1,
  parameter int T_WTR = T_WTR_CYCLES  // z sdram_pkg — zmenené v160 na 1
)(
  input  wire clk,
  input  wire rstn,
  input  wire [1:0] bank,

  input  wire issue_activate,
  input  wire issue_precharge,
  input  wire issue_refresh,
  input  wire issue_write,
  input  wire issue_read,

  output logic        can_readwrite,   // Pre aktuálnu banku (bank port)
  output logic        can_activate,    // Pre aktuálnu banku
  output logic        can_precharge,   // Pre aktuálnu banku
  output logic [3:0]  bank_can_rw      // [NEW] Per-bank can_readwrite
);

  localparam int TRCD_W = $clog2(T_RCD+1);
  localparam int TRP_W  = $clog2(T_RP+1);
  localparam int TRAS_W = $clog2(T_RAS+1);
  localparam int TRFC_W = $clog2(T_RFC+1);

  logic [TRCD_W-1:0] trcd_timer [BANKS];
  logic [TRP_W-1:0]  trp_timer  [BANKS];
  logic [TRAS_W-1:0] tras_timer [BANKS];
  logic [TRFC_W-1:0] trfc_timer;
  logic [3:0]        twtr_timer;
  logic [3:0]        twr_timer;
  logic [3:0]        trdl_timer;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      for (int i = 0; i < BANKS; i++) begin
        trcd_timer[i] <= '0;
        trp_timer[i]  <= '0;
        tras_timer[i] <= '0;
      end
      trfc_timer <= '0;
      twtr_timer <= '0;
      twr_timer  <= '0;
      trdl_timer <= '0;
    end else begin
      for (int i = 0; i < BANKS; i++) begin
        if (trcd_timer[i] != '0) trcd_timer[i] <= trcd_timer[i] - 1;
        if (trp_timer[i]  != '0) trp_timer[i]  <= trp_timer[i]  - 1;
        if (tras_timer[i] != '0) tras_timer[i] <= tras_timer[i] - 1;
      end
      if (trfc_timer != '0) trfc_timer <= trfc_timer - 1;
      if (twtr_timer != '0) twtr_timer <= twtr_timer - 1;
      if (twr_timer  != '0) twr_timer  <= twr_timer  - 1;
      if (trdl_timer != '0) trdl_timer <= trdl_timer - 1;

      if (issue_activate) begin
        trcd_timer[bank] <= TRCD_W'(T_RCD);
        tras_timer[bank] <= TRAS_W'(T_RAS);
      end
      if (issue_precharge) trp_timer[bank]  <= TRP_W'(T_RP);
      if (issue_refresh)   trfc_timer       <= TRFC_W'(T_RFC);
      if (issue_write) begin
        twr_timer  <= 4'(T_WR);
        twtr_timer <= 4'(T_WTR);
      end
      if (issue_read) trdl_timer <= 4'(T_RDL);
    end
  end

  // Výstupy pre aktuálnu banku (bank port)
  assign can_readwrite =
    trcd_timer[bank] == '0 &&
    trfc_timer       == '0 &&
    twtr_timer       == '0;

  assign can_activate =
    trp_timer[bank] == '0 &&
    trfc_timer      == '0;

  assign can_precharge =
    tras_timer[bank] == '0 &&
    twr_timer        == '0 &&
    trdl_timer       == '0 &&
    trfc_timer       == '0;

  // [NEW] Per-bank can_readwrite pre pipeline lookahead
  // Globálne timery (twtr, trfc) sú spoločné pre všetky banky
  generate
    for (genvar i = 0; i < BANKS; i++) begin : g_bank_can_rw
      assign bank_can_rw[i] =
        trcd_timer[i] == '0 &&
        trfc_timer    == '0 &&
        twtr_timer    == '0;
    end
  endgenerate

endmodule
`endif
