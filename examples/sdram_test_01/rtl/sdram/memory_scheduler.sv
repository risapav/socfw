/**
 * @file memory_scheduler.sv  (v160)
 * @brief SDRAM Scheduler s Bank Pipeliningom.
 *
 * Optimalizácie oproti v150:
 *
 *  [OPT-BANK-PIPELINE]
 *    Kým scheduler čaká na tRCD pre aktuálnu banku (ST_ACT_WAIT),
 *    môže vydať ACT pre inú banku z FIFO ak:
 *      - Iný príkaz v FIFO čaká na inú banku (bank != current_bank)
 *      - Tá banka je zatvorená a can_activate je splnené
 *    Implementácia: FIFO lookahead — ak head príkaz čaká (row-hit ale
 *    !can_readwrite), pozri či môžeš obsluhovať iný príkaz z FIFO.
 *
 *    Architektúra: scheduler má 2 "sloty":
 *      Slot A: aktuálne spracovávaný príkaz (latched_cmd)
 *      Slot B: paralelne aktivovaná banka (pipe_cmd)
 *    V ST_ACT_WAIT: ak FIFO head je iná banka → ACT ju (pipe_cmd)
 *    V ST_RW_ISSUE: ak pipe_cmd banka má splnené tRCD → môže ísť priamo RW
 *
 *  [OPT-OPEN-PAGE] zachovaná z v150
 */

`ifndef MEMORY_SCHEDULER_SV
`define MEMORY_SCHEDULER_SV

`default_nettype none

import sdram_pkg::*;

module memory_scheduler (
  input  wire                 clk,
  input  wire                 rstn,

  input  wire sdram_cmd_t     in_cmd,
  input  wire                 in_valid,
  output logic                in_ready,

  input  wire [3:0]           bank_row_hit,
  input  wire [3:0]           bank_open,
  output logic [3:0]          bank_do_act,
  output logic [3:0]          bank_do_pre,

  input  wire                 can_activate,
  input  wire                 can_readwrite,
  input  wire                 can_precharge,

  // Per-bank can_readwrite pre pipeline lookahead
  // timing_manager musí vystaviť can_rw pre každú banku
  input  wire [3:0]           bank_can_rw,

  input  wire                 refresh_req,
  output logic                refresh_grant,

  output phy_cmd_e            out_phy_cmd,
  output logic                out_valid,
  output logic                out_precharge_all,
  output logic                read_issue
);

  // ==========================================================================
  // FSM
  // ==========================================================================
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_ACT_WAIT,          // Čakanie tRCD po ACT (slot A)
    ST_ACT_WAIT_PIPE,     // [NEW] Čakanie tRCD, zároveň ACT-ujeme slot B
    ST_RW_ISSUE,          // Vydanie RD/WR pre slot A
    ST_PRE_WAIT_MISS,
    ST_PRE_ACT_MISS,
    ST_REF_PRE_WAIT,
    ST_REF_WAIT
  } state_e;

  state_e state, next_state;

  sdram_cmd_t latched_cmd;   // Slot A
  sdram_cmd_t pipe_cmd;      // Slot B — paralelne aktivovaná banka
  logic       pipe_valid;    // Slot B je platný

  logic       refresh_pending;

  wire [1:0] bank_sel  = in_cmd.addr.bank;
  wire [1:0] bank_latched = latched_cmd.addr.bank;

  // ==========================================================================
  // Latch logika
  // ==========================================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      latched_cmd <= '0;
      pipe_cmd    <= '0;
      pipe_valid  <= 1'b0;
    end else begin
      // Latch slot A pri prechode z IDLE
      if (state == ST_IDLE && in_valid && !refresh_pending) begin
        if (!bank_open[bank_sel] ||
            (bank_open[bank_sel] && !bank_row_hit[bank_sel])) begin
          latched_cmd <= in_cmd;
        end
      end

      // [OPT-BANK-PIPELINE] Latch slot B počas ST_ACT_WAIT
      // Podmienky: iná banka, zatvorená, can_activate, BEZ refresh_pending
      // Ak refresh_pending, nepipelinujeme — REF by zatvoril pipeline banku
      if (state == ST_ACT_WAIT &&
          in_valid &&
          !pipe_valid &&
          !refresh_pending &&
          in_cmd.addr.bank != bank_latched &&
          !bank_open[in_cmd.addr.bank] &&
          can_activate) begin
        pipe_cmd   <= in_cmd;
        pipe_valid <= 1'b1;
      end

      // Uvoľnenie slot B po RW_ISSUE
      if (state == ST_RW_ISSUE && can_readwrite)
        pipe_valid <= 1'b0;
    end
  end

  // ==========================================================================
  // Refresh tracking
  // ==========================================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      refresh_pending <= 1'b0;
    end else begin
      if (refresh_req)
        refresh_pending <= 1'b1;
      else if (state == ST_REF_WAIT && can_activate)
        refresh_pending <= 1'b0;
    end
  end

  // ==========================================================================
  // FSM kombinačná logika
  // ==========================================================================
  always_comb begin
    next_state        = state;
    out_phy_cmd       = CMD_NOP;
    out_valid         = 1'b0;
    out_precharge_all = 1'b0;
    in_ready          = 1'b0;
    bank_do_act       = 4'b0000;
    bank_do_pre       = 4'b0000;
    refresh_grant     = 1'b0;
    read_issue        = 1'b0;

    case (state)

      ST_IDLE: begin
        if (refresh_pending) begin
          if (|bank_open) begin
            if (can_precharge) begin
              out_phy_cmd       = CMD_PRE;
              out_valid         = 1'b1;
              out_precharge_all = 1'b1;
              bank_do_pre       = 4'b1111;
              next_state        = ST_REF_PRE_WAIT;
            end
          end else if (can_activate) begin
            out_phy_cmd   = CMD_REF;
            out_valid     = 1'b1;
            refresh_grant = 1'b1;
            next_state    = ST_REF_WAIT;
          end
        end
        else if (in_valid) begin
          // Row Hit → okamžitý RD/WR
          if (bank_open[bank_sel] && bank_row_hit[bank_sel]) begin
            if (can_readwrite) begin
              out_phy_cmd = in_cmd.write_en ? CMD_WR : CMD_RD;
              out_valid   = 1'b1;
              in_ready    = 1'b1;
              read_issue  = !in_cmd.write_en;
            end
          end
          // Banka zatvorená → ACT
          else if (!bank_open[bank_sel]) begin
            if (can_activate) begin
              out_phy_cmd           = CMD_ACT;
              out_valid             = 1'b1;
              bank_do_act[bank_sel] = 1'b1;
              next_state            = ST_ACT_WAIT;
            end
          end
          // Row Miss → PRE
          else begin
            if (can_precharge) begin
              out_phy_cmd           = CMD_PRE;
              out_valid             = 1'b1;
              bank_do_pre[bank_sel] = 1'b1;
              next_state            = ST_PRE_WAIT_MISS;
            end
          end
        end
      end

      // [OPT-BANK-PIPELINE] ST_ACT_WAIT: kým čakáme na tRCD banky A,
      // môžeme ACT-ovať banku B ak je v FIFO a zatvorená
      ST_ACT_WAIT: begin
        if (can_readwrite) begin
          next_state = ST_RW_ISSUE;
        end else if (in_valid &&
                     !pipe_valid &&
                     !refresh_pending &&
                     in_cmd.addr.bank != bank_latched &&
                     !bank_open[in_cmd.addr.bank] &&
                     can_activate) begin
          // [OPT-BANK-PIPELINE] Paralelný ACT pre inú banku
          // Len ak refresh nie je pending — REF by zatvoril otvorenú banku
          out_phy_cmd                        = CMD_ACT;
          out_valid                          = 1'b1;
          bank_do_act[in_cmd.addr.bank]      = 1'b1;
          next_state                         = ST_ACT_WAIT_PIPE;
        end
      end

      // [NEW] ST_ACT_WAIT_PIPE: čakáme na tRCD OBOCH bánk
      // can_readwrite sleduje tRCD pre FIFO head banku (slot A)
      // bank_can_rw[pipe_cmd.bank] sleduje tRCD pre slot B banku
      // Prechod do ST_RW_ISSUE len ak obe banky majú splnené tRCD
      ST_ACT_WAIT_PIPE: begin
        if (can_readwrite && bank_can_rw[pipe_cmd.addr.bank])
          next_state = ST_RW_ISSUE;
      end

      // ST_RW_ISSUE: vydaj RD/WR pre slot A (latched_cmd)
      // Slot B (pipe_cmd) bude spracovaný v ďalšom ST_IDLE cykle
      // s row-hit (banka je už otvorená)
      ST_RW_ISSUE: begin
        if (can_readwrite) begin
          out_phy_cmd = latched_cmd.write_en ? CMD_WR : CMD_RD;
          out_valid   = 1'b1;
          in_ready    = 1'b1;
          read_issue  = !latched_cmd.write_en;
          next_state  = ST_IDLE;
        end
      end

      ST_PRE_WAIT_MISS: begin
        if (can_activate)
          next_state = ST_PRE_ACT_MISS;
      end

      ST_PRE_ACT_MISS: begin
        if (can_activate) begin
          out_phy_cmd                        = CMD_ACT;
          out_valid                          = 1'b1;
          bank_do_act[latched_cmd.addr.bank] = 1'b1;
          next_state                         = ST_ACT_WAIT;
        end
      end

      ST_REF_PRE_WAIT: begin
        if (can_activate) begin
          out_phy_cmd   = CMD_REF;
          out_valid     = 1'b1;
          refresh_grant = 1'b1;
          next_state    = ST_REF_WAIT;
        end
      end

      ST_REF_WAIT: begin
        if (can_activate)
          next_state = ST_IDLE;
      end

      default: next_state = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) state <= ST_IDLE;
    else       state <= next_state;
  end

`ifdef ENABLE_ASSERTIONS
// ==========================================================================
// SVA — Funkcionálne assertions pre memory_scheduler
//
// Aktivácia: +define+ENABLE_ASSERTIONS v Questa
//   vlog ... +define+ENABLE_ASSERTIONS
//   alebo v Makefile: VLOG_FLAGS += +define+ENABLE_ASSERTIONS
// ==========================================================================

// --------------------------------------------------------------------------
// Pomocné signály pre assertions
// --------------------------------------------------------------------------
wire sva_cmd_wr   = out_valid && (out_phy_cmd == CMD_WR);
wire sva_cmd_rd   = out_valid && (out_phy_cmd == CMD_RD);
wire sva_cmd_act  = out_valid && (out_phy_cmd == CMD_ACT);
wire sva_cmd_ref  = out_valid && (out_phy_cmd == CMD_REF);
wire sva_cmd_pre  = out_valid && (out_phy_cmd == CMD_PRE);

// Banka príkazu ktorý sa práve vydáva
wire [1:0] sva_cmd_bank = (state == ST_RW_ISSUE || state == ST_ACT_WAIT_PIPE)
                           ? latched_cmd.addr.bank
                           : bank_sel;

// --------------------------------------------------------------------------
// SAFETY: S1 — CMD_WR/RD len keď banka je otvorená
// Porušenie = SDRAM timing violation (RD/WR bez ACT)
// --------------------------------------------------------------------------
property p_rw_requires_open_bank;
  @(posedge clk) disable iff (!rstn)
  (sva_cmd_wr || sva_cmd_rd) |-> bank_open[sva_cmd_bank];
endproperty
A_S1_rw_needs_open_bank:
  assert property (p_rw_requires_open_bank)
  else $error("[SCHED-S1] CMD_%s vydaný pre banku %0d ktorá nie je otvorená",
              sva_cmd_wr ? "WR" : "RD", sva_cmd_bank);

// --------------------------------------------------------------------------
// SAFETY: S2 — CMD_ACT len keď banka je zatvorená
// Porušenie = double-activate (JEDEC error)
// --------------------------------------------------------------------------
property p_act_requires_closed_bank;
  @(posedge clk) disable iff (!rstn)
  sva_cmd_act |-> !bank_open[sva_cmd_bank];
endproperty
A_S2_act_needs_closed_bank:
  assert property (p_act_requires_closed_bank)
  else $error("[SCHED-S2] CMD_ACT vydaný pre banku %0d ktorá je už otvorená",
              sva_cmd_bank);

// --------------------------------------------------------------------------
// SAFETY: S3 — CMD_REF len keď všetky banky sú zatvorené
// Porušenie = refresh s otvorenou bankou
// --------------------------------------------------------------------------
property p_ref_requires_all_closed;
  @(posedge clk) disable iff (!rstn)
  sva_cmd_ref |-> (bank_open == 4'b0000);
endproperty
A_S3_ref_needs_all_closed:
  assert property (p_ref_requires_all_closed)
  else $error("[SCHED-S3] CMD_REF vydaný keď bank_open=%04b (niektorá banka stále otvorená)",
              bank_open);

// --------------------------------------------------------------------------
// SAFETY: S4 — in_ready nesmie byť aktívne 2 po sebe idúce cykly
// in_ready je kombinačný FIFO consume signál — double-consume bug
// --------------------------------------------------------------------------
property p_in_ready_no_double;
  @(posedge clk) disable iff (!rstn)
  in_ready |=> !in_ready;
endproperty
A_S4_no_double_consume:
  assert property (p_in_ready_no_double)
  else $error("[SCHED-S4] in_ready aktívny 2 cykly po sebe — možné double-consume FIFO");

// --------------------------------------------------------------------------
// SAFETY: S5 — out_phy_cmd == CMD_NOP keď out_valid == 0
// --------------------------------------------------------------------------
property p_nop_when_invalid;
  @(posedge clk) disable iff (!rstn)
  !out_valid |-> (out_phy_cmd == CMD_NOP);
endproperty
A_S5_nop_when_invalid:
  assert property (p_nop_when_invalid)
  else $error("[SCHED-S5] out_phy_cmd=%04b ale out_valid=0 (má byť CMD_NOP)",
              out_phy_cmd);

// --------------------------------------------------------------------------
// SAFETY: S6 — read_issue len keď CMD_RD ide na zbernicu
// --------------------------------------------------------------------------
property p_read_issue_with_cmd_rd;
  @(posedge clk) disable iff (!rstn)
  read_issue |-> sva_cmd_rd;
endproperty
A_S6_read_issue_only_with_rd:
  assert property (p_read_issue_with_cmd_rd)
  else $error("[SCHED-S6] read_issue=1 ale out_phy_cmd=%04b (nie CMD_RD)",
              out_phy_cmd);

// --------------------------------------------------------------------------
// SAFETY: S7 — refresh_grant len keď CMD_REF ide na zbernicu
// --------------------------------------------------------------------------
property p_refresh_grant_with_ref;
  @(posedge clk) disable iff (!rstn)
  refresh_grant |-> sva_cmd_ref;
endproperty
A_S7_refresh_grant_only_with_ref:
  assert property (p_refresh_grant_with_ref)
  else $error("[SCHED-S7] refresh_grant=1 ale out_phy_cmd=%04b (nie CMD_REF)",
              out_phy_cmd);

// --------------------------------------------------------------------------
// LIVENESS: L1 — ST_ACT_WAIT musí eventually prejsť do ST_RW_ISSUE
// Timeout: T_RCD + 2 cykly (can_readwrite sa musí splniť)
// --------------------------------------------------------------------------
localparam int SVA_ACT_WAIT_MAX = T_RCD_CYCLES + 4;

property p_act_wait_terminates;
  @(posedge clk) disable iff (!rstn)
  (state == ST_ACT_WAIT) |-> ##[1:SVA_ACT_WAIT_MAX] (state == ST_RW_ISSUE);
endproperty
A_L1_act_wait_terminates:
  assert property (p_act_wait_terminates)
  else $error("[SCHED-L1] ST_ACT_WAIT neprešiel do ST_RW_ISSUE za %0d cyklov",
              SVA_ACT_WAIT_MAX);

// --------------------------------------------------------------------------
// LIVENESS: L2 — refresh_req musí byť eventually potvrdený
// Timeout: T_RFC + T_RP + T_RCD + marge (max čas na PRE ALL + REF)
// --------------------------------------------------------------------------
localparam int SVA_REFRESH_MAX = T_RFC_CYCLES + T_RP_CYCLES + 8;

property p_refresh_granted;
  @(posedge clk) disable iff (!rstn)
  $rose(refresh_pending) |-> ##[1:SVA_REFRESH_MAX] refresh_grant;
endproperty
A_L2_refresh_eventually_granted:
  assert property (p_refresh_granted)
  else $error("[SCHED-L2] refresh_pending nastavený ale refresh_grant neprišiel za %0d cyklov",
              SVA_REFRESH_MAX);

// --------------------------------------------------------------------------
// LIVENESS: L3 — in_valid musí byť eventually konzumovaný
// Timeout: zahŕňa najhorší prípad PRE+tRP+ACT+tRCD+RW
// --------------------------------------------------------------------------
localparam int SVA_CMD_MAX = T_RCD_CYCLES + T_RP_CYCLES + T_RAS_CYCLES + 16;

property p_cmd_eventually_consumed;
  @(posedge clk) disable iff (!rstn)
  (in_valid && !refresh_pending) |-> ##[1:SVA_CMD_MAX] in_ready;
endproperty
A_L3_cmd_eventually_consumed:
  assert property (p_cmd_eventually_consumed)
  else $error("[SCHED-L3] in_valid príkaz nebol konzumovaný za %0d cyklov (deadlock?)",
              SVA_CMD_MAX);

// --------------------------------------------------------------------------
// LIVENESS: L4 — ST_REF_WAIT musí eventually skončiť
// --------------------------------------------------------------------------
localparam int SVA_RFC_MAX = T_RFC_CYCLES + 4;

property p_ref_wait_terminates;
  @(posedge clk) disable iff (!rstn)
  (state == ST_REF_WAIT) |-> ##[1:SVA_RFC_MAX] (state == ST_IDLE);
endproperty
A_L4_ref_wait_terminates:
  assert property (p_ref_wait_terminates)
  else $error("[SCHED-L4] ST_REF_WAIT neprešiel do ST_IDLE za %0d cyklov",
              SVA_RFC_MAX);

// --------------------------------------------------------------------------
// COVER: dokumentácia dosiahnuľných stavov (pre FV / waveform review)
// --------------------------------------------------------------------------
C_row_hit:   cover property (@(posedge clk) disable iff (!rstn)
  sva_cmd_rd && bank_open[sva_cmd_bank] && bank_row_hit[sva_cmd_bank]);

C_row_miss:  cover property (@(posedge clk) disable iff (!rstn)
  sva_cmd_pre && !out_precharge_all);

C_pipeline:  cover property (@(posedge clk) disable iff (!rstn)
  state == ST_ACT_WAIT_PIPE);

C_ref_preempt: cover property (@(posedge clk) disable iff (!rstn)
  sva_cmd_ref && $past(in_valid));

`endif  // ENABLE_ASSERTIONS

endmodule
`endif // MEMORY_SCHEDULER_SV
