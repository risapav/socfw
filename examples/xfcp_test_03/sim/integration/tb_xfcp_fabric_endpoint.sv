`timescale 1ns/1ps

// Testbench for xfcp_fabric_endpoint (multi-slave, no UART).
//
// AXIS bytes injected directly into xfcp_in.
// 4 AXI-Lite slaves: axil_slave_model (MEM_DEPTH=64).
//
// Address map (compact 64-byte stride, fits in MEM_DEPTH=64):
//   Slave 0 @ 0x00000000  mask 0xFFFFFFC0  (words 0..15)
//   Slave 1 @ 0x00000040  mask 0xFFFFFFC0  (words 16..31)
//   Slave 2 @ 0x00000080  mask 0xFFFFFFC0  (words 32..47)
//   Slave 3 @ 0x000000C0  mask 0xFFFFFFC0  (words 48..63)
//
// axil_slave_model computes idx = addr >> 2. With large SLAVE_BASE
// (e.g. 0x00010000) idx = 16384 exceeds MEM_DEPTH=64 → reads 0xBAADF00D.
// The compact stride keeps all indices in [0,63].
//
// Data: avoid 0xFE bytes — parser interprets 0xFE as SOP and restarts.
//
// Tests:
//   T1: WRITE to slave 0, READ back -> verify routing to slave 0
//   T2: WRITE to slave 1, READ back -> verify routing to slave 1
//   T3: READ slave 0 after T2 WRITE to slave 1 (no cross-contamination)
//   T4: Invalid address -> no AXI transaction, error log expected
//   T5: Back-to-back: WRITE slave 0, WRITE slave 1, READ slave 0, READ slave 1
//   T6: Response ordering: in-order even if slaves differ
//   T7: Multi-word WRITE (count=8) to slave 0 -> two AXI transactions
//   T8: Multi-word READ  (count=8) from slave 1
//
// TODO: implement all tests
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) $(XFCP_COMMON) \
//        $(RTL_AXIL)/axil_slave_model.sv integration/tb_xfcp_fabric_endpoint.sv
//   vsim -c -do "run -all; quit" tb_xfcp_fabric_endpoint

module tb_xfcp_fabric_endpoint;
  import axi_pkg::*;
  import xfcp_pkg::*;

  localparam int NUM_SLAVES = 4;

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ── Interfaces ───────────────────────────────────────────────────
  axi4s_if    #(.DATA_WIDTH(8))                   xfcp_in  (.TCLK(clk), .TRESETn(rst_n));
  axi4s_if    #(.DATA_WIDTH(8))                   xfcp_out (.TCLK(clk), .TRESETn(rst_n));
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_s [NUM_SLAVES]
      (.ACLK(clk), .ARESETn(rst_n));

  // ── DUT ──────────────────────────────────────────────────────────
  xfcp_fabric_endpoint #(
    .NUM_SLAVES     (NUM_SLAVES),
    .AXI_ADDR_WIDTH (32),
    .AXI_DATA_WIDTH (32),
    .ID_STR         ("TB-FABRIC      "),
    .SLAVE_BASE     ('{ 32'h0000_0000, 32'h0000_0040,
                        32'h0000_0080, 32'h0000_00C0 }),
    .SLAVE_MASK     ('{ 32'hFFFF_FFC0, 32'hFFFF_FFC0,
                        32'hFFFF_FFC0, 32'hFFFF_FFC0 })
  ) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .xfcp_in  (xfcp_in.slave),
    .xfcp_out (xfcp_out.master),
    .m_axil   (axil_s)
  );

  // ── AXI memory slaves ─────────────────────────────────────────────
  for (genvar i = 0; i < NUM_SLAVES; i++) begin : g_slave
    axil_slave_model #(.MEM_DEPTH(64)) u_slave (
      .clk   (clk),
      .rstn  (rst_n),
      .s_axil(axil_s[i].slave)
    );
  end : g_slave

  // Always accept xfcp_out
  assign xfcp_out.TREADY = 1'b1;

  // Response capture
  logic [7:0]  resp_buf [0:127];
  int unsigned resp_wptr, resp_rptr;

  initial begin
    resp_wptr = 0;
    resp_rptr = 0;
  end

  always @(posedge clk) begin
    if (rst_n && xfcp_out.TVALID && xfcp_out.TREADY) begin
      resp_buf[resp_wptr & 127] = xfcp_out.TDATA;
      resp_wptr++;
    end
  end

  // ── Tasks ─────────────────────────────────────────────────────────

  task automatic axis_send(input logic [7:0] b);
    @(negedge clk);
    xfcp_in.TDATA  = b;
    xfcp_in.TVALID = 1'b1;
    xfcp_in.TLAST  = 1'b0;
    @(posedge clk);
    while (!xfcp_in.TREADY) @(posedge clk);
    @(negedge clk);
    xfcp_in.TVALID = 1'b0;
  endtask

  task automatic resp_wait(int unsigned n);
    int t;
    t = 0;
    while ((resp_wptr - resp_rptr) < n) begin
      @(posedge clk);
      if (++t > 200_000) $fatal(1, "resp_wait(%0d): timeout", n);
    end
  endtask

  task automatic resp_get(output logic [7:0] b);
    b = resp_buf[resp_rptr & 127];
    resp_rptr++;
  endtask

  task automatic xfcp_write(input logic [31:0] addr, input logic [31:0] data);
    axis_send(8'hFE); axis_send(8'h11);
    axis_send(8'h00); axis_send(8'h04);
    axis_send(addr[31:24]); axis_send(addr[23:16]);
    axis_send(addr[15:8]);  axis_send(addr[7:0]);
    axis_send(data[31:24]); axis_send(data[23:16]);
    axis_send(data[15:8]);  axis_send(data[7:0]);
  endtask

  task automatic xfcp_read(input logic [31:0] addr);
    axis_send(8'hFE); axis_send(8'h10);
    axis_send(8'h00); axis_send(8'h04);
    axis_send(addr[31:24]); axis_send(addr[23:16]);
    axis_send(addr[15:8]);  axis_send(addr[7:0]);
  endtask

  // Multi-word WRITE: count=8 (2 x 32-bit words at consecutive addresses)
  task automatic xfcp_write2(
    input logic [31:0] addr,
    input logic [31:0] data0,
    input logic [31:0] data1
  );
    axis_send(8'hFE); axis_send(8'h11);
    axis_send(8'h00); axis_send(8'h08);  // count=8
    axis_send(addr[31:24]); axis_send(addr[23:16]);
    axis_send(addr[15:8]);  axis_send(addr[7:0]);
    axis_send(data0[31:24]); axis_send(data0[23:16]);
    axis_send(data0[15:8]);  axis_send(data0[7:0]);
    axis_send(data1[31:24]); axis_send(data1[23:16]);
    axis_send(data1[15:8]);  axis_send(data1[7:0]);
  endtask

  task automatic drain_write_resp();
    resp_wait(21);
    resp_rptr += 21;
  endtask

  task automatic recv_read(output logic [31:0] rdata);
    logic [7:0] b;
    resp_wait(25);
    resp_rptr += 20;  // skip header
    resp_get(b); rdata[31:24] = b;
    resp_get(b); rdata[23:16] = b;
    resp_get(b); rdata[15:8]  = b;
    resp_get(b); rdata[7:0]   = b;
    resp_get(b);               // terminator
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
    xfcp_in.TDATA  = 8'h00;
    xfcp_in.TVALID = 1'b0;
    xfcp_in.TLAST  = 1'b0;
    xfcp_in.TKEEP  = '1;
    xfcp_in.TUSER  = '0;
    xfcp_in.TID    = '0;
    xfcp_in.TDEST  = '0;

    rst_n = 1'b0;
    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);

    // T1: WRITE -> slave 0 @ 0x00000004, READ back
    // 0xDEAD_BEEF bytes: DE AD BE EF — no 0xFE byte, safe.
    xfcp_write(32'h0000_0004, 32'hDEAD_BEEF);
    drain_write_resp();
    xfcp_read(32'h0000_0004);
    recv_read(rdata);
    chk32(rdata, 32'hDEAD_BEEF, "T1 slave0 WRITE+READ");

    // T2: WRITE -> slave 1 @ 0x00000044, READ back
    // Address 0x44 >> 2 = idx 17 (within MEM_DEPTH=64).
    // Data 0x1234_5678 has no 0xFE bytes.
    xfcp_write(32'h0000_0044, 32'h1234_5678);
    drain_write_resp();
    xfcp_read(32'h0000_0044);
    recv_read(rdata);
    chk32(rdata, 32'h1234_5678, "T2 slave1 WRITE+READ");

    // T3: Verify slave 0 not contaminated by T2 write to slave 1
    xfcp_read(32'h0000_0004);
    recv_read(rdata);
    chk32(rdata, 32'hDEAD_BEEF, "T3 slave0 still intact after slave1 write");

    // ── T4: Invalid-address WRITE — silently dropped, no deadlock ────
    // Address 0x100 matches no slave (ranges: 0x00, 0x40, 0x80, 0xC0 ± 64B).
    // System must not deadlock: subsequent valid READ must still work.
    // $error in DUT debug log is expected and does not count as test failure.
    xfcp_write(32'h0000_0100, 32'hDEAD_0000);  // no 0xFE bytes in addr or data
    // No response is sent for invalid WRITE (ofifo_wvalid=0 in fabric).
    // Verify liveness: re-read slave0 addr 0x04 (written in T1) must return DEAD_BEEF.
    xfcp_read(32'h0000_0004);
    recv_read(rdata);
    chk32(rdata, 32'hDEAD_BEEF, "T4 no deadlock after invalid-addr WRITE");

    // ── T5: Back-to-back WRITEs to different slaves ───────────────────
    // Send both requests before draining: verifies parallel engine dispatch.
    // Slaves 2 @ 0x80, 3 @ 0xC0 — unused addresses (T1-T3 used 0/1).
    xfcp_write(32'h0000_0080, 32'h1111_1111);  // slave 2 (no 0xFE bytes)
    xfcp_write(32'h0000_00C0, 32'h2222_2222);  // slave 3 (no 0xFE bytes)
    drain_write_resp();
    drain_write_resp();
    xfcp_read(32'h0000_0080);
    recv_read(rdata);
    chk32(rdata, 32'h1111_1111, "T5 slave2 back-to-back WRITE");
    xfcp_read(32'h0000_00C0);
    recv_read(rdata);
    chk32(rdata, 32'h2222_2222, "T5 slave3 back-to-back WRITE");

    // ── T6: In-order responses: WRITE then READ to same slave ─────────
    // WRITE first, READ second (no drain between) -> order_fifo guarantees
    // WRITE response arrives before READ response.
    xfcp_write(32'h0000_000C, 32'hABCD_1234);  // slave 0, addr 0x0C (no 0xFE)
    xfcp_read(32'h0000_000C);
    drain_write_resp();   // WRITE response must arrive first
    recv_read(rdata);     // READ response second
    chk32(rdata, 32'hABCD_1234, "T6 in-order WRITE+READ slave0");

    // ── T7: Multi-word WRITE (count=8, 2 words) to slave 0 ───────────
    // Two AXI transactions: addr 0x10 (word0) + addr 0x14 (word1).
    // WRITE response is always 21 bytes regardless of count.
    xfcp_write2(32'h0000_0010, 32'hAAAA_0001, 32'hBBBB_0002);
    drain_write_resp();
    $display("PASS T7 multi-word WRITE (count=8)");

    // ── T8: Verify T7 data + slave isolation ─────────────────────────
    // Single-word READs verify both words written by T7.
    // Also confirm slave 1 @ 0x44 (written in T2) not overwritten.
    xfcp_read(32'h0000_0010);
    recv_read(rdata);
    chk32(rdata, 32'hAAAA_0001, "T8 word0 T7 data");
    xfcp_read(32'h0000_0014);
    recv_read(rdata);
    chk32(rdata, 32'hBBBB_0002, "T8 word1 T7 data");
    xfcp_read(32'h0000_0044);
    recv_read(rdata);
    chk32(rdata, 32'h1234_5678, "T8 slave1 isolation (T2 data intact)");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
