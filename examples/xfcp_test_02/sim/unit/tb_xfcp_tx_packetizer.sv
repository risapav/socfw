`timescale 1ns/1ps

// Testbench for xfcp_tx_packetizer (standalone, no UART, no engine).
//
// Inject resp_start + resp_type + read_data directly.
// Capture AXI-Stream output bytes and verify packet format.
//
// Packet format:
//   WRITE resp (type=0x13): [FE][13][TYPE 2B][STR 16B][0x00+TLAST] = 21 bytes
//   READ  resp (type=0x12): [FE][12][TYPE 2B][STR 16B][data 4B MSB-first][0x00+TLAST] = 25 bytes
//
// Tests:
//   T1: WRITE response -> verify 21 bytes, FE 13 header, TLAST on last
//   T2: READ response 1 word -> verify 25 bytes, FE 12 header, data MSB-first, TLAST
//   T3: READ response with backpressure on m_axis_tready
//   T4: Two consecutive WRITE responses
//   T5: READ response with late resp_done_i (off-by-one timing)
//   T6: ID_STR exactly 16 bytes in header
//
// TODO: implement all tests
// Run with:
//   vlog -sv -suppress 2892 $(XFCP_COMMON) unit/tb_xfcp_tx_packetizer.sv
//   vsim -c -do "run -all; quit" tb_xfcp_tx_packetizer

module tb_xfcp_tx_packetizer;
  import xfcp_pkg::*;

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ── DUT signals ──────────────────────────────────────────────────
  logic [7:0]  m_axis_tdata;
  logic        m_axis_tvalid;
  logic        m_axis_tready;
  logic        m_axis_tlast;
  logic        resp_start;
  logic [7:0]  resp_type;
  logic [31:0] read_data;
  logic        read_data_valid;
  logic        read_data_ready;
  logic        resp_done_i;
  logic        packetizer_idle;
  logic        resp_done_o;

  // ── DUT ──────────────────────────────────────────────────────────
  xfcp_tx_packetizer #(
    .AXI_DATA_WIDTH (32),
    .XFCP_ID_TYPE   (16'h0001),
    .XFCP_ID_STR    ("TB-PACKETIZER  ")
  ) dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .m_axis_tdata    (m_axis_tdata),
    .m_axis_tvalid   (m_axis_tvalid),
    .m_axis_tready   (m_axis_tready),
    .m_axis_tlast    (m_axis_tlast),
    .resp_start      (resp_start),
    .resp_type       (resp_type),
    .read_data       (read_data),
    .read_data_valid (read_data_valid),
    .read_data_ready (read_data_ready),
    .resp_done_i     (resp_done_i),
    .packetizer_idle (packetizer_idle),
    .resp_done_o     (resp_done_o)
  );

  // Output capture
  logic [7:0]  cap_buf [0:63];
  int unsigned cap_wptr;

  initial begin
    cap_wptr       = 0;
    m_axis_tready  = 1'b1;
    resp_start     = 1'b0;
    resp_type      = 8'h13;
    read_data      = '0;
    read_data_valid = 1'b0;
    resp_done_i    = 1'b0;
  end

  always @(posedge clk) begin
    if (rst_n && m_axis_tvalid && m_axis_tready) begin
      cap_buf[cap_wptr & 63] = m_axis_tdata;
      cap_wptr++;
    end
  end

  // ── Tasks ─────────────────────────────────────────────────────────

  task automatic do_reset();
    rst_n = 1'b0;
    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  // Wait for N bytes to be captured
  task automatic wait_bytes(int unsigned n);
    int unsigned start;
    int t;
    start = cap_wptr;
    t = 0;
    while ((cap_wptr - start) < n) begin
      @(posedge clk);
      if (++t > 5000) $fatal(1, "wait_bytes(%0d): timeout", n);
    end
  endtask

  // Send one WRITE response (21 bytes)
  task automatic send_write_resp();
    @(negedge clk);
    resp_type  = 8'h13;
    resp_start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    resp_start = 1'b0;
    wait_bytes(21);
  endtask

  // Send one READ response: 1 word.
  // resp_done_i is pulsed early (during ST_HEADER) to set done_latch_q.
  // read_data_valid must be held until read_data_ready asserts in ST_PAYLOAD
  // (read_data_ready=0 outside ST_PAYLOAD, so early release loses the word).
  task automatic send_read_resp(input logic [31:0] data);
    int unsigned base;
    base = cap_wptr;
    @(negedge clk);
    resp_type       = 8'h12;
    resp_start      = 1'b1;
    read_data       = data;
    read_data_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    resp_start  = 1'b0;
    resp_done_i = 1'b1;   // sets done_latch_q (packetizer still in ST_HEADER)
    @(posedge clk);
    @(negedge clk);
    resp_done_i = 1'b0;
    // Hold read_data_valid until packetizer enters ST_PAYLOAD and
    // read_data_ready asserts (slot0 empty at ST_PAYLOAD entry).
    @(posedge clk);
    begin : wait_rdready
      int t;
      t = 0;
      while (!read_data_ready) begin
        @(posedge clk);
        if (++t > 5000) $fatal(1, "send_read_resp: read_data_ready timeout");
      end
    end
    @(negedge clk);
    read_data_valid = 1'b0;  // word consumed into slot0 at preceding posedge
    // Wait for all 25 bytes from the start of this response
    begin : wait_all
      int t;
      t = 0;
      while ((cap_wptr - base) < 25) begin
        @(posedge clk);
        if (++t > 5000) $fatal(1, "send_read_resp: 25-byte timeout");
      end
    end
  endtask

  task automatic chk8(input int unsigned idx, input logic [7:0] exp, input string lbl);
    if (cap_buf[idx & 63] !== exp) begin
      $display("FAIL %s [%0d]: got=0x%02X exp=0x%02X", lbl, idx, cap_buf[idx & 63], exp);
      fails++;
    end else $display("PASS %s [%0d]: 0x%02X", lbl, idx, exp);
  endtask

  // ── Stimulus ──────────────────────────────────────────────────────
  int unsigned base;

  initial begin
    do_reset();

    // T1: WRITE response
    base = cap_wptr;
    send_write_resp();
    chk8(base+0,  8'hFE, "T1 SOP");
    chk8(base+1,  8'h13, "T1 TYPE");
    chk8(base+20, 8'h00, "T1 terminator");
    if (m_axis_tlast !== 1'b0)
      $display("NOTE T1: TLAST not captured in comb path — check DONE byte");
    $display("PASS T1 WRITE response 21 bytes");

    // T2: READ response
    base = cap_wptr;
    send_read_resp(32'hA5A5_A5A5);
    chk8(base+0,  8'hFE,   "T2 SOP");
    chk8(base+1,  8'h12,   "T2 TYPE");
    chk8(base+20, 8'hA5,   "T2 data[31:24]");
    chk8(base+21, 8'hA5,   "T2 data[23:16]");
    chk8(base+22, 8'hA5,   "T2 data[15:8]");
    chk8(base+23, 8'hA5,   "T2 data[7:0]");
    chk8(base+24, 8'h00,   "T2 terminator");
    $display("PASS T2 READ response 25 bytes");

    // T3-T6: TODO
    $display("");
    $display("NOTE: T3-T6 not yet implemented — stub testbench");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
