/**
 * @file tb_init_refresh.sv
 * @brief Testbench — sdram_test_01_init_refresh milestone.
 *
 * @details
 * Overuje iba init sekvenciu a periodicky refresh bez AXI/read/write:
 *   200us wait -> PRE_ALL -> 8x AUTO_REF -> MRS -> init_done -> periodic REF
 *
 * DUT: sdram_init + refresh_manager + sdram_phy (command output)
 * Model: sdram_model_pro (JEDEC timing checker)
 * Trace: sdram_cmd_trace (formátovany log)
 *
 * Checks:
 *   cnt_pre_all == 1
 *   cnt_ref >= 11  (8 init + min 3 periodic)
 *   cnt_mrs == 1, MRS addr == 13'h0030
 *   cnt_act == 0, cnt_rd == 0, cnt_wr == 0
 *   sekvencia: PRE_ALL -> REF -> MRS -> init_done
 *   ziadne $error z sdram_model_pro
 */

`timescale 1ns/1ps
`default_nettype none
import sdram_pkg::*;

module tb_init_refresh;

  // ============================================================
  // Clocks a reset
  // ============================================================
  logic clk, clk_sh, rstn;

  initial begin clk    = 1'b0; forever #5 clk    = ~clk;    end
  initial begin clk_sh = 1'b0; #2.5; forever #5 clk_sh = ~clk_sh; end
  initial begin rstn   = 1'b0; #100; rstn = 1'b1; end

  // ============================================================
  // sdram_init vystupy
  // ============================================================
  phy_cmd_e                  init_cmd;
  logic [ROW_ADDR_WIDTH-1:0] init_addr;
  logic                      init_done;
  logic                      init_busy;

  // ============================================================
  // refresh_manager
  // ============================================================
  logic refresh_req;
  logic refresh_grant;
  logic refresh_busy;
  logic [3:0] refresh_timer;

  // ============================================================
  // Command mux -> PHY
  // ============================================================
  phy_cmd_e                  mux_cmd;
  logic [ROW_ADDR_WIDTH-1:0] mux_addr;

  // ============================================================
  // SDRAM bus
  // ============================================================
  logic [ROW_ADDR_WIDTH-1:0]  sdram_addr;
  logic [BANK_ADDR_WIDTH-1:0] sdram_ba;
  logic                       sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cs_n;
  wire                        sdram_clk;
  logic                       sdram_cke;
  wire  [15:0]                sdram_dq;

  // ============================================================
  // DUT: sdram_init
  // ============================================================
  sdram_init #(
    .INIT_200US_CYCLES (20000),
    .NUM_REFRESH       (8),
    .T_MRD_CYCLES      (2)
  ) u_init (
    .clk       (clk),
    .rstn      (rstn),
    .init_cmd  (init_cmd),
    .init_addr (init_addr),
    .init_done (init_done),
    .init_busy (init_busy)
  );

  // ============================================================
  // DUT: refresh_manager
  // ============================================================
  refresh_manager #(
    .REFRESH_INTERVAL   (T_REFI_CYCLES),
    .MAX_REFRESH_CREDITS(8)
  ) u_refresh (
    .clk          (clk),
    .rstn         (rstn),
    .refresh_req  (refresh_req),
    .refresh_grant(refresh_grant)
  );

  // ============================================================
  // Post-init refresh FSM — caka T_RFC cyklov medzi REF prikazmi
  // ============================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      refresh_busy  <= 1'b0;
      refresh_timer <= 4'h0;
    end else if (!init_busy) begin
      if (refresh_grant) begin
        refresh_busy  <= 1'b1;
        refresh_timer <= 4'(T_RFC_CYCLES - 1);
      end else if (refresh_busy) begin
        if (refresh_timer == 4'h0)
          refresh_busy <= 1'b0;
        else
          refresh_timer <= refresh_timer - 4'h1;
      end
    end
  end

  assign refresh_grant = !init_busy && refresh_req && !refresh_busy;

  // ============================================================
  // Command MUX: init ma prioritu pred refresh
  // ============================================================
  always_comb begin
    if (init_busy) begin
      mux_cmd  = init_cmd;
      mux_addr = init_addr;
    end else if (refresh_grant) begin
      mux_cmd  = CMD_REF;
      mux_addr = '0;
    end else begin
      mux_cmd  = CMD_NOP;
      mux_addr = '0;
    end
  end

  // ============================================================
  // DUT: sdram_phy (command register + clock forwarding)
  // ============================================================
  sdram_phy #(
    .DATA_WIDTH     (16),
    .ROW_ADDR_WIDTH (ROW_ADDR_WIDTH),
    .BANK_ADDR_WIDTH(BANK_ADDR_WIDTH),
    .CAS_LATENCY    (CAS_LATENCY),
    .USE_ALTIOBUF   (0)
  ) u_phy (
    .clk        (clk),
    .clk_sh     (clk_sh),
    .rstn       (rstn),
    .phy_cmd    (mux_cmd),
    .addr_in    (mux_addr),
    .ba_in      ('0),
    .read_en_in (1'b0),
    .dq_o       ('0),
    .dq_oe      (1'b0),
    .dq_i       (),
    .dq_i_valid (),
    .phy_wready (),
    .sdram_addr (sdram_addr),
    .sdram_ba   (sdram_ba),
    .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n),
    .sdram_we_n (sdram_we_n),
    .sdram_cs_n (sdram_cs_n),
    .sdram_dq   (sdram_dq),
    .sdram_clk  (sdram_clk),
    .sdram_cke  (sdram_cke)
  );

  // ============================================================
  // SDRAM behavioral model (JEDEC timing checker)
  // ============================================================
  sdram_model_pro #(
    .DATA_WIDTH(16),
    .ROW_WIDTH (13),
    .COL_WIDTH (9),
    .BANKS     (4),
    .tRCD      (T_RCD_CYCLES),
    .tRP       (T_RP_CYCLES),
    .tRAS      (T_RAS_CYCLES),
    .tWR       (T_WR_CYCLES),
    .tRFC      (T_RFC_CYCLES),
    .CL        (CAS_LATENCY)
  ) u_model (
    .clk  (sdram_clk),
    .rst  (!rstn),
    .addr (sdram_addr),
    .ba   (sdram_ba),
    .ras_n(sdram_ras_n),
    .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),
    .cs_n (sdram_cs_n),
    .dq   (sdram_dq)
  );

  // ============================================================
  // Command trace (farebny log na terminal)
  // ============================================================
  sdram_cmd_trace #(
    .ROW_WIDTH(13),
    .COL_WIDTH(9),
    .BANKS    (4)
  ) u_trace (
    .clk  (sdram_clk),
    .rstn (rstn),
    .addr (sdram_addr),
    .ba   (sdram_ba),
    .ras_n(sdram_ras_n),
    .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),
    .cs_n (sdram_cs_n)
  );

  // ============================================================
  // Checkers — vzorkovanie na sdram_clk (rovnaky pohlad ako model)
  // ============================================================
  int  cnt_pre_all = 0;
  int  cnt_ref     = 0;
  int  cnt_mrs     = 0;
  int  cnt_act     = 0;
  int  cnt_rd      = 0;
  int  cnt_wr      = 0;
  int  errors      = 0;

  time t_pre_all   = 0;
  time t_first_ref = 0;
  time t_mrs       = 0;
  time t_init_done = 0;

  always @(posedge sdram_clk) begin
    if (!sdram_cs_n) begin
      case ({sdram_ras_n, sdram_cas_n, sdram_we_n})
        3'b010: begin  // PRE / PRE_ALL
          if (sdram_addr[10]) begin
            cnt_pre_all++;
            if (t_pre_all == 0) t_pre_all = $time;
          end
        end
        3'b001: begin  // AUTO REFRESH
          cnt_ref++;
          if (t_first_ref == 0) t_first_ref = $time;
        end
        3'b000: begin  // MRS
          cnt_mrs++;
          if (t_mrs == 0) t_mrs = $time;
          if (sdram_addr !== 13'h0030)
            $error("[FAIL] MRS addr=0x%04h, expected 0x0030 (BL=1 CAS=3)", sdram_addr);
        end
        3'b011: cnt_act++;  // ACT
        3'b100: cnt_wr++;   // WR
        3'b101: cnt_rd++;   // RD
        default:;
      endcase
    end
  end

  always @(posedge clk) begin
    if (init_done && t_init_done == 0)
      t_init_done = $time;
  end

  // ============================================================
  // Main test body
  // ============================================================
  initial begin
    @(posedge rstn);
    @(posedge init_done);
    #100;

    // Drain accumulated refresh credits (max 8 kredity x (T_RFC + overhead))
    repeat (8 * (T_RFC_CYCLES + 6)) @(posedge clk);

    // Pocka na min 3 periodicke refreshy
    repeat (3 * (T_REFI_CYCLES + T_RFC_CYCLES + 6)) @(posedge clk);
    #50;

    // ------------------------------------------------------------------
    // Overenie sekvencie
    // ------------------------------------------------------------------
    if (t_pre_all == 0) begin
      $error("[FAIL] PRE_ALL nebolo nikdy vydane");
      errors++;
    end
    if (t_first_ref == 0) begin
      $error("[FAIL] REF nebolo nikdy vydane");
      errors++;
    end else if (t_pre_all > 0 && t_first_ref < t_pre_all) begin
      $error("[FAIL] REF pred PRE_ALL: ref=%0t pre=%0t", t_first_ref, t_pre_all);
      errors++;
    end
    if (t_mrs == 0) begin
      $error("[FAIL] MRS nebolo nikdy vydane");
      errors++;
    end else if (t_first_ref > 0 && t_mrs < t_first_ref) begin
      $error("[FAIL] MRS pred prvym REF: mrs=%0t ref=%0t", t_mrs, t_first_ref);
      errors++;
    end
    if (t_init_done == 0) begin
      $error("[FAIL] init_done sa nikdy neassertol");
      errors++;
    end else if (t_mrs > 0 && t_init_done < t_mrs) begin
      $error("[FAIL] init_done pred MRS: done=%0t mrs=%0t", t_init_done, t_mrs);
      errors++;
    end

    // ------------------------------------------------------------------
    // Overenie poctu prikazov
    // ------------------------------------------------------------------
    if (cnt_pre_all != 1) begin
      $error("[FAIL] Ocakavan 1 PRE_ALL, dostal %0d", cnt_pre_all);
      errors++;
    end
    if (cnt_ref < 11) begin
      $error("[FAIL] Ocakavanych >=11 REF (8 init + 3 periodic), dostal %0d", cnt_ref);
      errors++;
    end
    if (cnt_mrs != 1) begin
      $error("[FAIL] Ocakavane 1 MRS, dostal %0d", cnt_mrs);
      errors++;
    end
    if (cnt_act != 0) begin
      $error("[FAIL] Neocakavane ACT=%0d (init/refresh nesmie mat ACT)", cnt_act);
      errors++;
    end
    if (cnt_rd != 0) begin
      $error("[FAIL] Neocakavane RD=%0d", cnt_rd);
      errors++;
    end
    if (cnt_wr != 0) begin
      $error("[FAIL] Neocakavane WR=%0d", cnt_wr);
      errors++;
    end

    $display("");
    $display("==============================================================");
    $display("  PRE_ALL=%0d  REF=%0d  MRS=%0d  ACT=%0d  RD=%0d  WR=%0d",
             cnt_pre_all, cnt_ref, cnt_mrs, cnt_act, cnt_rd, cnt_wr);
    $display("  Seq: PRE_ALL@%0t  REF@%0t  MRS@%0t  init_done@%0t",
             t_pre_all, t_first_ref, t_mrs, t_init_done);
    if (errors == 0)
      $display("  *** PASS ***");
    else
      $display("  *** FAIL *** (errors=%0d)", errors);
    $display("==============================================================");
    $finish;
  end

  // Watchdog: 25ms pokryva 200us init + drain 8 kreditov + 3 periodicke REF
  initial begin
    #25_000_000;
    $fatal(1, "[WATCHDOG] Timeout! init_done=%0b cnt_ref=%0d", init_done, cnt_ref);
  end

endmodule
