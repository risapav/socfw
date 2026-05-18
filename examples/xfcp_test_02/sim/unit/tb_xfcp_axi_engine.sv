`timescale 1ns/1ps

// Testbench for xfcp_axi_engine (standalone, no UART).
//
// AXI-Lite slave: axil_slave_model (MEM_DEPTH=64).
// Input: req_hdr + write_data directly (no parser).
// LITTLE_ENDIAN=0: data MSB-first, no byte-swap.
//
// Tests:
//   T1: WRITE single word (count=4) -> verify AW/W/B handshake
//   T2: READ single word (count=4)  -> verify AR/R handshake + rdata
//   T3: WRITE then READ back        -> data integrity
//   T4: Multi-word WRITE (count=8)  -> two AXI transactions, addr++
//   T5: Multi-word READ  (count=8)  -> two AXI transactions
//   T6: AXI slave backpressure: delay AWREADY/WREADY/BVALID
//   T7: AXI slave backpressure: delay ARREADY/RVALID
//   T8: Write FIFO backpressure (hold write_data_valid=0 briefly)
//   T9: Watchdog timeout (slave does not respond -> error_timeout)
//
// TODO: implement all tests
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) $(XFCP_COMMON) \
//        $(RTL_AXIL)/axil_slave_model.sv unit/tb_xfcp_axi_engine.sv
//   vsim -c -do "run -all; quit" tb_xfcp_axi_engine

module tb_xfcp_axi_engine;
  import axi_pkg::*;
  import xfcp_pkg::*;

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ── Interfaces ───────────────────────────────────────────────────
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil (.ACLK(clk), .ARESETn(rst_n));

  // ── DUT signals ──────────────────────────────────────────────────
  logic [55:0]  req_hdr;
  logic         req_valid;
  logic         req_ready;
  logic [31:0]  write_data;
  logic         write_data_valid;
  logic         write_data_ready;
  logic [31:0]  read_data;
  logic         read_data_valid;
  logic         read_data_ready;
  logic         resp_start;
  logic [7:0]   resp_type;
  logic         resp_done;
  logic         error_timeout;

  // Packetizer idle stub (always idle for standalone test)
  logic packetizer_idle_i = 1'b1;

  // ── DUT ──────────────────────────────────────────────────────────
  xfcp_axi_engine #(
    .LITTLE_ENDIAN  (1'b0),
    .AXI_ADDR_WIDTH (32),
    .AXI_DATA_WIDTH (32),
    .TIMEOUT_VAL    (200)
  ) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .m_axil           (axil.master),
    .req_hdr          (req_hdr),
    .req_valid        (req_valid),
    .req_ready        (req_ready),
    .write_data       (write_data),
    .write_data_valid (write_data_valid),
    .write_data_ready (write_data_ready),
    .read_data        (read_data),
    .read_data_valid  (read_data_valid),
    .read_data_ready  (read_data_ready),
    .resp_start       (resp_start),
    .resp_type        (resp_type),
    .resp_done        (resp_done),
    .packetizer_idle_i(packetizer_idle_i),
    .error_timeout    (error_timeout)
  );

  // ── AXI memory slave ─────────────────────────────────────────────
  axil_slave_model #(.MEM_DEPTH(64)) u_slave (
    .clk   (clk),
    .rstn  (rst_n),
    .s_axil(axil.slave)
  );

  // ── Tasks ─────────────────────────────────────────────────────────

  task automatic do_reset();
    rst_n            = 1'b0;
    req_valid        = 1'b0;
    write_data_valid = 1'b0;
    read_data_ready  = 1'b0;
    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  // Build req_hdr from opcode/addr/count (56-bit packed: [55:48]=op [47:16]=addr [15:0]=count)
  function automatic logic [55:0] make_hdr(
    input logic [7:0]  op,
    input logic [31:0] addr,
    input logic [15:0] count
  );
    return {op, addr, count};
  endfunction

  // Submit a single-word WRITE request and wait for resp_done.
  // Two-phase design: push exactly one word into wfifo BEFORE asserting
  // req_valid. If write_data_valid is held across the req_ready while-loop,
  // each iteration writes another copy (w_ready=1 always when FIFO not full,
  // but wfifo_valid=0 for 1 cycle after write due to sequential count_q).
  // That leaves leftover words which corrupt the next WRITE transaction.
  task automatic do_write(input logic [31:0] addr, input logic [31:0] data);
    // Phase 1: push exactly one word into wfifo
    @(negedge clk);
    write_data       = data;
    write_data_valid = 1'b1;
    @(posedge clk);   // sequential FIFO write fires (count 0→1)
    @(negedge clk);
    write_data_valid = 1'b0;
    // Phase 2: req handshake — wfifo_valid=1 at next posedge
    req_hdr   = make_hdr(8'(XFCP_OP_WRITE), addr, 16'h4);
    req_valid = 1'b1;
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    // Wait for resp_done (fires in ST_NEXT after AW/W/B handshakes)
    @(posedge clk);
    begin : wait_done
      int t;
      t = 0;
      while (!resp_done) begin
        @(posedge clk);
        if (++t > 1000) $fatal(1, "do_write: resp_done timeout");
      end
    end
    repeat(2) @(posedge clk);
  endtask

  // Submit a single-word READ request and return rdata.
  // read_data_valid and resp_done both fire in ST_NEXT (same 1-cycle window).
  // Checking resp_done separately after deassert of read_data_ready misses the
  // pulse (engine already in ST_DONE). Verify resp_done at the same posedge.
  task automatic do_read(input logic [31:0] addr, output logic [31:0] rdata);
    @(negedge clk);
    req_hdr         = make_hdr(8'(XFCP_OP_READ), addr, 16'h4);
    req_valid       = 1'b1;
    read_data_ready = 1'b1;
    @(posedge clk);
    while (!req_ready) @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    // read_data_valid fires in ST_NEXT, resp_done is combinatorial from same state.
    // Capture both at the same posedge to avoid missing the 1-cycle resp_done pulse.
    @(posedge clk);
    begin : wait_rdata
      int t;
      t = 0;
      while (!read_data_valid) begin
        @(posedge clk);
        if (++t > 1000) $fatal(1, "do_read: read_data_valid timeout");
      end
    end
    rdata = read_data;
    if (!resp_done)
      $display("WARNING do_read: resp_done not seen at read_data_valid posedge");
    @(negedge clk);
    read_data_ready = 1'b0;
    repeat(2) @(posedge clk);
  endtask

  task automatic chk32(input logic [31:0] got, input logic [31:0] exp, input string lbl);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08X exp=0x%08X", lbl, got, exp);
      fails++;
    end else $display("PASS %s: 0x%08X", lbl, got);
  endtask

  // ── Stimulus ──────────────────────────────────────────────────────
  logic [31:0] rdata;

  initial begin
    do_reset();

    // T1: WRITE single word
    do_write(32'h00000004, 32'hDEAD_BEEF);
    $display("PASS T1 WRITE single word");

    // T2: READ single word (verify T1 data)
    do_read(32'h00000004, rdata);
    chk32(rdata, 32'hDEAD_BEEF, "T2 READ after WRITE");

    // T3: WRITE + READ back (different address)
    do_write(32'h00000008, 32'hCAFE_BABE);
    do_read(32'h00000008, rdata);
    chk32(rdata, 32'hCAFE_BABE, "T3 WRITE+READ back");

    // T4-T9: TODO — multi-word, backpressure, timeout

    $display("");
    $display("NOTE: T4-T9 not yet implemented — stub testbench");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
