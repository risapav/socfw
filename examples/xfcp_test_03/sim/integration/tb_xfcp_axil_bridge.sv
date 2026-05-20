`timescale 1ns/1ps

// Testbench for xfcp_axil_bridge (parser + engine + packetizer).
//
// AXIS bytes injected directly into xfcp_in (no UART).
// AXI slave: axil_slave_model (memory-backed, MEM_DEPTH=64 words).
// Configuration: LITTLE_ENDIAN=0 (data MSB-first on wire, no byte-swap).
//
// Request format (TLAST=0 throughout; parser uses COUNT field):
//   WRITE: [FE][11][00][04][addr 4B BE][data 4B MSB-first]
//   READ:  [FE][10][00][04][addr 4B BE]
//
// Response format:
//   WRITE: [FE][13][type 2B][str 16B][0x00+TLAST]         = 21 bytes
//   READ:  [FE][12][type 2B][str 16B][data 4B MSB-first][0x00+TLAST] = 25 bytes
//
// Tests:
//   T1: WRITE 0xA5A5_A5A5 -> addr 0x00000004; drain response
//   T2: READ  addr 0x00000004 -> expect 0xA5A5_A5A5
//   T3: WRITE 0x1234_5678 -> addr 0x00000008; READ back -> verify
//   T4: READ addr 0x00000004 still intact after T3
//   T5: WRITE 0 -> READ 0 (clear verify)
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) $(XFCP_COMMON) \
//        $(RTL_AXIL)/axil_slave_model.sv tb_xfcp_axil_bridge.sv
//   vsim -c -do "run -all; quit" tb_xfcp_axil_bridge

module tb_xfcp_axil_bridge;
  import axi_pkg::*;
  import xfcp_pkg::*;

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ── Interfaces ───────────────────────────────────────────────────
  axi4s_if    #(.DATA_WIDTH(8))                   xfcp_in  (.TCLK(clk), .TRESETn(rst_n));
  axi4s_if    #(.DATA_WIDTH(8))                   xfcp_out (.TCLK(clk), .TRESETn(rst_n));
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil     (.ACLK(clk), .ARESETn(rst_n));

  // ── DUT ──────────────────────────────────────────────────────────
  xfcp_axil_bridge #(
    .LITTLE_ENDIAN  (1'b0),
    .AXI_ADDR_WIDTH (32),
    .AXI_DATA_WIDTH (32)
  ) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .xfcp_in (xfcp_in.slave),
    .xfcp_out(xfcp_out.master),
    .m_axil  (axil.master)
  );

  // ── AXI memory slave ─────────────────────────────────────────────
  axil_slave_model #(.MEM_DEPTH(64)) u_slave (
    .clk   (clk),
    .rstn  (rst_n),
    .s_axil(axil.slave)
  );

  // Always accept xfcp_out
  assign xfcp_out.TREADY = 1'b1;

  // Response capture buffer
  logic [7:0]  resp_buf [0:63];
  int unsigned resp_wptr, resp_rptr;

  initial begin
    resp_wptr = 0;
    resp_rptr = 0;
  end

  always @(posedge clk) begin
    if (rst_n && xfcp_out.TVALID && xfcp_out.TREADY) begin
      resp_buf[resp_wptr & 63] = xfcp_out.TDATA;
      resp_wptr++;
    end
  end

  // ── Tasks ─────────────────────────────────────────────────────────

  // Send one byte into xfcp_in (TLAST=0)
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

  // Block until N bytes are in resp_buf (with timeout)
  task automatic resp_wait(int unsigned n);
    int timeout;
    timeout = 0;
    while ((resp_wptr - resp_rptr) < n) begin
      @(posedge clk);
      if (++timeout > 200_000)
        $fatal(1, "resp_wait: timeout waiting for %0d bytes (have %0d)",
               n, resp_wptr - resp_rptr);
    end
  endtask

  task automatic resp_drain(int unsigned n);
    resp_rptr += n;
  endtask

  task automatic resp_get(output logic [7:0] b);
    b = resp_buf[resp_rptr & 63];
    resp_rptr++;
  endtask

  // XFCP WRITE: [FE][11][00][04][addr BE][data MSB-first]
  task automatic xfcp_write(input logic [31:0] addr, input logic [31:0] data);
    axis_send(8'hFE); axis_send(8'h11);
    axis_send(8'h00); axis_send(8'h04);
    axis_send(addr[31:24]); axis_send(addr[23:16]);
    axis_send(addr[15:8]);  axis_send(addr[7:0]);
    axis_send(data[31:24]); axis_send(data[23:16]);
    axis_send(data[15:8]);  axis_send(data[7:0]);
  endtask

  // Drain WRITE response (21 bytes: FE 13 + type 2B + str 16B + 0x00)
  task automatic drain_write_resp();
    resp_wait(21);
    resp_drain(21);
  endtask

  // XFCP READ: [FE][10][00][04][addr BE]
  task automatic xfcp_read(input logic [31:0] addr);
    axis_send(8'hFE); axis_send(8'h10);
    axis_send(8'h00); axis_send(8'h04);
    axis_send(addr[31:24]); axis_send(addr[23:16]);
    axis_send(addr[15:8]);  axis_send(addr[7:0]);
  endtask

  // Receive READ response (25 bytes): skip 20B header, read 4B data, drain terminator
  task automatic recv_read(output logic [31:0] rdata);
    logic [7:0] b;
    resp_wait(25);
    resp_drain(20);
    resp_get(b); rdata[31:24] = b;
    resp_get(b); rdata[23:16] = b;
    resp_get(b); rdata[15:8]  = b;
    resp_get(b); rdata[7:0]   = b;
    resp_get(b);  // terminator 0x00
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

    // T1: WRITE 0xA5A5_A5A5 to addr 0x00000004
    xfcp_write(32'h00000004, 32'hA5A5_A5A5);
    drain_write_resp();
    $display("PASS T1 WRITE response received");

    // T2: READ addr 0x00000004 — expect 0xA5A5_A5A5
    xfcp_read(32'h00000004);
    recv_read(rdata);
    chk32(rdata, 32'hA5A5_A5A5, "T2 READ after WRITE");

    // T3: WRITE 0x1234_5678 to addr 0x00000008, READ back
    xfcp_write(32'h00000008, 32'h1234_5678);
    drain_write_resp();
    xfcp_read(32'h00000008);
    recv_read(rdata);
    chk32(rdata, 32'h1234_5678, "T3 WRITE+READ 0x08");

    // T4: Verify addr 0x00000004 still intact after T3
    xfcp_read(32'h00000004);
    recv_read(rdata);
    chk32(rdata, 32'hA5A5_A5A5, "T4 addr 0x04 still intact");

    // T5: Clear addr 0x00000004, verify
    xfcp_write(32'h00000004, 32'h0);
    drain_write_resp();
    xfcp_read(32'h00000004);
    recv_read(rdata);
    chk32(rdata, 32'h0, "T5 WRITE 0 -> READ 0");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
