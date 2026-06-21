// @file tb_axi_native_adapter_protocol_unit.sv
// @brief Protocol guard unit tests: P1-P5 normal paths, E1-E3 error paths.
// @details Fake native backend (no PHY, no SDRAM model).
//          P1: AW then W -- OKAY
//          P2: W then AW -- OKAY
//          P3: native_req_ready stall 3 cy -- per-cycle req stability check
//          P4: BREADY stall 3 cy -- per-cycle: BVALID stable, AW/W not accepted
//          P5: RREADY stall 3 cy -- per-cycle: RVALID stable, AR not accepted
//          E1: unaligned write addr -- SLVERR, native_req never issued (2 cy)
//          E2: partial WSTRB -- SLVERR, native_req never issued (2 cy)
//          E3: unaligned read addr -- SLVERR, native_req never issued (2 cy)
`ifndef TB_AXI_NATIVE_ADAPTER_PROTOCOL_UNIT_SV
`define TB_AXI_NATIVE_ADAPTER_PROTOCOL_UNIT_SV
`default_nettype none
`timescale 1ns/1ps

module tb_axi_native_adapter_protocol_unit;

  localparam int CLK_HALF = 4;
  localparam int TIMEOUT  = 400;

  // -------------------------------------------------------------------------
  // Clock
  // -------------------------------------------------------------------------
  logic clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  // -------------------------------------------------------------------------
  // DUT signals with safe defaults
  // -------------------------------------------------------------------------
  logic [23:0] s_axi_awaddr  = '0;
  logic        s_axi_awvalid = 1'b0;
  logic        s_axi_awready;
  logic [31:0] s_axi_wdata   = '0;
  logic  [3:0] s_axi_wstrb   = 4'b1111;
  logic        s_axi_wvalid  = 1'b0;
  logic        s_axi_wready;
  logic  [1:0] s_axi_bresp;
  logic        s_axi_bvalid;
  logic        s_axi_bready  = 1'b0;
  logic [23:0] s_axi_araddr  = '0;
  logic        s_axi_arvalid = 1'b0;
  logic        s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic  [1:0] s_axi_rresp;
  logic        s_axi_rvalid;
  logic        s_axi_rready  = 1'b0;
  logic        native_req_valid;
  logic        native_req_ready  = 1'b1;
  logic        native_req_write;
  logic [23:0] native_req_addr;
  logic [31:0] native_req_wdata;
  logic        native_rsp_valid  = 1'b0;
  logic [31:0] native_rsp_rdata  = '0;
  logic        rstn = 1'b0;

  // -------------------------------------------------------------------------
  // DUT
  // -------------------------------------------------------------------------
  axi_native_adapter #(
    .AXI_ADDR_WIDTH   (24),
    .AXI_DATA_WIDTH   (32),
    .NATIVE_ADDR_WIDTH(24)
  ) dut (
    .clk             (clk),
    .rstn            (rstn),
    .s_axi_awaddr    (s_axi_awaddr),
    .s_axi_awvalid   (s_axi_awvalid),
    .s_axi_awready   (s_axi_awready),
    .s_axi_wdata     (s_axi_wdata),
    .s_axi_wstrb     (s_axi_wstrb),
    .s_axi_wvalid    (s_axi_wvalid),
    .s_axi_wready    (s_axi_wready),
    .s_axi_bresp     (s_axi_bresp),
    .s_axi_bvalid    (s_axi_bvalid),
    .s_axi_bready    (s_axi_bready),
    .s_axi_araddr    (s_axi_araddr),
    .s_axi_arvalid   (s_axi_arvalid),
    .s_axi_arready   (s_axi_arready),
    .s_axi_rdata     (s_axi_rdata),
    .s_axi_rresp     (s_axi_rresp),
    .s_axi_rvalid    (s_axi_rvalid),
    .s_axi_rready    (s_axi_rready),
    .native_req_valid(native_req_valid),
    .native_req_ready(native_req_ready),
    .native_req_write(native_req_write),
    .native_req_addr (native_req_addr),
    .native_req_wdata(native_req_wdata),
    .native_rsp_valid(native_rsp_valid),
    .native_rsp_rdata(native_rsp_rdata)
  );

  // -------------------------------------------------------------------------
  // Checkers
  // -------------------------------------------------------------------------
  integer errors = 0;

  task automatic check1;
    input        got;
    input        exp;
    input [127:0] tag;
    if (got !== exp) begin
      $display("FAIL [%s] got=1'b%b exp=1'b%b", tag, got, exp);
      errors = errors + 1;
    end else begin
      $display("  ok [%s] = 1'b%b", tag, got);
    end
  endtask

  task automatic check2;
    input [1:0]   got;
    input [1:0]   exp;
    input [127:0] tag;
    if (got !== exp) begin
      $display("FAIL [%s] got=2'b%02b exp=2'b%02b", tag, got, exp);
      errors = errors + 1;
    end else begin
      $display("  ok [%s] = 2'b%02b", tag, got);
    end
  endtask

  task automatic check24;
    input [23:0]  got;
    input [23:0]  exp;
    input [127:0] tag;
    if (got !== exp) begin
      $display("FAIL [%s] got=0x%06h exp=0x%06h", tag, got, exp);
      errors = errors + 1;
    end else begin
      $display("  ok [%s] = 0x%06h", tag, got);
    end
  endtask

  task automatic check32;
    input [31:0]  got;
    input [31:0]  exp;
    input [127:0] tag;
    if (got !== exp) begin
      $display("FAIL [%s] got=0x%08h exp=0x%08h", tag, got, exp);
      errors = errors + 1;
    end else begin
      $display("  ok [%s] = 0x%08h", tag, got);
    end
  endtask

  // -------------------------------------------------------------------------
  // Timeout watchdog
  // -------------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (cyc > TIMEOUT) begin
      $display("TIMEOUT at cycle %0d", cyc);
      $finish;
    end
  end

  // -------------------------------------------------------------------------
  // Test body
  // -------------------------------------------------------------------------
  initial begin
    $display("# BUILD_CONFIG PROJECT=sdram_test_04 RSHIFT=0 CMDREG=1");
    $display("# TB: tb_axi_native_adapter_protocol_unit");

    // reset
    repeat (4) @(posedge clk);
    rstn <= 1'b1;
    @(posedge clk); #1;

    // =====================================================================
    // P1: AW arrives before W -- normal OKAY write
    // =====================================================================
    $display("-- P1: AW then W, BRESP=OKAY --");
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= 24'h000000;
    @(posedge clk); #1;                      // IDLE -> AW_ONLY
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b1;
    s_axi_wdata   <= 32'h1234_A5C3;
    s_axi_wstrb   <= 4'b1111;
    @(posedge clk); #1;                      // AW_ONLY -> WR_ISSU, bresp_r=OKAY
    s_axi_wvalid <= 1'b0;
    check32(native_req_wdata, 32'h1234_A5C3, "P1:wdata");
    @(posedge clk); #1;                      // WR_ISSU -> BVALID (ready=1)
    check2(s_axi_bresp, 2'b00, "P1:bresp");
    s_axi_bready <= 1'b1;
    @(posedge clk); #1;                      // BVALID -> IDLE
    s_axi_bready <= 1'b0;

    // =====================================================================
    // P2: W arrives before AW -- normal OKAY write
    // =====================================================================
    $display("-- P2: W then AW, BRESP=OKAY --");
    s_axi_wvalid <= 1'b1;
    s_axi_wdata  <= 32'hDEAD_BEEF;
    s_axi_wstrb  <= 4'b1111;
    @(posedge clk); #1;                      // IDLE -> W_ONLY
    s_axi_wvalid  <= 1'b0;
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= 24'h000004;
    @(posedge clk); #1;                      // W_ONLY -> WR_ISSU, bresp_r=OKAY
    s_axi_awvalid <= 1'b0;
    check32(native_req_wdata, 32'hDEAD_BEEF, "P2:wdata");
    @(posedge clk); #1;                      // WR_ISSU -> BVALID
    check2(s_axi_bresp, 2'b00, "P2:bresp");
    s_axi_bready <= 1'b1;
    @(posedge clk); #1;                      // BVALID -> IDLE
    s_axi_bready <= 1'b0;

    // =====================================================================
    // P3: native_req_ready stall -- per-cycle: req valid, write, addr, wdata
    // =====================================================================
    $display("-- P3: native_req_ready stall, per-cycle req stability --");
    native_req_ready <= 1'b0;
    @(posedge clk); #1;                      // idle cycle with ready=0
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= 24'h000000;
    s_axi_wvalid  <= 1'b1;
    s_axi_wdata   <= 32'hCAFE_BEEF;
    s_axi_wstrb   <= 4'b1111;
    @(posedge clk); #1;                      // IDLE -> WR_ISSU (ready=0)
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    // stall cycle 1
    check1(native_req_valid, 1'b1, "P3:c1:req_valid");
    check1(native_req_write, 1'b1, "P3:c1:req_write");
    check24(native_req_addr, 24'h000000, "P3:c1:req_addr");
    check32(native_req_wdata, 32'hCAFE_BEEF, "P3:c1:wdata");
    @(posedge clk); #1;                      // stall cycle 2 (WR_ISSU, ready=0)
    check1(native_req_valid, 1'b1, "P3:c2:req_valid");
    check1(native_req_write, 1'b1, "P3:c2:req_write");
    check24(native_req_addr, 24'h000000, "P3:c2:req_addr");
    check32(native_req_wdata, 32'hCAFE_BEEF, "P3:c2:wdata");
    @(posedge clk); #1;                      // stall cycle 3 (WR_ISSU, ready=0)
    check1(native_req_valid, 1'b1, "P3:c3:req_valid");
    check1(native_req_write, 1'b1, "P3:c3:req_write");
    check24(native_req_addr, 24'h000000, "P3:c3:req_addr");
    check32(native_req_wdata, 32'hCAFE_BEEF, "P3:c3:wdata");
    native_req_ready <= 1'b1;
    @(posedge clk); #1;                      // WR_ISSU -> BVALID
    check2(s_axi_bresp, 2'b00, "P3:bresp");
    s_axi_bready <= 1'b1;
    @(posedge clk); #1;                      // BVALID -> IDLE
    s_axi_bready <= 1'b0;

    // =====================================================================
    // P4: BREADY stall -- BVALID stable, new AW/W not accepted during stall
    // =====================================================================
    $display("-- P4: bready stall, BVALID stable, AW/W not accepted --");
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= 24'h000000;
    s_axi_wvalid  <= 1'b1;
    s_axi_wdata   <= 32'hDEAD_CAFE;
    s_axi_wstrb   <= 4'b1111;
    @(posedge clk); #1;                      // IDLE -> WR_ISSU
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    @(posedge clk); #1;                      // WR_ISSU -> BVALID (ready=1)
    // inject new write attempt: must be silently ignored while BVALID pending
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= 24'h000008;
    s_axi_wvalid  <= 1'b1;
    s_axi_wdata   <= 32'hBEEF_1234;
    s_axi_wstrb   <= 4'b1111;
    // stall cycle 1
    check1(s_axi_bvalid,  1'b1, "P4:c1:bvalid");
    check2(s_axi_bresp,  2'b00, "P4:c1:bresp");
    check1(s_axi_awready, 1'b0, "P4:c1:awready");
    check1(s_axi_wready,  1'b0, "P4:c1:wready");
    @(posedge clk); #1;                      // stall cycle 2 (BVALID, bready=0)
    check1(s_axi_bvalid,  1'b1, "P4:c2:bvalid");
    check2(s_axi_bresp,  2'b00, "P4:c2:bresp");
    check1(s_axi_awready, 1'b0, "P4:c2:awready");
    check1(s_axi_wready,  1'b0, "P4:c2:wready");
    @(posedge clk); #1;                      // stall cycle 3 (BVALID, bready=0)
    check1(s_axi_bvalid,  1'b1, "P4:c3:bvalid");
    check2(s_axi_bresp,  2'b00, "P4:c3:bresp");
    check1(s_axi_awready, 1'b0, "P4:c3:awready");
    check1(s_axi_wready,  1'b0, "P4:c3:wready");
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    s_axi_bready  <= 1'b1;
    @(posedge clk); #1;                      // BVALID -> IDLE
    s_axi_bready <= 1'b0;

    // =====================================================================
    // P5: RREADY stall -- RVALID stable, new AR not accepted during stall
    // =====================================================================
    $display("-- P5: rready stall, RVALID stable, AR not accepted --");
    s_axi_arvalid <= 1'b1;
    s_axi_araddr  <= 24'h000000;
    @(posedge clk); #1;                      // IDLE -> RD_ISSU
    s_axi_arvalid <= 1'b0;
    @(posedge clk); #1;                      // RD_ISSU -> RD_WAIT (ready=1)
    native_rsp_valid <= 1'b1;
    native_rsp_rdata <= 32'h5A5A_A5A5;
    @(posedge clk); #1;                      // RD_WAIT -> RVALID, rdata latched
    native_rsp_valid <= 1'b0;
    // inject new read attempt: must be silently ignored while RVALID pending
    s_axi_arvalid <= 1'b1;
    s_axi_araddr  <= 24'h000004;
    // stall cycle 1
    check1(s_axi_rvalid,  1'b1, "P5:c1:rvalid");
    check2(s_axi_rresp,  2'b00, "P5:c1:rresp");
    check32(s_axi_rdata, 32'h5A5A_A5A5, "P5:c1:rdata");
    check1(s_axi_arready, 1'b0, "P5:c1:arready");
    @(posedge clk); #1;                      // stall cycle 2 (RVALID, rready=0)
    check1(s_axi_rvalid,  1'b1, "P5:c2:rvalid");
    check2(s_axi_rresp,  2'b00, "P5:c2:rresp");
    check32(s_axi_rdata, 32'h5A5A_A5A5, "P5:c2:rdata");
    check1(s_axi_arready, 1'b0, "P5:c2:arready");
    @(posedge clk); #1;                      // stall cycle 3 (RVALID, rready=0)
    check1(s_axi_rvalid,  1'b1, "P5:c3:rvalid");
    check2(s_axi_rresp,  2'b00, "P5:c3:rresp");
    check32(s_axi_rdata, 32'h5A5A_A5A5, "P5:c3:rdata");
    check1(s_axi_arready, 1'b0, "P5:c3:arready");
    s_axi_arvalid <= 1'b0;
    s_axi_rready  <= 1'b1;
    @(posedge clk); #1;                      // RVALID -> IDLE
    s_axi_rready <= 1'b0;

    // =====================================================================
    // E1: Unaligned write address -> SLVERR, native_req never issued (2 cy)
    // =====================================================================
    $display("-- E1: unaligned wr addr=0x02, SLVERR, no native_req --");
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= 24'h000002;             // addr[1:0]=10 -- unaligned
    s_axi_wvalid  <= 1'b1;
    s_axi_wdata   <= 32'hBAAD_F00D;
    s_axi_wstrb   <= 4'b1111;
    @(posedge clk); #1;                      // IDLE -> BVALID (guard, skip native)
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    // cycle 1 in BVALID (bready=0): native_req must not be issued
    check1(native_req_valid, 1'b0, "E1:c1:no_req");
    check1(s_axi_bvalid,     1'b1, "E1:c1:bvalid");
    check2(s_axi_bresp,     2'b10, "E1:c1:bresp");
    @(posedge clk); #1;                      // cycle 2 in BVALID (bready=0)
    check1(native_req_valid, 1'b0, "E1:c2:no_req");
    check1(s_axi_bvalid,     1'b1, "E1:c2:bvalid");
    check2(s_axi_bresp,     2'b10, "E1:c2:bresp");
    s_axi_bready <= 1'b1;
    @(posedge clk); #1;                      // BVALID -> IDLE
    s_axi_bready <= 1'b0;

    // =====================================================================
    // E2: Partial WSTRB -> SLVERR, native_req never issued (2 cy)
    // =====================================================================
    $display("-- E2: partial WSTRB=4'b0011, SLVERR, no native_req --");
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= 24'h000000;             // aligned
    s_axi_wvalid  <= 1'b1;
    s_axi_wdata   <= 32'h55AA_55AA;
    s_axi_wstrb   <= 4'b0011;               // partial
    @(posedge clk); #1;                      // IDLE -> BVALID (guard, skip native)
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;
    s_axi_wstrb   <= 4'b1111;               // restore default
    // cycle 1 in BVALID (bready=0): native_req must not be issued
    check1(native_req_valid, 1'b0, "E2:c1:no_req");
    check1(s_axi_bvalid,     1'b1, "E2:c1:bvalid");
    check2(s_axi_bresp,     2'b10, "E2:c1:bresp");
    @(posedge clk); #1;                      // cycle 2 in BVALID (bready=0)
    check1(native_req_valid, 1'b0, "E2:c2:no_req");
    check1(s_axi_bvalid,     1'b1, "E2:c2:bvalid");
    check2(s_axi_bresp,     2'b10, "E2:c2:bresp");
    s_axi_bready <= 1'b1;
    @(posedge clk); #1;                      // BVALID -> IDLE
    s_axi_bready <= 1'b0;

    // =====================================================================
    // E3: Unaligned read address -> SLVERR, RDATA=0, no native_req (2 cy)
    // =====================================================================
    $display("-- E3: unaligned rd addr=0x02, SLVERR, no native_req --");
    s_axi_arvalid <= 1'b1;
    s_axi_araddr  <= 24'h000002;             // addr[1:0]=10 -- unaligned
    @(posedge clk); #1;                      // IDLE -> RVALID (guard, skip native)
    s_axi_arvalid <= 1'b0;
    // cycle 1 in RVALID (rready=0): native_req must not be issued
    check1(native_req_valid, 1'b0, "E3:c1:no_req");
    check1(s_axi_rvalid,     1'b1, "E3:c1:rvalid");
    check2(s_axi_rresp,     2'b10, "E3:c1:rresp");
    check32(s_axi_rdata, 32'h0000_0000, "E3:c1:rdata");
    @(posedge clk); #1;                      // cycle 2 in RVALID (rready=0)
    check1(native_req_valid, 1'b0, "E3:c2:no_req");
    check1(s_axi_rvalid,     1'b1, "E3:c2:rvalid");
    check2(s_axi_rresp,     2'b10, "E3:c2:rresp");
    check32(s_axi_rdata, 32'h0000_0000, "E3:c2:rdata");
    s_axi_rready <= 1'b1;
    @(posedge clk); #1;                      // RVALID -> IDLE
    s_axi_rready <= 1'b0;

    // =====================================================================
    // Done
    // =====================================================================
    @(posedge clk); #1;
    $display("# ERRORS=%0d WARNINGS=0", errors);
    if (errors == 0) $display("# *** PASS ***");
    else             $display("# *** FAIL ***");
    $finish;
  end

endmodule
`endif // TB_AXI_NATIVE_ADAPTER_PROTOCOL_UNIT_SV
