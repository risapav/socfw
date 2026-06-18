/**
 * @file tb_axi_backpressure.sv
 * @brief Testbench -- sdram_test_05b_axi_backpressure milestone.
 *
 * @details
 * DUT: sdram_system_top (full AXI controller).
 * Test R-channel backpressure: RREADY=0 pocas oboch beatov burstu.
 * Po zostaveni oboch beatov (output + skid) sa pustiRREADY=1 a oba sa drainuju.
 *
 * Scenar:
 *   1. Write 2-beat burst: 0xDEAD_BEEF + 0x1234_5678 (rovnake ako M5a)
 *   2. Read  2-beat burst s RREADY=0 od startu
 *   3. Cakaj kym rvalid=1 (beat0 v output registri, RREADY=0 -> stall)
 *   4. Cakaj este 5 cyklov (beat1 sa assembuje do skid registra)
 *   5. RREADY=1 -> oba beaty sa drainuju
 *
 * Definition of done:
 *   rvalid zostal stable pocas stallu (AXI protocol)
 *   RDATA[0] == 0xDEAD_BEEF, RLAST[0] == 0, RID[0] == AXI_TEST_RID
 *   RDATA[1] == 0x1234_5678, RLAST[1] == 1, RID[1] == AXI_TEST_RID
 *   cnt_act==1, cnt_wr==4, cnt_rd==4, cnt_pre==0
 *   sdram_model_pro: no timing violations
 */

`timescale 1ns/1ps
`default_nettype none
import sdram_pkg::*;

module tb_axi_backpressure;

  localparam logic [31:0] AXI_TEST_ADDR  = 32'h0001_0010;
  localparam logic [31:0] WDATA_0        = 32'hDEAD_BEEF;
  localparam logic [31:0] WDATA_1        = 32'h1234_5678;
  localparam logic [3:0]  AXI_TEST_WID   = 4'h3;
  localparam logic [3:0]  AXI_TEST_RID   = 4'h5;

  // ============================================================
  // Clocks and reset
  // ============================================================
  logic clk, clk_sh, rstn;
  initial begin clk    = 1'b0; forever #5    clk    = ~clk;    end
  initial begin clk_sh = 1'b0; #2.5; forever #5 clk_sh = ~clk_sh; end
  initial begin rstn   = 1'b0; repeat(5) @(posedge clk); @(negedge clk); rstn = 1'b1; end

  // ============================================================
  // AXI signals
  // ============================================================
  logic [3:0]  s_axi_arid,   s_axi_rid;
  logic [3:0]  s_axi_awid,   s_axi_bid;
  logic [31:0] s_axi_araddr, s_axi_awaddr;
  logic [7:0]  s_axi_arlen,  s_axi_awlen;
  logic        s_axi_arvalid, s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic        s_axi_rlast,  s_axi_rvalid,  s_axi_rready;
  logic        s_axi_awvalid, s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic        s_axi_wlast,  s_axi_wvalid,  s_axi_wready;
  logic        s_axi_bvalid, s_axi_bready;
  logic [1:0]  s_axi_bresp;

  // ============================================================
  // SDRAM interface
  // ============================================================
  wire [ROW_ADDR_WIDTH-1:0]  sdram_addr;
  wire [BANK_ADDR_WIDTH-1:0] sdram_ba;
  wire                       sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cs_n;
  wire [DATA_WIDTH-1:0]      sdram_dq;
  wire                       sdram_clk, sdram_cke;

  // ============================================================
  // DUT
  // ============================================================
  sdram_system_top u_dut (
    .clk          (clk),          .clk_sh        (clk_sh),       .rstn          (rstn),
    .s_axi_arid   (s_axi_arid),   .s_axi_araddr  (s_axi_araddr), .s_axi_arlen   (s_axi_arlen),
    .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rid    (s_axi_rid),    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rlast  (s_axi_rlast),  .s_axi_rvalid  (s_axi_rvalid), .s_axi_rready  (s_axi_rready),
    .s_axi_awid   (s_axi_awid),   .s_axi_awaddr  (s_axi_awaddr), .s_axi_awlen   (s_axi_awlen),
    .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata  (s_axi_wdata),  .s_axi_wlast   (s_axi_wlast),
    .s_axi_wvalid (s_axi_wvalid), .s_axi_wready  (s_axi_wready),
    .s_axi_bvalid (s_axi_bvalid), .s_axi_bready  (s_axi_bready),
    .s_axi_bresp  (s_axi_bresp),  .s_axi_bid     (s_axi_bid),
    .sdram_addr   (sdram_addr),   .sdram_ba      (sdram_ba),
    .sdram_ras_n  (sdram_ras_n),  .sdram_cas_n   (sdram_cas_n),
    .sdram_we_n   (sdram_we_n),   .sdram_cs_n    (sdram_cs_n),
    .sdram_dq     (sdram_dq),     .sdram_clk     (sdram_clk),    .sdram_cke     (sdram_cke)
  );

  // ============================================================
  // SDRAM model + trace
  // ============================================================
  sdram_model_pro #(
    .DATA_WIDTH(DATA_WIDTH),     .ROW_WIDTH (ROW_ADDR_WIDTH), .COL_WIDTH(COL_ADDR_WIDTH),
    .BANKS(4),
    .tRCD(T_RCD_CYCLES), .tRP(T_RP_CYCLES), .tRAS(T_RAS_CYCLES),
    .tWR (T_WR_CYCLES),  .tRFC(T_RFC_CYCLES), .CL(CAS_LATENCY)
  ) u_model (
    .clk  (sdram_clk), .rst(!rstn),
    .addr (sdram_addr), .ba(sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),  .cs_n (sdram_cs_n),
    .dq   (sdram_dq)
  );

  sdram_cmd_trace #(
    .ROW_WIDTH(ROW_ADDR_WIDTH), .COL_WIDTH(COL_ADDR_WIDTH), .BANKS(4)
  ) u_trace (
    .clk  (sdram_clk), .rstn(rstn),
    .addr (sdram_addr), .ba(sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),  .cs_n (sdram_cs_n)
  );

  // ============================================================
  // Command counters
  // ============================================================
  int cnt_act = 0, cnt_wr = 0, cnt_rd = 0, cnt_pre = 0;
  int errors  = 0;

  always @(posedge sdram_clk) begin
    if (!sdram_cs_n) begin
      case ({sdram_ras_n, sdram_cas_n, sdram_we_n})
        3'b011: cnt_act++;
        3'b100: cnt_wr++;
        3'b101: cnt_rd++;
        3'b010: if (!sdram_addr[10]) cnt_pre++;
        default: ;
      endcase
    end
  end

  // ============================================================
  // AXI R capture (RREADY gated -- only capture on handshake)
  // ============================================================
  logic [31:0] rd_data [0:1];
  logic [3:0]  rd_id   [0:1];
  logic        rd_last [0:1];
  int          rd_cnt = 0;

  // AXI protocol check: rvalid must not drop while rready=0
  logic        rvalid_seen  = 1'b0;
  int          rvalid_drops = 0;

  always @(posedge clk) begin
    if (s_axi_rvalid) rvalid_seen <= 1'b1;
    // Once rvalid fires, it must not drop until rready is seen
    if (rvalid_seen && !s_axi_rvalid && !s_axi_rready) begin
      $warning("[TB] RVALID dropped without RREADY at %0t ns", $time);
      rvalid_drops++;
    end
    // Capture on handshake
    if (s_axi_rvalid && s_axi_rready && rd_cnt < 2) begin
      rd_data[rd_cnt] = s_axi_rdata;
      rd_id  [rd_cnt] = s_axi_rid;
      rd_last[rd_cnt] = s_axi_rlast;
      rd_cnt++;
      if (rd_cnt < 2) rvalid_seen <= 1'b0;  // reset for next beat
    end
  end

  // ============================================================
  // Main test sequence
  // ============================================================
  initial begin
    // Default AXI idle state; RREADY=0 from start (backpressure test)
    s_axi_arvalid = 1'b0;  s_axi_arid   = '0;  s_axi_araddr = '0;  s_axi_arlen  = '0;
    s_axi_rready  = 1'b0;   // <-- backpressure ON
    s_axi_awvalid = 1'b0;  s_axi_awid   = '0;  s_axi_awaddr = '0;  s_axi_awlen  = '0;
    s_axi_wvalid  = 1'b0;  s_axi_wdata  = '0;  s_axi_wlast  = 1'b0;
    s_axi_bready  = 1'b1;

    @(posedge rstn);
    @(posedge u_dut.init_done);
    repeat(4) @(posedge clk);

    // ----------------------------------------------------------
    // AXI WRITE: 2-beat burst (rovnake ako M5a)
    // ----------------------------------------------------------
    $display("[TB] AXI WRITE: addr=0x%08x len=1 data={0x%08x, 0x%08x}",
             AXI_TEST_ADDR, WDATA_0, WDATA_1);

    @(posedge clk); #1;
    s_axi_awid    = AXI_TEST_WID;
    s_axi_awaddr  = AXI_TEST_ADDR;
    s_axi_awlen   = 8'h01;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = WDATA_0;
    s_axi_wlast   = 1'b0;
    s_axi_wvalid  = 1'b1;

    while (!s_axi_awready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_awvalid = 1'b0;

    while (!s_axi_wready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_wdata = WDATA_1;
    s_axi_wlast = 1'b1;

    while (!s_axi_wready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_wvalid = 1'b0;
    s_axi_wlast  = 1'b0;

    while (!s_axi_bvalid) @(posedge clk);
    $display("[TB] BVALID: bid=0x%x bresp=%0b", s_axi_bid, s_axi_bresp);
    repeat(4) @(posedge clk);

    // ----------------------------------------------------------
    // AXI READ: 2-beat burst, RREADY=0 (backpressure)
    // ----------------------------------------------------------
    $display("[TB] AXI READ (backpressure): addr=0x%08x len=1 RREADY=0", AXI_TEST_ADDR);

    @(posedge clk); #1;
    s_axi_arid    = AXI_TEST_RID;
    s_axi_araddr  = AXI_TEST_ADDR;
    s_axi_arlen   = 8'h01;
    s_axi_arvalid = 1'b1;

    // AR handshake
    while (!s_axi_arready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_arvalid = 1'b0;

    // Cakaj kym beat0 sa objavi v output registri (rvalid=1, rready=0 -> stall)
    while (!s_axi_rvalid) @(posedge clk);
    $display("[TB] Beat0 stalled in output register (rvalid=1, rready=0)");

    // Daj beat1 cas na assemblovanie do skid registra
    repeat(8) @(posedge clk);
    $display("[TB] Releasing RREADY=1 to drain output + skid");

    @(posedge clk); #1;
    s_axi_rready = 1'b1;

    // Cakaj na oba beaty
    while (rd_cnt < 2) @(posedge clk);
    repeat(2) @(posedge clk);

    // ----------------------------------------------------------
    // Verification
    // ----------------------------------------------------------
    if (cnt_act != 1) begin
      $error("[FAIL] ACT: expected 1, got %0d", cnt_act);
      errors++;
    end
    if (cnt_wr != 4) begin
      $error("[FAIL] WR: expected 4, got %0d", cnt_wr);
      errors++;
    end
    if (cnt_rd != 4) begin
      $error("[FAIL] RD: expected 4, got %0d", cnt_rd);
      errors++;
    end
    if (cnt_pre != 0) begin
      $error("[FAIL] PRE: expected 0, got %0d", cnt_pre);
      errors++;
    end
    if (rvalid_drops != 0) begin
      $error("[FAIL] AXI protocol: RVALID dropped %0d time(s) without RREADY", rvalid_drops);
      errors++;
    end
    if (rd_cnt < 2) begin
      $error("[FAIL] Only %0d RVALID beats captured (expected 2)", rd_cnt);
      errors++;
    end else begin
      if (rd_data[0] !== WDATA_0) begin
        $error("[FAIL] RDATA[0]: expected 0x%08x got 0x%08x", WDATA_0, rd_data[0]);
        errors++;
      end
      if (rd_last[0] !== 1'b0) begin
        $error("[FAIL] RLAST[0]: expected 0, got %0b", rd_last[0]);
        errors++;
      end
      if (rd_id[0] !== AXI_TEST_RID) begin
        $error("[FAIL] RID[0]: expected 0x%x got 0x%x", AXI_TEST_RID, rd_id[0]);
        errors++;
      end
      if (rd_data[1] !== WDATA_1) begin
        $error("[FAIL] RDATA[1]: expected 0x%08x got 0x%08x", WDATA_1, rd_data[1]);
        errors++;
      end
      if (rd_last[1] !== 1'b1) begin
        $error("[FAIL] RLAST[1]: expected 1, got %0b", rd_last[1]);
        errors++;
      end
      if (rd_id[1] !== AXI_TEST_RID) begin
        $error("[FAIL] RID[1]: expected 0x%x got 0x%x", AXI_TEST_RID, rd_id[1]);
        errors++;
      end
    end

    $display("");
    $display("=============================================================");
    $display("  ACT=%0d WR=%0d RD=%0d PRE=%0d  RVALID_drops=%0d",
             cnt_act, cnt_wr, cnt_rd, cnt_pre, rvalid_drops);
    if (rd_cnt >= 2) begin
      $display("  Beat0: 0x%08x  rlast=%0b  rid=0x%x",
               rd_data[0], rd_last[0], rd_id[0]);
      $display("  Beat1: 0x%08x  rlast=%0b  rid=0x%x",
               rd_data[1], rd_last[1], rd_id[1]);
    end
    if (errors == 0)
      $display("  *** PASS ***");
    else
      $display("  *** FAIL *** (errors=%0d)", errors);
    $display("=============================================================");
    $finish;
  end

  // ============================================================
  // Watchdog
  // ============================================================
  initial begin
    #25_000_000;
    $fatal(1, "[WATCHDOG] Timeout at %0t ns (init_done=%0b rd_cnt=%0d rvalid=%0b)",
           $time, u_dut.init_done, rd_cnt, s_axi_rvalid);
  end

endmodule
