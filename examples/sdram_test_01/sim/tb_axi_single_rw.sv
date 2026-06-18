/**
 * @file tb_axi_single_rw.sv
 * @brief Testbench — sdram_test_04_axi_single_rw milestone.
 *
 * @details
 * DUT: sdram_system_top (full AXI controller with scheduler, gearboxes, PHY).
 * Single AXI write (AWLEN=0) followed by single AXI read (ARLEN=0).
 * RREADY=1, BREADY=1 — no backpressure (known limitation of this milestone).
 *
 * AXI address layout (DATA_WIDTH=16):
 *   [0]      = byte offset (ignored)
 *   [9:1]    = col  (9 bits)
 *   [11:10]  = bank (2 bits)
 *   [24:12]  = row  (13 bits)
 *
 * Test: bank=0, row=0x10, col=8
 *   AXI addr = (0x10<<12) | (0<<10) | (8<<1) = 0x0001_0010
 *
 * Expected command trace on SDRAM bus (post-init):
 *   ACT B0 R0x10         (closed bank -> activate)
 *   WR  B0 C8            (after tRCD)
 *   WR  B0 C9            (row-hit, gearbox phase1, after tWTR)
 *   RD  B0 C8            (row-hit, after tWTR from last WR)
 *   RD  B0 C9            (row-hit, gearbox phase1)
 *
 * Definition of done:
 *   cnt_act==1, cnt_wr==2, cnt_rd==2, cnt_pre==0
 *   RDATA == 0x1234_A5C3
 *   RLAST == 1, RID == AXI_TEST_RID
 *   sdram_model_pro: no timing violations
 */

`timescale 1ns/1ps
`default_nettype none
import sdram_pkg::*;

module tb_axi_single_rw;

  // AXI test parameters
  localparam logic [31:0] AXI_TEST_ADDR  = 32'h0001_0010;
  localparam logic [31:0] AXI_TEST_WDATA = 32'h1234_A5C3;
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
  // DUT: sdram_system_top
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
  // SDRAM model + trace (on sdram_clk = forwarded clock)
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
  // Command counters (on sdram_clk — same domain as SDRAM bus)
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
  // AXI read response capture (on clk — AXI domain)
  // ============================================================
  logic [31:0] rd_data      = '0;
  logic [3:0]  rd_id        = '0;
  logic        rd_last       = 1'b0;
  logic        rd_valid_seen = 1'b0;

  always @(posedge clk) begin
    if (s_axi_rvalid && !rd_valid_seen) begin
      rd_valid_seen = 1'b1;
      rd_data       = s_axi_rdata;
      rd_id         = s_axi_rid;
      rd_last       = s_axi_rlast;
    end
  end

  // ============================================================
  // Main test sequence
  // ============================================================
  initial begin
    // Default AXI idle state
    s_axi_arvalid = 1'b0;  s_axi_arid   = '0;  s_axi_araddr = '0;  s_axi_arlen  = '0;
    s_axi_rready  = 1'b1;
    s_axi_awvalid = 1'b0;  s_axi_awid   = '0;  s_axi_awaddr = '0;  s_axi_awlen  = '0;
    s_axi_wvalid  = 1'b0;  s_axi_wdata  = '0;  s_axi_wlast  = 1'b0;
    s_axi_bready  = 1'b1;

    @(posedge rstn);
    @(posedge u_dut.init_done);
    repeat(4) @(posedge clk);

    // ----------------------------------------------------------
    // AXI WRITE: 32-bit single beat to bank=0, row=0x10, col=8
    //   -> gearbox: WR C8 (low word 0xA5C3) + WR C9 (high word 0x1234)
    // ----------------------------------------------------------
    $display("[TB] AXI WRITE: addr=0x%08x data=0x%08x", AXI_TEST_ADDR, AXI_TEST_WDATA);

    @(posedge clk); #1;
    s_axi_awid    = AXI_TEST_WID;
    s_axi_awaddr  = AXI_TEST_ADDR;
    s_axi_awlen   = 8'h00;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = AXI_TEST_WDATA;
    s_axi_wlast   = 1'b1;
    s_axi_wvalid  = 1'b1;

    // AW handshake: awready=1 from reset; wait for posedge where it fires
    while (!s_axi_awready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_awvalid = 1'b0;

    // W handshake: wready=1 one cycle after AW (aw_active && GS_IDLE)
    while (!s_axi_wready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_wvalid = 1'b0;
    s_axi_wlast  = 1'b0;

    // B response (early BVALID after gearbox phase1 — known limitation)
    while (!s_axi_bvalid) @(posedge clk);
    $display("[TB] BVALID: bid=0x%x bresp=%0b", s_axi_bid, s_axi_bresp);
    repeat(4) @(posedge clk);

    // ----------------------------------------------------------
    // AXI READ: same address — bank=0, row=0x10 is still open
    //   -> gearbox: RD C8 + RD C9  (row-hit after tWTR)
    // ----------------------------------------------------------
    $display("[TB] AXI READ:  addr=0x%08x", AXI_TEST_ADDR);

    @(posedge clk); #1;
    s_axi_arid    = AXI_TEST_RID;
    s_axi_araddr  = AXI_TEST_ADDR;
    s_axi_arlen   = 8'h00;
    s_axi_arvalid = 1'b1;

    // AR handshake
    while (!s_axi_arready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_arvalid = 1'b0;

    // Wait for read data (gearbox reassembles 2x16-bit -> 32-bit)
    while (!rd_valid_seen) @(posedge clk);
    repeat(2) @(posedge clk);

    // ----------------------------------------------------------
    // Verification
    // ----------------------------------------------------------
    if (cnt_act != 1) begin
      $error("[FAIL] ACT: expected 1, got %0d", cnt_act);
      errors++;
    end
    if (cnt_wr != 2) begin
      $error("[FAIL] WR: expected 2, got %0d", cnt_wr);
      errors++;
    end
    if (cnt_rd != 2) begin
      $error("[FAIL] RD: expected 2, got %0d", cnt_rd);
      errors++;
    end
    if (cnt_pre != 0) begin
      $error("[FAIL] PRE: expected 0, got %0d", cnt_pre);
      errors++;
    end
    if (!rd_valid_seen) begin
      $error("[FAIL] RVALID never asserted");
      errors++;
    end
    if (rd_data !== AXI_TEST_WDATA) begin
      $error("[FAIL] RDATA mismatch: expected 0x%08x got 0x%08x",
             AXI_TEST_WDATA, rd_data);
      errors++;
    end
    if (rd_id !== AXI_TEST_RID) begin
      $error("[FAIL] RID mismatch: expected 0x%x got 0x%x", AXI_TEST_RID, rd_id);
      errors++;
    end
    if (!rd_last) begin
      $error("[FAIL] RLAST not asserted for single-beat read");
      errors++;
    end

    $display("");
    $display("=============================================================");
    $display("  ACT=%0d WR=%0d RD=%0d PRE=%0d",
             cnt_act, cnt_wr, cnt_rd, cnt_pre);
    $display("  Write=0x%08x  Read=0x%08x  rlast=%0b  rid=0x%x",
             AXI_TEST_WDATA, rd_data, rd_last, rd_id);
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
    $fatal(1, "[WATCHDOG] Timeout at %0t ns (init_done=%0b rd_valid_seen=%0b)",
           $time, u_dut.init_done, rd_valid_seen);
  end

endmodule
