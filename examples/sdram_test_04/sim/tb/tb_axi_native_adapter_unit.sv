// tb_axi_native_adapter_unit.sv -- AXI native adapter unit test.
// Fake native backend (native_req_ready=1 always, rsp_valid injected by TB).
// No SDRAM PHY. No SDRAM model. No native_word_port.
// Tests: 4 transactions -- write+read at AXI addr 0x00 and 0x04.
`timescale 1ns/1ps

module tb_axi_native_adapter_unit;

  localparam integer CLK_HALF = 4;

  logic clk  = 0;
  logic rstn = 0;

  always #CLK_HALF clk = ~clk;

  // -----------------------------------------------------------------------
  // AXI-lite interface
  // -----------------------------------------------------------------------
  logic [23:0] s_axi_awaddr  = '0;
  logic        s_axi_awvalid = 0;
  logic        s_axi_awready;

  logic [31:0] s_axi_wdata   = '0;
  logic [3:0]  s_axi_wstrb   = 4'b1111;
  logic        s_axi_wvalid  = 0;
  logic        s_axi_wready;

  logic [1:0]  s_axi_bresp;
  logic        s_axi_bvalid;
  logic        s_axi_bready  = 0;

  logic [23:0] s_axi_araddr  = '0;
  logic        s_axi_arvalid = 0;
  logic        s_axi_arready;

  logic [31:0] s_axi_rdata;
  logic [1:0]  s_axi_rresp;
  logic        s_axi_rvalid;
  logic        s_axi_rready  = 0;

  // -----------------------------------------------------------------------
  // Fake native backend
  // -----------------------------------------------------------------------
  logic        native_req_valid;
  logic        native_req_ready = 1;  // always ready
  logic        native_req_write;
  logic [23:0] native_req_addr;
  logic [31:0] native_req_wdata;

  logic        native_rsp_valid = 0;
  logic [31:0] native_rsp_rdata = '0;

  // -----------------------------------------------------------------------
  // DUT
  // -----------------------------------------------------------------------
  axi_native_adapter #(
    .AXI_ADDR_WIDTH   (24),
    .AXI_DATA_WIDTH   (32),
    .NATIVE_ADDR_WIDTH(24)
  ) u_dut (
    .clk            (clk),
    .rstn           (rstn),
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .s_axi_araddr   (s_axi_araddr),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),
    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .native_req_valid(native_req_valid),
    .native_req_ready(native_req_ready),
    .native_req_write(native_req_write),
    .native_req_addr (native_req_addr),
    .native_req_wdata(native_req_wdata),
    .native_rsp_valid(native_rsp_valid),
    .native_rsp_rdata(native_rsp_rdata)
  );

  // -----------------------------------------------------------------------
  // Counters and state
  // -----------------------------------------------------------------------
  integer cyc    = 0;
  integer errors = 0;
  always @(posedge clk) cyc++;

  // Captured native request values for SUMMARY
  logic [23:0] cap_wr0_addr,  cap_wr4_addr;
  logic [31:0] cap_wr0_wdata, cap_wr4_wdata;
  logic [31:0] cap_rd0_rdata, cap_rd4_rdata;

  // -----------------------------------------------------------------------
  task automatic check;
    input string  label;
    input logic   actual;
    input logic   expected;
    begin
      if (actual !== expected) begin
        $display("[FAIL] %s: got=%b expected=%b @ cyc=%0d", label, actual, expected, cyc);
        errors++;
      end else begin
        $display("[OK]   %s = %b @ cyc=%0d", label, actual, cyc);
      end
    end
  endtask

  task automatic check32;
    input string  label;
    input logic [31:0] actual;
    input logic [31:0] expected;
    begin
      if (actual !== expected) begin
        $display("[FAIL] %s: got=0x%08h expected=0x%08h @ cyc=%0d", label, actual, expected, cyc);
        errors++;
      end else begin
        $display("[OK]   %s = 0x%08h @ cyc=%0d", label, actual, cyc);
      end
    end
  endtask

  task automatic check24;
    input string  label;
    input logic [23:0] actual;
    input logic [23:0] expected;
    begin
      if (actual !== expected) begin
        $display("[FAIL] %s: got=0x%06h expected=0x%06h @ cyc=%0d", label, actual, expected, cyc);
        errors++;
      end else begin
        $display("[OK]   %s = 0x%06h @ cyc=%0d", label, actual, cyc);
      end
    end
  endtask

  // -----------------------------------------------------------------------
  // Test sequence
  // -----------------------------------------------------------------------
  initial begin
    $display("=== tb_axi_native_adapter_unit ===");
    $display("=== AXI-lite -> native_word_port adapter, fake native backend ===");

    rstn = 0;
    repeat(4) @(posedge clk); #1;
    rstn = 1;
    @(posedge clk); #1;

    // -------------------------------------------------------------------
    // Test 1: AXI write AWADDR=0x000000 WDATA=0x1234_A5C3 WSTRB=4'b1111
    // Expected native: native_req_valid=1, write=1, addr=0, wdata=0x1234_A5C3
    // Expected AXI: BVALID=1, BRESP=OKAY
    // -------------------------------------------------------------------
    $display("--- Test 1: AXI write addr=0x000000 wdata=0x1234_A5C3 ---");
    s_axi_awaddr  = 24'h000000;
    s_axi_wdata   = 32'h1234_A5C3;
    s_axi_wstrb   = 4'b1111;
    s_axi_awvalid = 1;
    s_axi_wvalid  = 1;
    @(posedge clk); #1;
    // Handshake for AW+W completed; adapter now in ST_WR_ISSU
    // native_req driven combinatorially from registered state
    s_axi_awvalid = 0;
    s_axi_wvalid  = 0;
    $display("[cyc=%0d] T1: native_req valid=%b write=%b addr=0x%06h wdata=0x%08h",
             cyc, native_req_valid, native_req_write, native_req_addr, native_req_wdata);
    check("T1 native_req_valid", native_req_valid, 1'b1);
    check("T1 native_req_write", native_req_write, 1'b1);
    check24("T1 native_req_addr", native_req_addr, 24'd0);
    check32("T1 native_req_wdata", native_req_wdata, 32'h1234_A5C3);
    cap_wr0_addr  = native_req_addr;
    cap_wr0_wdata = native_req_wdata;

    @(posedge clk); #1;
    // native handshake fired (native_req_ready=1); adapter now in ST_BVALID
    $display("[cyc=%0d] T1: BVALID=%b BRESP=%b", cyc, s_axi_bvalid, s_axi_bresp);
    check("T1 s_axi_bvalid", s_axi_bvalid, 1'b1);
    check("T1 s_axi_bresp[1]", s_axi_bresp[1], 1'b0);
    check("T1 s_axi_bresp[0]", s_axi_bresp[0], 1'b0);
    s_axi_bready = 1;
    @(posedge clk); #1;
    // BVALID handshake; adapter back to ST_IDLE
    s_axi_bready = 0;
    $display("[cyc=%0d] T1: DONE", cyc);

    repeat(1) @(posedge clk); #1;

    // -------------------------------------------------------------------
    // Test 2: AXI read ARADDR=0x000000
    // Expected native: native_req_valid=1, write=0, addr=0
    // Inject: native_rsp_valid=1, native_rsp_rdata=0x1234_A5C3
    // Expected AXI: RVALID=1, RRESP=OKAY, RDATA=0x1234_A5C3
    // -------------------------------------------------------------------
    $display("--- Test 2: AXI read  addr=0x000000 expect=0x1234_A5C3 ---");
    s_axi_araddr  = 24'h000000;
    s_axi_arvalid = 1;
    @(posedge clk); #1;
    // AR handshake; adapter in ST_RD_ISSU
    s_axi_arvalid = 0;
    $display("[cyc=%0d] T2: native_req valid=%b write=%b addr=0x%06h",
             cyc, native_req_valid, native_req_write, native_req_addr);
    check("T2 native_req_valid", native_req_valid, 1'b1);
    check("T2 native_req_write", native_req_write, 1'b0);
    check24("T2 native_req_addr", native_req_addr, 24'd0);

    @(posedge clk); #1;
    // native handshake fired; adapter in ST_RD_WAIT
    // Inject native response
    native_rsp_valid = 1;
    native_rsp_rdata = 32'h1234_A5C3;
    @(posedge clk); #1;
    // Adapter latched rdata; now in ST_RVALID
    native_rsp_valid = 0;
    $display("[cyc=%0d] T2: RVALID=%b RRESP=%b RDATA=0x%08h",
             cyc, s_axi_rvalid, s_axi_rresp, s_axi_rdata);
    check("T2 s_axi_rvalid", s_axi_rvalid, 1'b1);
    check("T2 s_axi_rresp[1]", s_axi_rresp[1], 1'b0);
    check("T2 s_axi_rresp[0]", s_axi_rresp[0], 1'b0);
    check32("T2 s_axi_rdata", s_axi_rdata, 32'h1234_A5C3);
    cap_rd0_rdata = s_axi_rdata;
    s_axi_rready = 1;
    @(posedge clk); #1;
    s_axi_rready = 0;
    $display("[cyc=%0d] T2: DONE", cyc);

    repeat(1) @(posedge clk); #1;

    // -------------------------------------------------------------------
    // Test 3: AXI write AWADDR=0x000004 WDATA=0xDEAD_BEEF WSTRB=4'b1111
    // Expected native: native_req_valid=1, write=1, addr=2, wdata=0xDEAD_BEEF
    // Expected AXI: BVALID=1, BRESP=OKAY
    // -------------------------------------------------------------------
    $display("--- Test 3: AXI write addr=0x000004 wdata=0xDEAD_BEEF ---");
    s_axi_awaddr  = 24'h000004;
    s_axi_wdata   = 32'hDEAD_BEEF;
    s_axi_wstrb   = 4'b1111;
    s_axi_awvalid = 1;
    s_axi_wvalid  = 1;
    @(posedge clk); #1;
    s_axi_awvalid = 0;
    s_axi_wvalid  = 0;
    $display("[cyc=%0d] T3: native_req valid=%b write=%b addr=0x%06h wdata=0x%08h",
             cyc, native_req_valid, native_req_write, native_req_addr, native_req_wdata);
    check("T3 native_req_valid", native_req_valid, 1'b1);
    check("T3 native_req_write", native_req_write, 1'b1);
    check24("T3 native_req_addr",  native_req_addr,  24'd2);
    check32("T3 native_req_wdata", native_req_wdata, 32'hDEAD_BEEF);
    cap_wr4_addr  = native_req_addr;
    cap_wr4_wdata = native_req_wdata;

    @(posedge clk); #1;
    $display("[cyc=%0d] T3: BVALID=%b BRESP=%b", cyc, s_axi_bvalid, s_axi_bresp);
    check("T3 s_axi_bvalid", s_axi_bvalid, 1'b1);
    check("T3 s_axi_bresp[1]", s_axi_bresp[1], 1'b0);
    check("T3 s_axi_bresp[0]", s_axi_bresp[0], 1'b0);
    s_axi_bready = 1;
    @(posedge clk); #1;
    s_axi_bready = 0;
    $display("[cyc=%0d] T3: DONE", cyc);

    repeat(1) @(posedge clk); #1;

    // -------------------------------------------------------------------
    // Test 4: AXI read ARADDR=0x000004
    // Inject: native_rsp_rdata=0xDEAD_BEEF
    // Expected AXI: RVALID=1, RRESP=OKAY, RDATA=0xDEAD_BEEF
    // -------------------------------------------------------------------
    $display("--- Test 4: AXI read  addr=0x000004 expect=0xDEAD_BEEF ---");
    s_axi_araddr  = 24'h000004;
    s_axi_arvalid = 1;
    @(posedge clk); #1;
    s_axi_arvalid = 0;
    $display("[cyc=%0d] T4: native_req valid=%b write=%b addr=0x%06h",
             cyc, native_req_valid, native_req_write, native_req_addr);
    check("T4 native_req_valid", native_req_valid, 1'b1);
    check("T4 native_req_write", native_req_write, 1'b0);
    check24("T4 native_req_addr", native_req_addr, 24'd2);

    @(posedge clk); #1;
    native_rsp_valid = 1;
    native_rsp_rdata = 32'hDEAD_BEEF;
    @(posedge clk); #1;
    native_rsp_valid = 0;
    $display("[cyc=%0d] T4: RVALID=%b RRESP=%b RDATA=0x%08h",
             cyc, s_axi_rvalid, s_axi_rresp, s_axi_rdata);
    check("T4 s_axi_rvalid", s_axi_rvalid, 1'b1);
    check("T4 s_axi_rresp[1]", s_axi_rresp[1], 1'b0);
    check("T4 s_axi_rresp[0]", s_axi_rresp[0], 1'b0);
    check32("T4 s_axi_rdata", s_axi_rdata, 32'hDEAD_BEEF);
    cap_rd4_rdata = s_axi_rdata;
    s_axi_rready = 1;
    @(posedge clk); #1;
    s_axi_rready = 0;
    $display("[cyc=%0d] T4: DONE", cyc);

    repeat(2) @(posedge clk);

    // -------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------
    $display("-------------------------------------------");
    $display("SUMMARY:");
    $display("  write_addr0_native_addr  = 0x%06h (expected 0x000000)", cap_wr0_addr);
    $display("  write_addr0_native_wdata = 0x%08h (expected 0x1234a5c3)", cap_wr0_wdata);
    $display("  read_addr0_rdata         = 0x%08h (expected 0x1234a5c3)", cap_rd0_rdata);
    $display("  write_addr4_native_addr  = 0x%06h (expected 0x000002)", cap_wr4_addr);
    $display("  write_addr4_native_wdata = 0x%08h (expected 0xdeadbeef)", cap_wr4_wdata);
    $display("  read_addr4_rdata         = 0x%08h (expected 0xdeadbeef)", cap_rd4_rdata);
    $display("-------------------------------------------");
    $display("  errors=%0d", errors);

    if (errors == 0) begin
      $display("==============================================");
      $display("  *** PASS *** (errors=%0d)", errors);
      $display("==============================================");
    end else begin
      $display("==============================================");
      $display("  *** FAIL *** (errors=%0d)", errors);
      $display("==============================================");
    end
    $finish;
  end

endmodule
