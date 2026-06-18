/**
 * @file tb_coverage.sv
 * @brief Functional Coverage pre SDRAM Controller.
 *
 * Použitie — vložiť do tb_sdram_top pred endmodule:
 *
 *   `include "tb_coverage.sv"
 *
 * alebo pridať do filelist.f a inštanciovať v TB:
 *
 *   sdram_coverage u_cov (
 *     .clk       (clk),
 *     .rstn      (rstn),
 *     .sched_state (dut.i_scheduler.state),
 *     .bank_open   (dut.bank_open),
 *     .bank_row_hit(dut.bank_row_hit),
 *     ...
 *   );
 *
 * Questa: coverage report -detail -cvg po simulácii
 */

`ifndef TB_COVERAGE_SV
`define TB_COVERAGE_SV

import sdram_pkg::*;

module sdram_coverage #(
  parameter int ID_WIDTH = AXI_ID_WIDTH
)(
  input wire clk,
  input wire rstn,

  // Scheduler interné signály (hierarchická referencia z TB)
  input wire [3:0]  sched_state,      // dut.i_scheduler.state
  input wire        refresh_pending,  // dut.i_scheduler.refresh_pending
  input wire        pipe_valid,       // dut.i_scheduler.pipe_valid

  // Bank status
  input wire [3:0]  bank_open,
  input wire [3:0]  bank_row_hit,
  input wire [3:0]  bank_do_act,
  input wire [3:0]  bank_do_pre,

  // Scheduler výstup
  input wire        sched_valid,
  input wire [3:0]  sched_cmd,        // phy_cmd_e
  input wire [1:0]  fifo_bank,        // fifo_cmd.addr.bank

  // AXI Write
  input wire        s_axi_awvalid,
  input wire        s_axi_awready,
  input wire [7:0]  s_axi_awlen,
  input wire        s_axi_wvalid,
  input wire        s_axi_wready,
  input wire        s_axi_wlast,
  input wire        s_axi_bvalid,
  input wire        s_axi_bready,

  // AXI Read
  input wire        s_axi_arvalid,
  input wire        s_axi_arready,
  input wire [7:0]  s_axi_arlen,
  input wire        s_axi_rvalid,
  input wire        s_axi_rready,
  input wire        s_axi_rlast
);

  // ==========================================================================
  // COVERGROUP 1: Scheduler FSM stav pokrytie
  // Cieľ: každý stav navštívený aspoň raz
  // ==========================================================================
  covergroup cg_scheduler_fsm @(posedge clk iff rstn);
    cp_state: coverpoint sched_state {
      bins idle         = {4'd0};  // ST_IDLE
      bins act_wait     = {4'd1};  // ST_ACT_WAIT
      bins rw_issue     = {4'd2};  // ST_RW_ISSUE
      bins pre_miss     = {4'd3};  // ST_PRE_WAIT_MISS
      bins pre_act_miss = {4'd4};  // ST_PRE_ACT_MISS
      bins ref_pre_wait = {4'd5};  // ST_REF_PRE_WAIT
      bins ref_wait     = {4'd6};  // ST_REF_WAIT
      bins act_wait_pipe= {4'd7};  // ST_ACT_WAIT_PIPE (bank pipeline)
    }

    // Prechody — kľúčové sekvencie
    cp_transitions: coverpoint sched_state {
      bins idle_to_act_wait  = (4'd0 => 4'd1);  // IDLE → ACT_WAIT (new activate)
      bins idle_to_pre_miss  = (4'd0 => 4'd3);  // IDLE → PRE_WAIT_MISS (row miss)
      bins idle_to_ref_pre   = (4'd0 => 4'd5);  // IDLE → REF_PRE_WAIT (refresh)
      bins act_wait_to_pipe  = (4'd1 => 4'd7);  // ACT_WAIT → PIPE (pipeline ACT)
      bins rw_to_idle        = (4'd2 => 4'd0);  // RW_ISSUE → IDLE (completed)
      bins ref_wait_to_idle  = (4'd6 => 4'd0);  // REF_WAIT → IDLE (refresh done)
    }

    // Refresh pending počas RW operácie
    cp_refresh_during_rw: coverpoint sched_state {
      bins rw_with_refresh = {4'd2};
    }
    cp_refresh_flag: coverpoint refresh_pending;
    cx_rw_with_pending_refresh: cross cp_refresh_during_rw, cp_refresh_flag {
      bins rw_and_refresh_pending = binsof(cp_refresh_during_rw.rw_with_refresh)
                                  && binsof(cp_refresh_flag) intersect {1'b1};
    }
  endgroup

  // ==========================================================================
  // COVERGROUP 2: Bank scenáre
  // Cieľ: každá banka aktivovaná, row-hit aj row-miss pre každú
  // ==========================================================================
  covergroup cg_bank_scenarios @(posedge clk iff rstn);

    // Každá banka musí byť aktivovaná
    cp_bank_activated: coverpoint fifo_bank iff (sched_valid && sched_cmd == 4'b0011) {
      bins bank0 = {2'd0};
      bins bank1 = {2'd1};
      bins bank2 = {2'd2};
      bins bank3 = {2'd3};
    }

    // Row hit pre každú banku
    cp_row_hit_bank: coverpoint fifo_bank
      iff (sched_valid && (sched_cmd == 4'b0100 || sched_cmd == 4'b0101)
           && bank_row_hit[fifo_bank]) {
      bins bank0_hit = {2'd0};
      bins bank1_hit = {2'd1};
      bins bank2_hit = {2'd2};
      bins bank3_hit = {2'd3};
    }

    // Row miss pre každú banku (PRE vydaný)
    cp_row_miss_bank: coverpoint fifo_bank
      iff (sched_valid && sched_cmd == 4'b0010 && !(&bank_open)) {
      bins bank0_miss = {2'd0};
      bins bank1_miss = {2'd1};
      bins bank2_miss = {2'd2};
      bins bank3_miss = {2'd3};
    }

    // Počet súčasne otvorených bánk
    cp_open_bank_count: coverpoint $countones(bank_open) {
      bins none  = {0};
      bins one   = {1};
      bins two   = {2};
      bins three = {3};
      bins all4  = {4};
    }

    // Bank pipeline: pipe_valid aktívny
    cp_pipeline_active: coverpoint pipe_valid {
      bins pipeline_used = {1'b1};
    }
  endgroup

  // ==========================================================================
  // COVERGROUP 3: Refresh scenáre
  // ==========================================================================
  covergroup cg_refresh @(posedge clk iff rstn);

    // Refresh s rôznymi stavmi bánk
    cp_ref_bank_state: coverpoint $countones(bank_open)
      iff (sched_valid && sched_cmd == 4'b0001) {
      bins ref_no_open   = {0};    // REF pri žiadnej otvorenej banke
      bins ref_with_open = {[1:4]}; // REF musela PRE ALL
    }

    // Refresh pending pri plnom FIFO vs prázdnom
    // (nepriama detekcia cez sched_state)
    cp_ref_interrupts_rw: coverpoint sched_state
      iff (refresh_pending) {
      bins ref_during_act_wait = {4'd1};  // refresh čaká kým ACT_WAIT
      bins ref_during_rw       = {4'd2};  // refresh čaká kým RW_ISSUE
    }
  endgroup

  // ==========================================================================
  // COVERGROUP 4: AXI burst typy
  // ==========================================================================
  covergroup cg_axi_burst @(posedge clk iff rstn);

    // Write burst dĺžky
    cp_write_len: coverpoint s_axi_awlen
      iff (s_axi_awvalid && s_axi_awready) {
      bins single   = {8'd0};         // len=0 → 1 beat
      bins burst2   = {8'd1};         // len=1 → 2 beaty
      bins burst4   = {8'd3};         // len=3 → 4 beaty
      bins burst8   = {8'd7};         // len=7 → 8 beatov
      bins other    = {[8'd2:8'd255]} with (item != 8'd3 && item != 8'd7);
    }

    // Read burst dĺžky
    cp_read_len: coverpoint s_axi_arlen
      iff (s_axi_arvalid && s_axi_arready) {
      bins single = {8'd0};
      bins burst2 = {8'd1};
      bins burst4 = {8'd3};
      bins burst8 = {8'd7};
      bins other  = {[8'd2:8'd255]} with (item != 8'd3 && item != 8'd7);
    }

    // B channel response timing
    cp_b_resp_timing: coverpoint s_axi_bvalid {
      bins b_valid_seen = {1'b1};
    }

    // R channel last beat
    cp_r_last: coverpoint s_axi_rlast
      iff (s_axi_rvalid && s_axi_rready) {
      bins last_seen = {1'b1};
    }
  endgroup

  // ==========================================================================
  // COVERGROUP 5: SDRAM príkazy na zbernicu
  // ==========================================================================
  covergroup cg_sdram_cmds @(posedge clk iff rstn);
    cp_cmd: coverpoint sched_cmd iff (sched_valid) {
      bins act_cmd = {4'b0011};  // CMD_ACT
      bins wr_cmd  = {4'b0100};  // CMD_WR
      bins rd_cmd  = {4'b0101};  // CMD_RD
      bins pre_cmd = {4'b0010};  // CMD_PRE
      bins ref_cmd = {4'b0001};  // CMD_REF
    }

    // Write immediately followed by read (same bank)
    cp_wr_then_rd: coverpoint sched_cmd iff (sched_valid) {
      bins wr_to_rd = (4'b0100 => 4'b0101);
      bins rd_to_wr = (4'b0101 => 4'b0100);
    }
  endgroup

  // ==========================================================================
  // Inštancie covergroups
  // ==========================================================================
  cg_scheduler_fsm cov_fsm    = new();
  cg_bank_scenarios cov_banks = new();
  cg_refresh        cov_ref   = new();
  cg_axi_burst      cov_burst = new();
  cg_sdram_cmds     cov_cmds  = new();

  // ==========================================================================
  // Coverage report na konci simulácie
  // ==========================================================================
  final begin
    automatic real fsm_cov    = cov_fsm.get_coverage();
    automatic real banks_cov  = cov_banks.get_coverage();
    automatic real ref_cov    = cov_ref.get_coverage();
    automatic real burst_cov  = cov_burst.get_coverage();
    automatic real cmds_cov   = cov_cmds.get_coverage();
    automatic real total_cov  = (fsm_cov + banks_cov + ref_cov +
                                  burst_cov + cmds_cov) / 5.0;

    $display("\n============================================================");
    $display(" FUNCTIONAL COVERAGE REPORT");
    $display("============================================================");
    $display(" Scheduler FSM:   %0.1f%%", fsm_cov);
    $display(" Bank scenáre:    %0.1f%%", banks_cov);
    $display(" Refresh:         %0.1f%%", ref_cov);
    $display(" AXI burst:       %0.1f%%", burst_cov);
    $display(" SDRAM commands:  %0.1f%%", cmds_cov);
    $display("------------------------------------------------------------");
    $display(" Celkové pokrytie: %0.1f%%", total_cov);
    $display("============================================================\n");

    if (total_cov < 80.0)
      $warning("[COV] Pokrytie pod 80%% — pridaj testovacie scenáre!");
  end

endmodule
`endif
