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
  logic [$bits(xfcp_req_hdr_t)-1:0] req_hdr;
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

  // Build req_hdr from opcode/addr/count (64-bit: [63:56]=op [55:48]=seq [47:16]=addr [15:0]=count)
  function automatic logic [$bits(xfcp_req_hdr_t)-1:0] make_hdr(
    input logic [7:0]  op,
    input logic [31:0] addr,
    input logic [15:0] count
  );
    return {op, 8'h00, addr, count};  // seq=0 for testbench
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

    // ── T4: Multi-word WRITE (count=8, two AXI transactions) ──────────
    begin : T4
      // Pre-load both words into wfifo before req handshake
      @(negedge clk); write_data = 32'hAAAA_1111; write_data_valid = 1'b1;
      @(posedge clk); @(negedge clk); write_data_valid = 1'b0;
      @(negedge clk); write_data = 32'hBBBB_2222; write_data_valid = 1'b1;
      @(posedge clk); @(negedge clk); write_data_valid = 1'b0;
      req_hdr   = make_hdr(8'(XFCP_OP_WRITE), 32'h00000010, 16'h8);
      req_valid = 1'b1;
      @(posedge clk); while (!req_ready) @(posedge clk);
      @(negedge clk); req_valid = 1'b0;
      begin : t4_wait
        int t; t = 0;
        forever begin
          @(posedge clk);
          if (resp_done) break;
          if (++t > 2000) $fatal(1, "T4: resp_done timeout");
        end
      end
      $display("PASS T4 multi-word WRITE (2 words)");
      repeat(2) @(posedge clk);
    end

    // ── T5: Multi-word READ (count=8) — read back T4 data ────────────
    begin : T5
      logic [31:0] t5_words[2];
      int          t5_ptr, t5_t;
      t5_ptr = 0; t5_t = 0;
      @(negedge clk);
      req_hdr         = make_hdr(8'(XFCP_OP_READ), 32'h00000010, 16'h8);
      req_valid       = 1'b1;
      read_data_ready = 1'b1;
      @(posedge clk); while (!req_ready) @(posedge clk);
      @(negedge clk); req_valid = 1'b0;
      forever begin
        @(posedge clk);
        if (read_data_valid && t5_ptr < 2) begin
          t5_words[t5_ptr] = read_data;
          t5_ptr++;
        end
        if (resp_done) break;
        if (++t5_t > 2000) $fatal(1, "T5: resp_done timeout");
      end
      @(negedge clk); read_data_ready = 1'b0;
      chk32(t5_words[0], 32'hAAAA_1111, "T5 word0");
      chk32(t5_words[1], 32'hBBBB_2222, "T5 word1");
      repeat(2) @(posedge clk);
    end

    // ── T6: WRITE with AWREADY backpressure (10 cycles) ───────────────
    begin : T6
      // Force AWREADY low so engine stalls in ST_WR_ADDR
      force axil.AWREADY = 1'b0;
      @(negedge clk); write_data = 32'hC0FF_EE01; write_data_valid = 1'b1;
      @(posedge clk); @(negedge clk); write_data_valid = 1'b0;
      req_hdr   = make_hdr(8'(XFCP_OP_WRITE), 32'h00000020, 16'h4);
      req_valid = 1'b1;
      @(posedge clk); while (!req_ready) @(posedge clk);
      @(negedge clk); req_valid = 1'b0;
      repeat(10) @(posedge clk);
      release axil.AWREADY;
      begin : t6_wait
        int t; t = 0;
        forever begin
          @(posedge clk);
          if (resp_done) break;
          if (++t > 1000) $fatal(1, "T6: resp_done timeout after AWREADY release");
        end
      end
      $display("PASS T6 WRITE AWREADY backpressure");
      repeat(2) @(posedge clk);
    end

    // ── T7: READ with ARREADY backpressure — verify T6 data ──────────
    begin : T7
      // Force ARREADY low so engine stalls in ST_RD_ADDR
      force axil.ARREADY = 1'b0;
      @(negedge clk);
      req_hdr         = make_hdr(8'(XFCP_OP_READ), 32'h00000020, 16'h4);
      req_valid       = 1'b1;
      read_data_ready = 1'b1;
      @(posedge clk); while (!req_ready) @(posedge clk);
      @(negedge clk); req_valid = 1'b0;
      repeat(10) @(posedge clk);
      release axil.ARREADY;
      begin : t7_wait
        int t; t = 0;
        forever begin
          @(posedge clk);
          if (read_data_valid) rdata = read_data;
          if (resp_done) break;
          if (++t > 1000) $fatal(1, "T7: resp_done timeout after ARREADY release");
        end
      end
      @(negedge clk); read_data_ready = 1'b0;
      chk32(rdata, 32'hC0FF_EE01, "T7 READ after ARREADY backpressure");
      repeat(2) @(posedge clk);
    end

    // ── T8: WFIFO backpressure — delay second write word by 10 cycles ─
    begin : T8
      // Pre-load word0 only; word1 arrives after 10 cycles
      @(negedge clk); write_data = 32'hDEAD_0001; write_data_valid = 1'b1;
      @(posedge clk); @(negedge clk); write_data_valid = 1'b0;
      req_hdr   = make_hdr(8'(XFCP_OP_WRITE), 32'h00000030, 16'h8);
      req_valid = 1'b1;
      @(posedge clk); while (!req_ready) @(posedge clk);
      @(negedge clk); req_valid = 1'b0;
      repeat(10) @(posedge clk);   // engine stalls in ST_WR_DATA awaiting word1
      @(negedge clk); write_data = 32'hDEAD_0002; write_data_valid = 1'b1;
      @(posedge clk); @(negedge clk); write_data_valid = 1'b0;
      begin : t8_wait
        int t; t = 0;
        forever begin
          @(posedge clk);
          if (resp_done) break;
          if (++t > 2000) $fatal(1, "T8: resp_done timeout");
        end
      end
      $display("PASS T8 WFIFO backpressure (delayed word1)");
      repeat(2) @(posedge clk);
    end
    do_read(32'h00000030, rdata); chk32(rdata, 32'hDEAD_0001, "T8 word0 verify");
    do_read(32'h00000034, rdata); chk32(rdata, 32'hDEAD_0002, "T8 word1 verify");

    // ── T9: Watchdog timeout (ARREADY stuck → error_timeout → recovery) ──
    begin : T9
      // Force ARREADY=0: engine stuck in ST_RD_ADDR, watchdog counts to TIMEOUT_VAL
      force axil.ARREADY = 1'b0;
      @(negedge clk);
      req_hdr         = make_hdr(8'(XFCP_OP_READ), 32'h00000038, 16'h4);
      req_valid       = 1'b1;
      read_data_ready = 1'b0;
      @(posedge clk); while (!req_ready) @(posedge clk);
      @(negedge clk); req_valid = 1'b0;
      begin : t9_tout
        int t; t = 0;
        while (!error_timeout) begin
          @(posedge clk);
          if (++t > 500) $fatal(1, "T9: error_timeout never fired (TIMEOUT_VAL=200)");
        end
      end
      release axil.ARREADY;
      repeat(5) @(posedge clk);    // ST_DONE -> ST_IDLE, error_timeout clears
      do_read(32'h00000008, rdata);
      chk32(rdata, 32'hCAFE_BABE, "T9 recovery READ after timeout");
      if (error_timeout)
        $display("FAIL T9: error_timeout still set after recovery");
      else
        $display("PASS T9 watchdog timeout + recovery");
      repeat(2) @(posedge clk);
    end

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
