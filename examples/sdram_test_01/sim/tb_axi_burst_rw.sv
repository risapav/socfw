/**
 * @file tb_axi_burst_rw.sv
 * @brief Testbench -- sdram_test_05_axi_burst_rw milestone (M5a).
 *
 * @details
 * DUT: sdram_system_top (full AXI controller).
 * 2-beat AXI write (AWLEN=1) + 2-beat AXI read (ARLEN=1).
 * RREADY=1, BREADY=1 -- no backpressure.
 *
 * AXI address layout (DATA_WIDTH=16):
 *   [0]      = byte offset (ignored)
 *   [9:1]    = col  (9 bits)
 *   [11:10]  = bank (2 bits)
 *   [24:12]  = row  (13 bits)
 *
 * Test: bank=0, row=0x10, col=8
 *   Beat 0: AXI addr = 0x0001_0010  -> col=8  (ph0), col=9  (ph1)
 *   Beat 1: AXI addr = 0x0001_0014  -> col=10 (ph0), col=11 (ph1)
 *
 * Expected SDRAM command trace (post-init):
 *   ACT B0 R0x10
 *   WR  B0 C8    (low  word beat0: 0xBEEF)
 *   WR  B0 C9    (high word beat0: 0xDEAD)
 *   WR  B0 C10   (low  word beat1: 0x5678)
 *   WR  B0 C11   (high word beat1: 0x1234)
 *   RD  B0 C8
 *   RD  B0 C9
 *   RD  B0 C10
 *   RD  B0 C11
 *
 * Definition of done:
 *   cnt_act==1, cnt_wr==4, cnt_rd==4, cnt_pre==0
 *   RDATA[0] == 0xDEAD_BEEF, RLAST[0] == 0, RID[0] == AXI_TEST_RID
 *   RDATA[1] == 0x1234_5678, RLAST[1] == 1, RID[1] == AXI_TEST_RID
 *   sdram_model_pro: no timing violations
 */

`timescale 1ns/1ps
`default_nettype none
import sdram_pkg::*;

module tb_axi_burst_rw;

  // AXI test parameters
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
        3'b010: if (!sdram_addr[10]) cnt_pre++;
        default: ;
      endcase
    end
  end

  // ============================================================
  // AXI read response capture -- 2 beats
  // ============================================================
  logic [31:0] rd_data [0:1];
  logic [3:0]  rd_id   [0:1];
  logic        rd_last [0:1];
  int          rd_cnt = 0;

  always @(posedge clk) begin
    if (s_axi_rvalid && s_axi_rready && rd_cnt < 2) begin
      rd_data[rd_cnt] = s_axi_rdata;
      rd_id  [rd_cnt] = s_axi_rid;
      rd_last[rd_cnt] = s_axi_rlast;
      rd_cnt++;
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
    // AXI WRITE: 2-beat burst
    //   Beat 0: addr=0x0001_0010  wdata=0xDEAD_BEEF  wlast=0
    //   Beat 1: addr=0x0001_0014  wdata=0x1234_5678  wlast=1
    // ----------------------------------------------------------
    $display("[TB] AXI WRITE: addr=0x%08x len=1 data={0x%08x, 0x%08x}",
             AXI_TEST_ADDR, WDATA_0, WDATA_1);

    @(posedge clk); #1;
    s_axi_awid    = AXI_TEST_WID;
    s_axi_awaddr  = AXI_TEST_ADDR;
    s_axi_awlen   = 8'h01;
    s_axi_awvalid = 1'b1;
    // W beat 0 simultaneously with AW
    s_axi_wdata   = WDATA_0;
    s_axi_wlast   = 1'b0;
    s_axi_wvalid  = 1'b1;

    // AW handshake
    while (!s_axi_awready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_awvalid = 1'b0;

    // W beat 0 handshake (wready=1 from aw_active && GS_IDLE)
    while (!s_axi_wready) @(posedge clk);
    @(posedge clk); #1;
    // Beat 0 accepted; switch to beat 1
    s_axi_wdata = WDATA_1;
    s_axi_wlast = 1'b1;

    // W beat 1 handshake (after gearbox processes beat0 and returns to GS_IDLE)
    while (!s_axi_wready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_wvalid = 1'b0;
    s_axi_wlast  = 1'b0;

    // B response
    while (!s_axi_bvalid) @(posedge clk);
    $display("[TB] BVALID: bid=0x%x bresp=%0b", s_axi_bid, s_axi_bresp);
    repeat(4) @(posedge clk);

    // ----------------------------------------------------------
    // AXI READ: 2-beat burst, same address range
    //   Beat 0: addr=0x0001_0010  expected RDATA=0xDEAD_BEEF  RLAST=0
    //   Beat 1: addr=0x0001_0014  expected RDATA=0x1234_5678  RLAST=1
    // ----------------------------------------------------------
    $display("[TB] AXI READ:  addr=0x%08x len=1", AXI_TEST_ADDR);

    @(posedge clk); #1;
    s_axi_arid    = AXI_TEST_RID;
    s_axi_araddr  = AXI_TEST_ADDR;
    s_axi_arlen   = 8'h01;
    s_axi_arvalid = 1'b1;

    // AR handshake
    while (!s_axi_arready) @(posedge clk);
    @(posedge clk); #1;
    s_axi_arvalid = 1'b0;

    // Wait for both read beats
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
    if (rd_cnt < 2) begin
      $error("[FAIL] Only %0d RVALID beats seen (expected 2)", rd_cnt);
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
    $display("  ACT=%0d WR=%0d RD=%0d PRE=%0d",
             cnt_act, cnt_wr, cnt_rd, cnt_pre);
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
    $fatal(1, "[WATCHDOG] Timeout at %0t ns (init_done=%0b rd_cnt=%0d)",
           $time, u_dut.init_done, rd_cnt);
  end

endmodule
