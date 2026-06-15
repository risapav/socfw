`timescale 1ns/1ps

// tb_xfcp_arbiter_2to1 -- unit test for xfcp_arbiter_2to1
//
// Tests:
//   T1: UART READ  -- synthetic TLAST after byte 9 (ADDR3, remain=0)
//   T2: ETH packet -- natural s1_last forwarded as m_last
//   T3: UART WRITE -- synthetic TLAST after byte 11 (CNT=2 payload bytes)
//   T4: Priority   -- UART (s0) wins when both s0+s1 pending at ARB_IDLE
//   T5: Order FIFO -- UART response routed to m0, ETH response to m1
//   T6: SOP filter -- invalid UART bytes silently dropped, valid packet follows
//   T7: SOP filter -- ETH granted when UART port has only invalid SOP bytes
//
// Run: vsim -c -do "run -all; quit" tb_xfcp_arbiter_2to1

module tb_xfcp_arbiter_2to1;
  import xfcp_pkg::*;

  // =========================================================================
  // Clock: 10 ns period
  // =========================================================================
  logic clk;
  logic rst_ni;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // =========================================================================
  // DUT port signals
  // =========================================================================
  logic       s0_valid, s0_ready;
  logic [7:0] s0_data;

  logic       s1_valid, s1_ready;
  logic [7:0] s1_data;
  logic       s1_last;

  logic       m_valid,  m_ready;
  logic [7:0] m_data;
  logic       m_last;

  logic       s_resp_valid, s_resp_ready;
  logic [7:0] s_resp_data;
  logic       s_resp_last;

  logic       m0_valid, m0_ready;
  logic [7:0] m0_data;
  logic       m0_last;

  logic       m1_valid, m1_ready;
  logic [7:0] m1_data;
  logic       m1_last;

  // =========================================================================
  // DUT
  // =========================================================================
  xfcp_arbiter_2to1 #(
    .ORD_FIFO_DEPTH (4)
  ) dut (
    .clk_i          (clk),
    .rst_ni         (rst_ni),
    .s0_valid_i     (s0_valid),
    .s0_ready_o     (s0_ready),
    .s0_data_i      (s0_data),
    .s1_valid_i     (s1_valid),
    .s1_ready_o     (s1_ready),
    .s1_data_i      (s1_data),
    .s1_last_i      (s1_last),
    .m_valid_o      (m_valid),
    .m_ready_i      (m_ready),
    .m_data_o       (m_data),
    .m_last_o       (m_last),
    .s_resp_valid_i (s_resp_valid),
    .s_resp_ready_o (s_resp_ready),
    .s_resp_data_i  (s_resp_data),
    .s_resp_last_i  (s_resp_last),
    .m0_valid_o     (m0_valid),
    .m0_ready_i     (m0_ready),
    .m0_data_o      (m0_data),
    .m0_last_o      (m0_last),
    .m1_valid_o     (m1_valid),
    .m1_ready_i     (m1_ready),
    .m1_data_o      (m1_data),
    .m1_last_o      (m1_last)
  );

  // Downstream always ready
  assign m_ready  = 1'b1;
  assign m0_ready = 1'b1;
  assign m1_ready = 1'b1;

  // =========================================================================
  // Monitors -- updated by always block, read by initial block at negedge
  // =========================================================================
  int   ep_cnt;      // beats forwarded to endpoint since last reset
  int   m0_cnt;      // beats delivered on m0 since last reset
  int   m1_cnt;      // beats delivered on m1 since last reset
  logic ep_last_saw; // m_last seen on the most recent forwarded beat
  logic m0_got_last; // m0 has received at least one TLAST
  logic m1_got_last; // m1 has received at least one TLAST

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ep_cnt      <= 0;
      m0_cnt      <= 0;
      m1_cnt      <= 0;
      ep_last_saw <= 1'b0;
      m0_got_last <= 1'b0;
      m1_got_last <= 1'b0;
    end else begin
      if (m_valid && m_ready) begin
        ep_cnt      <= ep_cnt + 1;
        ep_last_saw <= m_last;
      end
      if (m0_valid && m0_ready) begin
        m0_cnt <= m0_cnt + 1;
        if (m0_last) m0_got_last <= 1'b1;
      end
      if (m1_valid && m1_ready) begin
        m1_cnt <= m1_cnt + 1;
        if (m1_last) m1_got_last <= 1'b1;
      end
    end
  end

  // =========================================================================
  // Check helper
  // =========================================================================
  int fails;

  task automatic chk(input logic cond, input string lbl);
    if (!cond) begin $display("FAIL %s", lbl); fails++; end
    else             $display("PASS %s", lbl);
  endtask

  // =========================================================================
  // Stimulus tasks
  // =========================================================================

  task automatic do_reset();
    rst_ni       = 1'b0;
    s0_valid     = 1'b0; s0_data     = 8'h0;
    s1_valid     = 1'b0; s1_data     = 8'h0; s1_last     = 1'b0;
    s_resp_valid = 1'b0; s_resp_data = 8'h0; s_resp_last = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk);
  endtask

  // Send one byte on UART port; blocks until s0_ready handshake completes
  task automatic p0_byte(input logic [7:0] d);
    @(negedge clk);
    s0_valid = 1'b1;
    s0_data  = d;
    @(posedge clk);
    while (!s0_ready) @(posedge clk);
    @(negedge clk);
    s0_valid = 1'b0;
  endtask

  // UART XFCP READ: 9 bytes (SOP OP SEQ CNT_H CNT_L ADDR[3:0])
  // Arbiter generates synthetic TLAST on ADDR3 (byte 9) when remain==0
  task automatic p0_read(input logic [7:0] seq, input logic [31:0] addr);
    p0_byte(XFCP_SOP_REQ);
    p0_byte(8'(XFCP_OP_READ));
    p0_byte(seq);
    p0_byte(8'h00);       // CNT_H = 0
    p0_byte(8'h00);       // CNT_L = 0
    p0_byte(addr[31:24]); // ADDR MSB first (Big-Endian)
    p0_byte(addr[23:16]);
    p0_byte(addr[15:8]);
    p0_byte(addr[7:0]);
  endtask

  // UART XFCP WRITE with exactly 2 payload bytes (CNT=2)
  // Arbiter generates synthetic TLAST on 2nd payload byte (byte 11)
  task automatic p0_write2(
    input logic [7:0]  seq,
    input logic [31:0] addr,
    input logic [7:0]  d0, d1
  );
    p0_byte(XFCP_SOP_REQ);
    p0_byte(8'(XFCP_OP_WRITE));
    p0_byte(seq);
    p0_byte(8'h00);       // CNT_H = 0
    p0_byte(8'h02);       // CNT_L = 2
    p0_byte(addr[31:24]);
    p0_byte(addr[23:16]);
    p0_byte(addr[15:8]);
    p0_byte(addr[7:0]);
    p0_byte(d0);
    p0_byte(d1);
  endtask

  // ETH framed packet on s1: n bytes, TLAST asserted on the last
  task automatic p1_pkt(input int n);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      s1_valid = 1'b1;
      s1_data  = 8'(i + 1);
      s1_last  = (i == n - 1) ? 1'b1 : 1'b0;
      @(posedge clk);
      while (!s1_ready) @(posedge clk);
    end
    @(negedge clk);
    s1_valid = 1'b0;
    s1_last  = 1'b0;
  endtask

  // Inject a 3-byte response on s_resp (TLAST on byte 3)
  task automatic resp3(input logic [7:0] d0, d1, d2);
    @(negedge clk);
    s_resp_valid = 1'b1; s_resp_data = d0; s_resp_last = 1'b0;
    @(posedge clk); while (!s_resp_ready) @(posedge clk);
    @(negedge clk);
    s_resp_valid = 1'b1; s_resp_data = d1; s_resp_last = 1'b0;
    @(posedge clk); while (!s_resp_ready) @(posedge clk);
    @(negedge clk);
    s_resp_valid = 1'b1; s_resp_data = d2; s_resp_last = 1'b1;
    @(posedge clk); while (!s_resp_ready) @(posedge clk);
    @(negedge clk);
    s_resp_valid = 1'b0;
    s_resp_last  = 1'b0;
  endtask

  // =========================================================================
  // Main test sequence
  // =========================================================================
  initial begin
    fails = 0;

    // -- T1: UART READ -- synthetic TLAST after 9th byte (ADDR3) -----------
    do_reset();
    p0_read(8'h01, 32'hFF00_0000);
    @(negedge clk);
    chk(ep_cnt      == 9,    "T1 ep_cnt=9");
    chk(ep_last_saw == 1'b1, "T1 TLAST on byte 9 (ADDR3)");

    // -- T2: ETH packet -- natural s1_last forwarded as m_last -------------
    do_reset();
    p1_pkt(5);
    @(negedge clk);
    chk(ep_cnt      == 5,    "T2 ep_cnt=5");
    chk(ep_last_saw == 1'b1, "T2 ETH TLAST forwarded");

    // -- T3: UART WRITE -- TLAST after 11th byte (2nd payload) -------------
    do_reset();
    p0_write2(8'h02, 32'hFF01_0000, 8'hDE, 8'hAD);
    @(negedge clk);
    chk(ep_cnt      == 11,   "T3 ep_cnt=11");
    chk(ep_last_saw == 1'b1, "T3 TLAST on byte 11 (payload[1])");

    // -- T4: Priority -- UART gets ARB_GRANT0 when both s0+s1 at IDLE -----
    do_reset();
    @(negedge clk);
    s0_valid = 1'b1; s0_data = XFCP_SOP_REQ;       // UART pending
    s1_valid = 1'b1; s1_data = 8'hAA; s1_last = 1'b0; // ETH pending
    @(posedge clk);  // ARB_IDLE: arb_d = ARB_GRANT0 (s0 wins)
    @(posedge clk);  // arb_q = ARB_GRANT0 => s0_ready=1, s1_ready=0
    @(negedge clk);
    chk(s0_ready === 1'b1 && s1_ready === 1'b0,
        "T4 UART granted (s0_ready=1, s1_ready=0)");
    s0_valid = 1'b0;
    s1_valid = 1'b0; s1_last = 1'b0;

    // -- T5: Order FIFO -- resp1 -> m0 (UART), resp2 -> m1 (ETH) ----------
    do_reset();
    p0_read(8'h10, 32'hFF00_0000); // ord_fifo push: 0 (UART)
    p1_pkt(5);                     // ord_fifo push: 1 (ETH)
    @(negedge clk);
    chk(ep_cnt == 14, "T5 ep_cnt=14 (9+5)");

    resp3(8'hFD, 8'hAA, 8'hBB);   // response 1 -- must route to m0
    @(negedge clk);
    chk(m0_cnt      == 3,    "T5 resp1 m0_cnt=3");
    chk(m1_cnt      == 0,    "T5 resp1 m1_cnt=0");
    chk(m0_got_last == 1'b1, "T5 resp1 m0 TLAST");
    chk(m1_got_last == 1'b0, "T5 resp1 m1 no TLAST yet");

    resp3(8'hFD, 8'hCC, 8'hDD);   // response 2 -- must route to m1
    @(negedge clk);
    chk(m1_cnt      == 3,    "T5 resp2 m1_cnt=3");
    chk(m1_got_last == 1'b1, "T5 resp2 m1 TLAST");

    // -- T6: SOP filter -- invalid UART bytes dropped, valid READ accepted ----
    do_reset();
    // Two consecutive non-SOP bytes must be consumed from UART FIFO without
    // being forwarded to the fabric endpoint and without pushing order FIFO.
    @(negedge clk); s0_valid = 1'b1; s0_data = 8'hAB;  // bad byte 1
    @(posedge clk); while (!s0_ready) @(posedge clk);
    @(negedge clk); s0_valid = 1'b1; s0_data = 8'h00;  // bad byte 2
    @(posedge clk); while (!s0_ready) @(posedge clk);
    @(negedge clk); s0_valid = 1'b0;
    chk(ep_cnt == 0, "T6 bad bytes not forwarded to endpoint");
    // A valid UART READ after the noise must work normally.
    p0_read(8'h05, 32'hFF02_0000);
    @(negedge clk);
    chk(ep_cnt      == 9,    "T6 valid READ ep_cnt=9");
    chk(ep_last_saw == 1'b1, "T6 valid READ TLAST on ADDR3");

    // -- T7: SOP filter -- ETH granted when UART has bad byte ----------------
    // At ARB_IDLE, if UART has an invalid SOP but ETH is valid, ETH is granted.
    // arb_q is registered so ETH byte appears on m_valid one cycle AFTER
    // arb_d=GRANT1 is computed (two posedges after stimulus).
    do_reset();
    @(negedge clk);
    s0_valid = 1'b1; s0_data = 8'hBB;             // bad UART byte (persists)
    s1_valid = 1'b1; s1_data = 8'hAA; s1_last = 1'b1;  // ETH single byte
    @(posedge clk);  // posedge_0: arb_q: IDLE -> GRANT1 (latched)
    @(posedge clk);  // posedge_1: arb_q=GRANT1 active; ETH byte forwarded
    @(negedge clk);
    chk(ep_cnt      == 1,    "T7 ETH byte forwarded ep_cnt=1");
    chk(ep_last_saw == 1'b1, "T7 ETH TLAST forwarded");
    s1_valid = 1'b0; s1_last = 1'b0;
    // posedge_2: arb_q: GRANT1 -> IDLE; bad UART byte consumed (s0_ready=1).
    @(posedge clk);
    @(negedge clk);
    chk(ep_cnt == 1, "T7 bad UART byte not forwarded (ep_cnt stays 1)");
    s0_valid = 1'b0;

    // ======================================================================
    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
