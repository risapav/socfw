/**
 * @file tb_scheduler_rw.sv
 * @brief Testbench — sdram_test_03_scheduler_rw milestone.
 *
 * @details
 * DUT: sdram_init + timing_manager + 4x bank_machine + memory_scheduler + sdram_phy.
 * No AXI, no write/read_engine, no FIFO, no refresh_manager.
 * Direct sdram_cmd_t driver -> scheduler -> PHY -> sdram_model_pro.
 *
 * Test sequence:
 *   WRITE bank=0, row=0x010, col=0x008, data=0xA5C3
 *   READ  bank=0, row=0x010, col=0x008  (row-hit, same bank stays open)
 *
 * Expected command trace on SDRAM bus:
 *   ACT B0 row0x010   (closed bank -> activate)
 *   WR  B0 col0x008   (after tRCD)
 *   RD  B0 col0x008   (row-hit after tWTR=1 cycle)
 *
 * Definition of done:
 *   cnt_act==1, cnt_wr==1, cnt_rd==1, cnt_pre==0
 *   rd_data == 0xA5C3
 *   sdram_model_pro: Errors=0, Warnings=0
 */

`timescale 1ns/1ps
`default_nettype none
import sdram_pkg::*;

module tb_scheduler_rw;

  // ============================================================
  // Test address + data
  // ============================================================
  localparam logic [ROW_ADDR_WIDTH-1:0]  TEST_ROW  = 13'h0010;
  localparam logic [COL_ADDR_WIDTH-1:0]  TEST_COL  = 9'h008;
  localparam logic [BANK_ADDR_WIDTH-1:0] TEST_BANK = 2'h0;
  localparam logic [DATA_WIDTH-1:0]      WDATA     = 16'hA5C3;

  // ============================================================
  // Clocks a reset
  // ============================================================
  logic clk, clk_sh, rstn;
  initial begin clk    = 1'b0; forever #5 clk    = ~clk;    end
  initial begin clk_sh = 1'b0; #2.5; forever #5 clk_sh = ~clk_sh; end
  initial begin rstn   = 1'b0; #100; rstn = 1'b1; end

  // ============================================================
  // TB command driver (FIFO-less: cur_cmd held until sched_ready)
  // ============================================================
  sdram_cmd_t tb_cmd;
  logic       tb_valid;
  logic       sched_ready;  // = in_ready from scheduler

  // ============================================================
  // Scheduler outputs (declared here — used in timing_manager and PHY below)
  // ============================================================
  phy_cmd_e sched_cmd_w;
  logic     sched_valid_w, sched_read_issue, sched_pre_all;

  // ============================================================
  // sdram_init
  // ============================================================
  phy_cmd_e                  init_phy_cmd;
  logic [ROW_ADDR_WIDTH-1:0] init_addr;
  logic                      init_done, init_busy;

  sdram_init #(
    .INIT_200US_CYCLES(20000),
    .NUM_REFRESH      (8),
    .T_MRD_CYCLES     (2)
  ) u_init (
    .clk(clk), .rstn(rstn),
    .init_cmd (init_phy_cmd), .init_addr(init_addr),
    .init_done(init_done),    .init_busy(init_busy)
  );

  // ============================================================
  // timing_manager
  // ============================================================
  logic        can_activate, can_readwrite, can_precharge;
  logic [3:0]  bank_can_rw;

  timing_manager u_timing (
    .clk(clk), .rstn(rstn),
    .bank            (tb_cmd.addr.bank),
    .issue_activate  (sched_valid_w && (sched_cmd_w == CMD_ACT)),
    .issue_precharge (sched_valid_w && (sched_cmd_w == CMD_PRE)),
    .issue_refresh   (sched_valid_w && (sched_cmd_w == CMD_REF)),
    .issue_write     (sched_valid_w && (sched_cmd_w == CMD_WR)),
    .issue_read      (sched_valid_w && (sched_cmd_w == CMD_RD)),
    .can_activate    (can_activate),
    .can_readwrite   (can_readwrite),
    .can_precharge   (can_precharge),
    .bank_can_rw     (bank_can_rw)
  );

  // ============================================================
  // bank_machines (4x)
  // ============================================================
  logic [3:0] bank_row_hit, bank_open;
  logic [3:0] bank_do_act, bank_do_pre;

  generate
    for (genvar i = 0; i < 4; i++) begin : g_bank
      bank_machine u_bank (
        .clk(clk), .rstn(rstn),
        .do_activate (bank_do_act[i]),
        .do_precharge(bank_do_pre[i]),
        .row_addr    (tb_cmd.addr.row),
        .query_row   (tb_cmd.addr.row),
        .row_open    (bank_open[i]),
        .row_hit     (bank_row_hit[i]),
        .curr_row    ()
      );
    end
  endgenerate

  // ============================================================
  // memory_scheduler
  // ============================================================
  memory_scheduler u_sched (
    .clk(clk), .rstn(rstn),
    .in_cmd      (tb_cmd),    .in_valid    (tb_valid),
    .in_ready    (sched_ready),
    .bank_row_hit(bank_row_hit), .bank_open  (bank_open),
    .bank_do_act (bank_do_act),  .bank_do_pre(bank_do_pre),
    .can_activate (init_done && can_activate),
    .can_readwrite(init_done && can_readwrite),
    .can_precharge(init_done && can_precharge),
    .bank_can_rw (bank_can_rw),
    .refresh_req  (1'b0),         .refresh_grant(),
    .out_phy_cmd  (sched_cmd_w),  .out_valid(sched_valid_w),
    .read_issue   (sched_read_issue),
    .out_precharge_all(sched_pre_all)
  );

  // ============================================================
  // PHY addr/cmd mux (identical wiring to sdram_system_top)
  // ============================================================
  phy_cmd_e                   phy_cmd_mux;
  logic [ROW_ADDR_WIDTH-1:0]  phy_addr_mux;
  logic [BANK_ADDR_WIDTH-1:0] phy_ba_mux;

  always_comb begin
    if (init_busy) begin
      phy_cmd_mux  = init_phy_cmd;
      phy_addr_mux = init_addr;
      phy_ba_mux   = '0;
    end else if (sched_valid_w) begin
      phy_cmd_mux = sched_cmd_w;
      phy_ba_mux  = tb_cmd.addr.bank;
      unique case (sched_cmd_w)
        CMD_ACT:        phy_addr_mux = tb_cmd.addr.row;
        CMD_RD, CMD_WR: phy_addr_mux = ROW_ADDR_WIDTH'(tb_cmd.addr.col);
        CMD_PRE:        phy_addr_mux = sched_pre_all ? 13'h0400 : 13'h0000;
        default:        phy_addr_mux = '0;
      endcase
    end else begin
      phy_cmd_mux  = CMD_NOP;
      phy_addr_mux = '0;
      phy_ba_mux   = '0;
    end
  end

  // ============================================================
  // DQ OE: 1-cycle hold register so model captures WDATA at clk_sh
  // (clk_sh leads clk by 2.5 ns; model samples DQ at clk_sh_{T_wr+7.5ns}
  //  but sched_valid_w falls at T_wr+delta — hold keeps dq_oe=1 until T_wr+10ns)
  // ============================================================
  wire  dq_oe_comb = sched_valid_w && (sched_cmd_w == CMD_WR);
  logic dq_oe_hold;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) dq_oe_hold <= 1'b0;
    else       dq_oe_hold <= dq_oe_comb;
  end
  wire dq_oe = dq_oe_comb | dq_oe_hold;

  // ============================================================
  // sdram_phy
  // ============================================================
  logic [ROW_ADDR_WIDTH-1:0]  sdram_addr;
  logic [BANK_ADDR_WIDTH-1:0] sdram_ba;
  logic                       sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cs_n;
  wire                        sdram_clk;
  logic                       sdram_cke;
  wire  [DATA_WIDTH-1:0]      sdram_dq;
  logic [DATA_WIDTH-1:0]      dq_i;
  logic                       dq_i_valid;

  sdram_phy #(
    .DATA_WIDTH     (DATA_WIDTH),
    .ROW_ADDR_WIDTH (ROW_ADDR_WIDTH),
    .BANK_ADDR_WIDTH(BANK_ADDR_WIDTH),
    .CAS_LATENCY    (CAS_LATENCY),
    .USE_ALTIOBUF   (0)
  ) u_phy (
    .clk(clk), .clk_sh(clk_sh), .rstn(rstn),
    .phy_cmd   (phy_cmd_mux), .addr_in(phy_addr_mux), .ba_in(phy_ba_mux),
    .read_en_in(sched_valid_w && (sched_cmd_w == CMD_RD)),
    .dq_o      (DATA_WIDTH'(WDATA)), .dq_oe(dq_oe),
    .dq_i      (dq_i), .dq_i_valid(dq_i_valid), .phy_wready(),
    .sdram_addr (sdram_addr),   .sdram_ba  (sdram_ba),
    .sdram_ras_n(sdram_ras_n),  .sdram_cas_n(sdram_cas_n),
    .sdram_we_n (sdram_we_n),   .sdram_cs_n (sdram_cs_n),
    .sdram_dq   (sdram_dq),     .sdram_clk  (sdram_clk),
    .sdram_cke  (sdram_cke)
  );

  // ============================================================
  // SDRAM model + trace
  // ============================================================
  sdram_model_pro #(
    .DATA_WIDTH(DATA_WIDTH),  .ROW_WIDTH(ROW_ADDR_WIDTH), .COL_WIDTH(COL_ADDR_WIDTH),
    .BANKS(4),
    .tRCD(T_RCD_CYCLES), .tRP(T_RP_CYCLES),  .tRAS(T_RAS_CYCLES),
    .tWR (T_WR_CYCLES),  .tRFC(T_RFC_CYCLES), .CL(CAS_LATENCY)
  ) u_model (
    .clk(sdram_clk), .rst(!rstn),
    .addr(sdram_addr), .ba(sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),  .cs_n (sdram_cs_n),
    .dq   (sdram_dq)
  );

  sdram_cmd_trace #(
    .ROW_WIDTH(ROW_ADDR_WIDTH), .COL_WIDTH(COL_ADDR_WIDTH), .BANKS(4)
  ) u_trace (
    .clk(sdram_clk), .rstn(rstn),
    .addr(sdram_addr), .ba(sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),  .cs_n (sdram_cs_n)
  );

  // ============================================================
  // Command counters (on sdram_clk)
  // ============================================================
  int cnt_act = 0, cnt_wr = 0, cnt_rd = 0, cnt_pre = 0;
  int errors  = 0;

  always @(posedge sdram_clk) begin
    if (!sdram_cs_n) begin
      case ({sdram_ras_n, sdram_cas_n, sdram_we_n})
        3'b011: cnt_act++;
        3'b100: cnt_wr++;
        3'b101: cnt_rd++;
        3'b010: if (!sdram_addr[10]) cnt_pre++;  // single-bank PRE only
        default:;
      endcase
    end
  end

  // Read data capture (dq_i_valid is a 1-cycle pulse)
  logic               rd_valid_seen = 1'b0;
  logic [DATA_WIDTH-1:0] rd_data    = '0;

  always @(posedge clk) begin
    if (dq_i_valid && !rd_valid_seen) begin
      rd_valid_seen = 1'b1;
      rd_data       = dq_i;
    end
  end

  // ============================================================
  // Main test
  // ============================================================
  initial begin
    tb_cmd   = '0;
    tb_valid = 1'b0;

    @(posedge rstn);
    @(posedge init_done);
    repeat(4) @(posedge clk);

    // ----------------------------------------------------------
    // WRITE: bank=0, row=0x010, col=0x008, data=0xA5C3
    //
    // Scheduler trace (SDRAM cycles):
    //   ST_IDLE (closed bank) -> CMD_ACT -> ST_ACT_WAIT (tRCD=2)
    //   -> ST_RW_ISSUE -> CMD_WR -> ST_IDLE
    // ----------------------------------------------------------
    $display("[TB] WRITE: bank=%0h row=0x%04h col=0x%03h data=0x%04h",
             TEST_BANK, TEST_ROW, TEST_COL, WDATA);

    @(posedge clk); #1;
    tb_cmd.addr.row  = TEST_ROW;
    tb_cmd.addr.bank = TEST_BANK;
    tb_cmd.addr.col  = TEST_COL;
    tb_cmd.write_en  = 1'b1;
    tb_cmd.burst_len = '0;
    tb_cmd.id        = '0;
    tb_cmd.last      = 1'b1;
    tb_valid = 1'b1;

    // Wait until scheduler consumes WRITE (in_ready at posedge)
    while (!sched_ready) @(posedge clk);
    #1;

    // ----------------------------------------------------------
    // READ: same address — row-hit (bank stays open after WRITE)
    //
    // Scheduler trace:
    //   ST_IDLE (row-hit) -> CMD_RD after tWTR=1 cycle
    //
    // Timing note (clk_sh leads clk by 2.5 ns):
    //   At T_wr-2.5 ns (clk_sh before T_wr posedge):
    //     twtr_timer just became 0 via NBA from T_wr-10ns posedge.
    //     Scheduler combinational fires: sched_valid=1, CMD_RD.
    //     read_en_sh captured at this clk_sh (= N_p).
    //   At T_wr (clk posedge): PHY registers CMD_RD.
    //   Model sees CMD_RD at T_wr+7.5 ns (= N_m = N_p+1). -> matching M2 timing.
    // ----------------------------------------------------------
    $display("[TB] READ:  bank=%0h row=0x%04h col=0x%03h",
             TEST_BANK, TEST_ROW, TEST_COL);

    tb_cmd.write_en = 1'b0;
    // tb_valid stays 1

    // Wait until scheduler consumes READ
    while (!sched_ready) @(posedge clk);
    #1;
    tb_valid = 1'b0;

    // Wait for CAS pipeline to deliver dq_i_valid (CAS_LATENCY+5 + margin)
    repeat(CAS_LATENCY + 10) @(posedge clk);

    // ----------------------------------------------------------
    // Verification
    // ----------------------------------------------------------
    if (cnt_act != 1) begin
      $error("[FAIL] ACT: expected 1, got %0d", cnt_act);
      errors++;
    end
    if (cnt_wr != 1) begin
      $error("[FAIL] WR: expected 1, got %0d", cnt_wr);
      errors++;
    end
    if (cnt_rd != 1) begin
      $error("[FAIL] RD: expected 1, got %0d", cnt_rd);
      errors++;
    end
    if (cnt_pre != 0) begin
      $error("[FAIL] PRE: expected 0, got %0d", cnt_pre);
      errors++;
    end
    if (!rd_valid_seen) begin
      $error("[FAIL] dq_i_valid nikdy neassertol");
      errors++;
    end
    if (rd_valid_seen && rd_data !== WDATA) begin
      $error("[FAIL] Data mismatch: write=0x%04h read=0x%04h", WDATA, rd_data);
      errors++;
    end

    $display("");
    $display("=============================================================");
    $display("  ACT=%0d WR=%0d RD=%0d PRE=%0d", cnt_act, cnt_wr, cnt_rd, cnt_pre);
    $display("  Write=0x%04h  Read=0x%04h  valid=%0b",
             WDATA, rd_valid_seen ? rd_data : '0, rd_valid_seen);
    if (errors == 0)
      $display("  *** PASS ***");
    else
      $display("  *** FAIL *** (errors=%0d)", errors);
    $display("=============================================================");
    $finish;
  end

  // Watchdog
  initial begin
    #25_000_000;
    $fatal(1, "[WATCHDOG] Timeout! init_done=%0b rd_valid_seen=%0b",
           init_done, rd_valid_seen);
  end

endmodule
