/**
 * @file tb_phy_single_rw.sv
 * @brief Testbench — sdram_test_02_single_rw milestone.
 *
 * @details
 * TB riadi sdram_phy priamo (bez schedulera, timing_manager, AXI).
 * Po init_done vykoná manuálnu sekvenciu:
 *
 *   WRITE: ACT -> (tRCD) -> WR + DQ -> (margin) -> PRE -> (tRP)
 *   READ:  ACT -> (tRCD) -> RD + read_en_in -> (CAS pipeline) -> capture dq_i
 *
 * Overuje:
 *   cmd counts: ACT=2, WR=1, RD=1, PRE=2
 *   data: dq_i_valid assert, dq_i == WDATA
 *   model: žiadne $error z sdram_model_pro (tRCD, tRP, rfc violations)
 */

`timescale 1ns/1ps
`default_nettype none
import sdram_pkg::*;

module tb_phy_single_rw;

  // ============================================================
  // Test address + data
  // ============================================================
  localparam logic [ROW_ADDR_WIDTH-1:0]  TEST_ROW  = 13'h0010;  // row 16
  localparam logic [COL_ADDR_WIDTH-1:0]  TEST_COL  = 9'h008;    // col 8
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
  // sdram_init
  // ============================================================
  phy_cmd_e                  init_cmd;
  logic [ROW_ADDR_WIDTH-1:0] init_addr;
  logic                      init_done, init_busy;

  sdram_init #(
    .INIT_200US_CYCLES(20000),
    .NUM_REFRESH      (8),
    .T_MRD_CYCLES     (2)
  ) u_init (
    .clk      (clk),      .rstn     (rstn),
    .init_cmd (init_cmd), .init_addr(init_addr),
    .init_done(init_done), .init_busy(init_busy)
  );

  // ============================================================
  // TB-driven PHY control (post-init)
  // ============================================================
  phy_cmd_e                   tb_cmd   = CMD_NOP;
  logic [ROW_ADDR_WIDTH-1:0]  tb_addr  = '0;
  logic [BANK_ADDR_WIDTH-1:0] tb_ba    = '0;
  logic [DATA_WIDTH-1:0]      tb_dq_o  = '0;
  logic                       tb_dq_oe = 1'b0;
  logic                       tb_rden  = 1'b0;

  // Mux: init priority over TB
  phy_cmd_e                   mux_cmd;
  logic [ROW_ADDR_WIDTH-1:0]  mux_addr;
  logic [BANK_ADDR_WIDTH-1:0] mux_ba;
  logic [DATA_WIDTH-1:0]      mux_dq_o;
  logic                       mux_dq_oe;
  logic                       mux_rden;

  always_comb begin
    if (init_busy) begin
      mux_cmd   = init_cmd;  mux_addr  = init_addr;
      mux_ba    = '0;        mux_dq_o  = '0;
      mux_dq_oe = 1'b0;      mux_rden  = 1'b0;
    end else begin
      mux_cmd   = tb_cmd;   mux_addr  = tb_addr;
      mux_ba    = tb_ba;    mux_dq_o  = tb_dq_o;
      mux_dq_oe = tb_dq_oe; mux_rden  = tb_rden;
    end
  end

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
    .clk        (clk),     .clk_sh    (clk_sh),     .rstn      (rstn),
    .phy_cmd    (mux_cmd), .addr_in   (mux_addr),   .ba_in     (mux_ba),
    .read_en_in (mux_rden),.dq_o      (mux_dq_o),   .dq_oe     (mux_dq_oe),
    .dq_i       (dq_i),    .dq_i_valid(dq_i_valid),  .phy_wready(),
    .sdram_addr (sdram_addr),  .sdram_ba  (sdram_ba),
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
    .sdram_we_n (sdram_we_n),  .sdram_cs_n (sdram_cs_n),
    .sdram_dq   (sdram_dq),    .sdram_clk  (sdram_clk),
    .sdram_cke  (sdram_cke)
  );

  // ============================================================
  // SDRAM model + trace
  // ============================================================
  sdram_model_pro #(
    .DATA_WIDTH(DATA_WIDTH), .ROW_WIDTH(ROW_ADDR_WIDTH), .COL_WIDTH(COL_ADDR_WIDTH),
    .BANKS(4), .tRCD(T_RCD_CYCLES), .tRP(T_RP_CYCLES),  .tRAS(T_RAS_CYCLES),
    .tWR (T_WR_CYCLES),  .tRFC(T_RFC_CYCLES), .CL(CAS_LATENCY)
  ) u_model (
    .clk(sdram_clk), .rst(!rstn), .addr(sdram_addr), .ba(sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n), .we_n(sdram_we_n),
    .cs_n(sdram_cs_n),   .dq(sdram_dq)
  );

  sdram_cmd_trace #(
    .ROW_WIDTH(ROW_ADDR_WIDTH), .COL_WIDTH(COL_ADDR_WIDTH), .BANKS(4)
  ) u_trace (
    .clk(sdram_clk), .rstn(rstn), .addr(sdram_addr), .ba(sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n), .we_n(sdram_we_n), .cs_n(sdram_cs_n)
  );

  // ============================================================
  // Command counters (na sdram_clk)
  // ============================================================
  int cnt_act = 0, cnt_wr = 0, cnt_rd = 0, cnt_pre = 0;
  int errors  = 0;

  always @(posedge sdram_clk) begin
    if (!sdram_cs_n) begin
      case ({sdram_ras_n, sdram_cas_n, sdram_we_n})
        3'b011: cnt_act++;
        3'b100: cnt_wr++;
        3'b101: cnt_rd++;
        3'b010: if (!sdram_addr[10]) cnt_pre++;  // single-bank PRE only; skip init PRE_ALL
        default:;
      endcase
    end
  end

  // dq_i capture: dq_i drzi poslednu platnu hodnotu po valide (hold)
  // dq_i_valid je 1-cyklovy pulz; rd_valid_seen latchuje ze pulz nastal
  logic               rd_valid_seen = 1'b0;
  logic [DATA_WIDTH-1:0] rd_data    = '0;

  always @(posedge clk) begin
    if (dq_i_valid && !rd_valid_seen) begin
      rd_valid_seen = 1'b1;  // latch
      rd_data       = dq_i;
    end
  end

  // ============================================================
  // Tasks
  // ============================================================

  // Vydaj 1 NOP cyklus (s #1 pre deterministicke nacasovanie)
  task nop();
    @(posedge clk); #1;
    tb_cmd   = CMD_NOP;
    tb_dq_oe = 1'b0;
    tb_rden  = 1'b0;
  endtask

  task nops(int n);
    repeat (n) nop();
  endtask

  // ============================================================
  // Main test
  // ============================================================
  initial begin
    @(posedge rstn);
    @(posedge init_done);
    nops(4);  // safety NOPs po init

    // ----------------------------------------------------------
    // WRITE: ACT -> (tRCD NOPs) -> WR+DQ -> (margin) -> PRE -> (tRP NOPs)
    //
    // Timing (SDRAM cycles, 1 cyklus neskor ako TB):
    //   ACT@S → rcd=2,tras=4
    //   NOP x3 → rcd: 2→1→0
    //   WR@S+4 → rcd=0 OK, tras=0 (decrement), wr_timer=2
    //   NOP x4 → wr_timer: 2→1→0
    //   PRE@S+9 → wr=0 OK, tras=0 OK (single-bank: model neskontroluje)
    //   NOP x3 → rp: 2→1→0
    // ----------------------------------------------------------
    $display("[TB] WRITE: bank=%0h row=0x%04h col=0x%03h data=0x%04h",
             TEST_BANK, TEST_ROW, TEST_COL, WDATA);

    @(posedge clk); #1;
    tb_cmd = CMD_ACT; tb_addr = TEST_ROW; tb_ba = TEST_BANK;

    nops(3);  // tRCD margin (potrebne >=2)

    @(posedge clk); #1;
    tb_cmd   = CMD_WR;
    tb_addr  = ROW_ADDR_WIDTH'(TEST_COL);  // A10=0 (no auto-precharge)
    tb_ba    = TEST_BANK;
    tb_dq_o  = WDATA;
    tb_dq_oe = 1'b1;

    // clk_sh leads clk by 2.5 ns: model samples dq via blocking assign at clk_sh_{C+2}
    // = 22.5 ns after TB drives CMD_WR. The first nop() would deassert dq_oe at C+1+1ns=16 ns
    // — too soon. Hold dq_oe for one extra cycle so model sees WDATA.
    @(posedge clk); #1;
    tb_cmd   = CMD_NOP;
    // tb_dq_oe intentionally still 1 here

    nops(3);  // first nop deasserts dq_oe (at C+2+1ns > 22.5 ns OK); tWR + tRAS margin

    @(posedge clk); #1;
    tb_cmd = CMD_PRE; tb_addr = '0; tb_ba = TEST_BANK;

    nops(3);  // tRP margin (potrebne >=2)

    // ----------------------------------------------------------
    // READ: ACT -> (tRCD NOPs) -> RD+read_en -> (CAS pipeline) -> capture
    //
    // dq_i_valid pulse = CAS_LATENCY+2 = 5 cyklov po drive RD
    // rd_data latchuje v always @(posedge clk) pri dq_i_valid
    // ----------------------------------------------------------
    $display("[TB] READ:  bank=%0h row=0x%04h col=0x%03h",
             TEST_BANK, TEST_ROW, TEST_COL);

    @(posedge clk); #1;
    tb_cmd = CMD_ACT; tb_addr = TEST_ROW; tb_ba = TEST_BANK;

    nops(3);  // tRCD margin

    @(posedge clk); #1;
    tb_cmd  = CMD_RD;
    tb_addr = ROW_ADDR_WIDTH'(TEST_COL);  // A10=0
    tb_ba   = TEST_BANK;
    tb_rden = 1'b1;

    // Deassert read_en, cakaj na CAS pipeline (CAS_LATENCY+2=5) + margin
    nops(1);  // deassert rden (nop() sets rden=0)
    repeat (CAS_LATENCY + 4) @(posedge clk);  // celkovo 1+7 = 8 cyklov od RD drive

    // PRE po citani (tRDL + tRAS margin)
    nops(4);
    @(posedge clk); #1;
    tb_cmd = CMD_PRE; tb_addr = '0; tb_ba = TEST_BANK;
    nops(3);

    // ----------------------------------------------------------
    // Verifikacia
    // ----------------------------------------------------------
    if (cnt_act != 2) begin
      $error("[FAIL] ACT: expected 2, got %0d", cnt_act);
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
    if (cnt_pre != 2) begin
      $error("[FAIL] PRE: expected 2, got %0d", cnt_pre);
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
