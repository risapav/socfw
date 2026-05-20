`timescale 1ns/1ps

// Testbench for xfcp_rx_parser.
//
// XFCP request bytes injected directly via AXI-Stream (no UART).
// Protocol: SOP=0xFE, READ=0x10, WRITE=0x11.
// Header: [SOP][OPCODE][COUNT_HI][COUNT_LO][ADDR 4B BE]
// req_hdr (56-bit packed xfcp_req_hdr_t): [55:48]=opcode [47:16]=addr [15:0]=count
//
// Tests:
//   T1: READ  FE 10 00 04 FF 02 00 04 -> opcode=0x10 addr=0xFF020004 count=4
//   T2: WRITE FE 11 00 04 FF 02 00 04 00 00 00 3F -> req_hdr + wdata=0x0000003F
//   T3: Bad opcode 0x99 -> error_protocol asserted
//   T4: COUNT=3 (not multiple of 4) -> error_protocol asserted
//   T5: TLAST mid-header -> error_protocol asserted
//   T6: Back-to-back READ packets -> two req_hdr entries queued in FIFO
//   T7: WRITE with backpressure on write_data_ready -> data preserved in FIFO
//   T8: 0xFF (RPATH SOP) in S_IDLE with pass_ready=0 -> ignored, next READ works
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) $(XFCP_PARSER) tb_xfcp_rx_parser.sv
//   vsim -c -do "run -all; quit" tb_xfcp_rx_parser

module tb_xfcp_rx_parser;
  import axi_pkg::*;
  import xfcp_pkg::*;

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ── DUT signals ──────────────────────────────────────────────────
  logic [7:0]  s_tdata;
  logic        s_tvalid;
  logic        s_tready;
  logic        s_tlast;

  logic [55:0] req_hdr;
  logic        req_valid;
  logic        req_ready;

  logic [31:0] write_data;
  logic        write_data_valid;
  logic        write_data_ready;

  logic        error_protocol;

  // ── DUT ──────────────────────────────────────────────────────────
  xfcp_rx_parser #(
    .AXI_ADDR_WIDTH(32),
    .AXI_DATA_WIDTH(32),
    .FIFO_DEPTH    (8)
  ) dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .s_axis_tdata    (s_tdata),
    .s_axis_tvalid   (s_tvalid),
    .s_axis_tready   (s_tready),
    .s_axis_tlast    (s_tlast),
    .req_hdr         (req_hdr),
    .req_valid       (req_valid),
    .req_ready       (req_ready),
    .write_data      (write_data),
    .write_data_valid(write_data_valid),
    .write_data_ready(write_data_ready),
    .pass_valid      (),
    .pass_data       (),
    .pass_last       (),
    .pass_ready      (1'b0),
    .error_protocol  (error_protocol)
  );

  // ── Tasks ─────────────────────────────────────────────────────────

  // Send one AXIS byte; waits for tready (handles S_DECODE stall cycle)
  task automatic axis_byte(input logic [7:0] b, input logic last = 1'b0);
    @(negedge clk);
    s_tdata  = b;
    s_tvalid = 1'b1;
    s_tlast  = last;
    @(posedge clk);
    while (!s_tready) @(posedge clk);
    @(negedge clk);
    s_tvalid = 1'b0;
    s_tlast  = 1'b0;
  endtask

  // Wait for req_valid; check opcode/addr/count; ack with one-cycle req_ready
  task automatic expect_req(
    input logic [7:0]  exp_op,
    input logic [31:0] exp_addr,
    input logic [15:0] exp_cnt,
    input string       lbl
  );
    xfcp_req_hdr_t h;
    int timeout;
    timeout = 0;
    req_ready = 1'b1;
    @(posedge clk);
    while (!req_valid) begin
      @(posedge clk);
      if (++timeout > 500) $fatal(1, "%s: req_valid timeout", lbl);
    end
    h = xfcp_req_hdr_t'(req_hdr);
    if (8'(h.opcode) !== exp_op) begin
      $display("FAIL %s opcode: got=0x%02X exp=0x%02X", lbl, 8'(h.opcode), exp_op);
      fails++;
    end else $display("PASS %s opcode=0x%02X", lbl, exp_op);
    if (h.addr !== exp_addr) begin
      $display("FAIL %s addr: got=0x%08X exp=0x%08X", lbl, h.addr, exp_addr);
      fails++;
    end else $display("PASS %s addr=0x%08X", lbl, exp_addr);
    if (h.count !== exp_cnt) begin
      $display("FAIL %s count: got=%0d exp=%0d", lbl, h.count, exp_cnt);
      fails++;
    end else $display("PASS %s count=%0d", lbl, exp_cnt);
    req_ready = 1'b0;
    @(posedge clk);
  endtask

  // Wait for write_data_valid; check value; ack
  task automatic expect_wdata(input logic [31:0] exp, input string lbl);
    int timeout;
    timeout = 0;
    write_data_ready = 1'b1;
    @(posedge clk);
    while (!write_data_valid) begin
      @(posedge clk);
      if (++timeout > 500) $fatal(1, "%s: write_data_valid timeout", lbl);
    end
    if (write_data !== exp) begin
      $display("FAIL %s: got=0x%08X exp=0x%08X", lbl, write_data, exp);
      fails++;
    end else $display("PASS %s: 0x%08X", lbl, exp);
    write_data_ready = 1'b0;
    @(posedge clk);
  endtask

  // Wait for error_protocol to be asserted
  task automatic expect_error(input string lbl);
    int timeout;
    timeout = 0;
    @(posedge clk);
    while (!error_protocol) begin
      @(posedge clk);
      if (++timeout > 100) $fatal(1, "%s: error_protocol timeout", lbl);
    end
    $display("PASS %s: error_protocol asserted", lbl);
  endtask

  task automatic do_reset();
    rst_n = 1'b0;
    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  // ── Stimulus ──────────────────────────────────────────────────────
  initial begin
    s_tdata          = 8'h00;
    s_tvalid         = 1'b0;
    s_tlast          = 1'b0;
    req_ready        = 1'b0;
    write_data_ready = 1'b0;

    do_reset();

    // ── T1: READ FE 10 00 04 FF 02 00 04 ────────────────────────────
    axis_byte(8'hFE); axis_byte(8'h10);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'hFF); axis_byte(8'h02);
    axis_byte(8'h00); axis_byte(8'h04);
    expect_req(8'h10, 32'hFF020004, 16'h4, "T1 READ");
    repeat(2) @(posedge clk);

    // ── T2: WRITE FE 11 00 04 FF 02 00 04 | 00 00 00 3F ─────────────
    axis_byte(8'hFE); axis_byte(8'h11);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'hFF); axis_byte(8'h02);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'h00); axis_byte(8'h00);
    axis_byte(8'h00); axis_byte(8'h3F);
    expect_req  (8'h11, 32'hFF020004, 16'h4, "T2 WRITE hdr");
    expect_wdata(32'h0000003F, "T2 WRITE data");
    repeat(2) @(posedge clk);

    // ── T3: Bad opcode 0x99 -> error_protocol ───────────────────────
    axis_byte(8'hFE); axis_byte(8'h99);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'h00); axis_byte(8'h00);
    axis_byte(8'h00); axis_byte(8'h00, 1'b1);
    expect_error("T3 bad opcode");
    do_reset();

    // ── T4: COUNT=3 (not multiple of 4) -> error_protocol ───────────
    axis_byte(8'hFE); axis_byte(8'h10);
    axis_byte(8'h00); axis_byte(8'h03);
    axis_byte(8'h00); axis_byte(8'h00);
    axis_byte(8'h00); axis_byte(8'h00, 1'b1);
    expect_error("T4 COUNT not multiple of 4");
    do_reset();

    // ── T5: TLAST mid-header -> error_protocol ───────────────────────
    axis_byte(8'hFE); axis_byte(8'h10);
    axis_byte(8'h00, 1'b1);
    expect_error("T5 TLAST mid-header");
    do_reset();

    // ── T6: Back-to-back READ packets ───────────────────────────────
    req_ready = 1'b0;
    axis_byte(8'hFE); axis_byte(8'h10);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'hFF); axis_byte(8'h00);
    axis_byte(8'h00); axis_byte(8'h00);
    axis_byte(8'hFE); axis_byte(8'h10);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'hFF); axis_byte(8'h01);
    axis_byte(8'h00); axis_byte(8'h00);
    expect_req(8'h10, 32'hFF000000, 16'h4, "T6 pkt-A");
    expect_req(8'h10, 32'hFF010000, 16'h4, "T6 pkt-B");
    repeat(2) @(posedge clk);

    // ── T7: WRITE with backpressure on write_data_ready ─────────────
    write_data_ready = 1'b0;
    axis_byte(8'hFE); axis_byte(8'h11);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'hFF); axis_byte(8'h05);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'hDE); axis_byte(8'hAD);
    axis_byte(8'hBE); axis_byte(8'hEF);
    expect_req  (8'h11, 32'hFF050004, 16'h4, "T7 WRITE hdr");
    repeat(20) @(posedge clk);
    expect_wdata(32'hDEADBEEF, "T7 WRITE data backpressure");

    // ── T8: 0xFF in S_IDLE with pass_ready=0 → ignored, next READ OK ─
    // Bug: before fix, parser entered S_RPATH and deadlocked (TLAST=0,
    // pass_ready=0 → no exit, no watchdog, no SOP recovery).
    // Fix: only enter S_RPATH when pass_ready=1.
    // Verify: send 0xFF in IDLE, then valid READ, expect correct req_hdr.
    axis_byte(8'hFF);             // stray RPATH SOP — must be ignored
    repeat(4) @(posedge clk);    // wait a few cycles
    axis_byte(8'hFE); axis_byte(8'h10);
    axis_byte(8'h00); axis_byte(8'h04);
    axis_byte(8'hFF); axis_byte(8'h03);
    axis_byte(8'h00); axis_byte(8'h08);
    expect_req(8'h10, 32'hFF030008, 16'h4, "T8 READ after stray 0xFF");
    repeat(2) @(posedge clk);

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
