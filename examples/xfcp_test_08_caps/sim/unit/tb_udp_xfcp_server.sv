`timescale 1ns/1ps

// tb_udp_xfcp_server -- unit test for udp_xfcp_server
//
// Tests:
//   T1: wrong dst_port  -- packet dropped, no xfcp_rx output
//   T2: XFCP READ       -- xfcp_rx stream matches 9-byte payload
//   T3: UDP reply hdr   -- dst_mac/ip/port correct in IPv4 TX output
//   T4: oversize drop   -- payload > MAX_PKT_BYTES, no xfcp_rx
//   T5: busy drop       -- second request while busy is ignored
//
// Run: vsim -c -do "run -all; quit" tb_udp_xfcp_server

module tb_udp_xfcp_server;

  localparam int XFCP_PORT_I = 50000;
  localparam int MAX_PKT     = 128;

  // =========================================================================
  // Clock: 10 ns period
  // =========================================================================
  logic clk, rst_ni;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic        s_ip_hdr_valid;
  logic [7:0]  s_ip_proto;
  logic [31:0] s_ip_src_ip;
  logic        s_ip_accept;
  logic [47:0] s_eth_src_mac;
  logic [7:0]  s_tdata;
  logic        s_tvalid;
  logic        s_tlast;
  logic        s_tuser;

  logic        rx_valid, rx_last;
  logic [7:0]  rx_data;
  logic        rx_ready;

  logic        tx_valid, tx_last;
  logic [7:0]  tx_data;
  logic        tx_ready;

  logic        meta_valid, meta_ready;
  logic [7:0]  meta_proto;
  logic [31:0] meta_dst_ip;
  logic [47:0] meta_dst_mac;
  logic [15:0] meta_plen;

  logic [7:0]  ax_tdata;
  logic        ax_tvalid, ax_tready, ax_tlast, ax_tuser;

  // =========================================================================
  // DUT
  // =========================================================================
  udp_xfcp_server #(
    .XFCP_PORT     (16'(XFCP_PORT_I)),
    .MAX_PKT_BYTES (MAX_PKT)
  ) dut (
    .clk_i                (clk),
    .rst_ni               (rst_ni),
    .s_ip_hdr_valid_i     (s_ip_hdr_valid),
    .s_ip_proto_i         (s_ip_proto),
    .s_ip_src_ip_i        (s_ip_src_ip),
    .s_ip_accept_i        (s_ip_accept),
    .s_eth_src_mac_i      (s_eth_src_mac),
    .s_axis_tdata         (s_tdata),
    .s_axis_tvalid        (s_tvalid),
    .s_axis_tlast         (s_tlast),
    .s_axis_tuser         (s_tuser),
    .xfcp_rx_valid_o      (rx_valid),
    .xfcp_rx_ready_i      (rx_ready),
    .xfcp_rx_data_o       (rx_data),
    .xfcp_rx_last_o       (rx_last),
    .xfcp_tx_valid_i      (tx_valid),
    .xfcp_tx_ready_o      (tx_ready),
    .xfcp_tx_data_i       (tx_data),
    .xfcp_tx_last_i       (tx_last),
    .m_meta_valid_o       (meta_valid),
    .m_meta_ready_i       (meta_ready),
    .m_meta_proto_o       (meta_proto),
    .m_meta_dst_ip_o      (meta_dst_ip),
    .m_meta_dst_mac_o     (meta_dst_mac),
    .m_meta_payload_len_o (meta_plen),
    .m_axis_tdata_o       (ax_tdata),
    .m_axis_tvalid_o      (ax_tvalid),
    .m_axis_tready_i      (ax_tready),
    .m_axis_tlast_o       (ax_tlast),
    .m_axis_tuser_o       (ax_tuser)
  );

  // Downstream always ready
  assign rx_ready  = 1'b1;
  assign meta_ready = 1'b1;
  assign ax_tready  = 1'b1;

  // =========================================================================
  // Monitors: capture xfcp_rx stream, m_meta, and m_axis beats
  // =========================================================================
  int          xfcp_rx_n;
  logic [7:0]  xfcp_rx_buf [256];
  logic        xfcp_rx_done;

  int          tx_bytes_n;
  logic [7:0]  tx_bytes_buf [512];

  logic        meta_seen;
  logic [47:0] meta_mac_cap;
  logic [31:0] meta_ip_cap;
  logic [15:0] meta_plen_cap;
  logic [7:0]  meta_proto_cap;

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      xfcp_rx_n    <= 0;
      xfcp_rx_done <= 1'b0;
      tx_bytes_n   <= 0;
      meta_seen    <= 1'b0;
    end else begin
      if (rx_valid && rx_ready) begin
        if (xfcp_rx_n < 256) begin
          xfcp_rx_buf[xfcp_rx_n] <= rx_data;
          xfcp_rx_n <= xfcp_rx_n + 1;
        end
        if (rx_last) xfcp_rx_done <= 1'b1;
      end
      if (ax_tvalid && ax_tready) begin
        if (tx_bytes_n < 512) begin
          tx_bytes_buf[tx_bytes_n] <= ax_tdata;
          tx_bytes_n <= tx_bytes_n + 1;
        end
      end
      if (meta_valid && meta_ready) begin
        meta_seen      <= 1'b1;
        meta_mac_cap   <= meta_dst_mac;
        meta_ip_cap    <= meta_dst_ip;
        meta_plen_cap  <= meta_plen;
        meta_proto_cap <= meta_proto;
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
    rst_ni         = 1'b0;
    s_ip_hdr_valid = 1'b0;
    s_ip_proto     = 8'h11;
    s_ip_src_ip    = '0;
    s_ip_accept    = 1'b1;
    s_eth_src_mac  = '0;
    s_tdata        = 8'h0;
    s_tvalid       = 1'b0;
    s_tlast        = 1'b0;
    s_tuser        = 1'b0;
    tx_valid       = 1'b0;
    tx_data        = 8'h0;
    tx_last        = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk); rst_ni = 1'b1;
    repeat (2) @(posedge clk);
  endtask

  // Drive full UDP L4 frame (no tready -- unconditional).
  // s_ip_hdr_valid is high only on byte 0 (as per ipv4_rx convention).
  task automatic send_udp(
    input logic [47:0] smac,
    input logic [31:0] sip,
    input logic [15:0] sport,
    input logic [15:0] dport,
    input logic [7:0]  pay[],
    input int          n_pay
  );
    automatic logic [7:0] all[];
    automatic int n_total = 8 + n_pay;
    automatic int udp_len = n_total;

    all = new[n_total];
    all[0] = sport[15:8]; all[1] = sport[7:0];
    all[2] = dport[15:8]; all[3] = dport[7:0];
    all[4] = 8'(udp_len >> 8); all[5] = 8'(udp_len);
    all[6] = 8'h00;       all[7] = 8'h00;
    for (int i = 0; i < n_pay; i++) all[8+i] = pay[i];

    for (int i = 0; i < n_total; i++) begin
      @(negedge clk);
      s_ip_hdr_valid = (i == 0) ? 1'b1 : 1'b0;
      s_ip_src_ip    = sip;
      s_eth_src_mac  = smac;
      s_tdata        = all[i];
      s_tvalid       = 1'b1;
      s_tlast        = (i == n_total - 1) ? 1'b1 : 1'b0;
      s_tuser        = 1'b0;
      @(posedge clk);
    end
    @(negedge clk);
    s_ip_hdr_valid = 1'b0;
    s_tvalid       = 1'b0;
    s_tlast        = 1'b0;
  endtask

  // Feed mock XFCP response bytes into DUT via xfcp_tx interface.
  task automatic send_resp(input logic [7:0] d[], input int n);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      tx_valid = 1'b1;
      tx_data  = d[i];
      tx_last  = (i == n - 1) ? 1'b1 : 1'b0;
      @(posedge clk);
      while (!tx_ready) @(posedge clk);
    end
    @(negedge clk);
    tx_valid = 1'b0;
    tx_last  = 1'b0;
  endtask

  // =========================================================================
  // Test constants
  // =========================================================================
  localparam logic [47:0] SMAC  = 48'hAABBCCDDEEFF;
  localparam logic [31:0] SIP   = 32'h0A000001;   // 10.0.0.1
  localparam logic [15:0] SPORT = 16'h1234;
  localparam logic [15:0] BAD_P = 16'h1111;
  localparam logic [15:0] XPORT = 16'(XFCP_PORT_I); // 0xC350

  // XFCP READ request: SOP=0xFE, OP=0x10, SEQ=0x01, CNT=0, ADDR=0xFF020000
  localparam logic [7:0] READ_REQ[9] = '{
    8'hFE, 8'h10, 8'h01, 8'h00, 8'h00, 8'hFF, 8'h02, 8'h00, 8'h00
  };

  // Mock XFCP response: SOP=0xFD, OP=0x12, SEQ=0x01, CNT=4, ADDR=0xFF020000,
  //                     DATA=0xDEADBEEF  (13 bytes total)
  localparam logic [7:0] RESP[13] = '{
    8'hFD, 8'h12, 8'h01, 8'h00, 8'h04, 8'hFF, 8'h02, 8'h00, 8'h00,
    8'hDE, 8'hAD, 8'hBE, 8'hEF
  };

  // =========================================================================
  // Main test sequence
  // =========================================================================
  initial begin
    fails = 0;
    do_reset();

    // ====================================================================
    // T1: wrong dst_port -- DUT must drop; xfcp_rx must stay silent
    // ====================================================================
    $display("--- T1: wrong dst_port drop ---");
    begin
      automatic logic [7:0] p[9] = READ_REQ;
      send_udp(SMAC, SIP, SPORT, BAD_P, p, 9);
      repeat (30) @(posedge clk);
      chk(!xfcp_rx_done,   "T1.no_rx_done");
      chk(xfcp_rx_n == 0,  "T1.rx_n==0");
    end
    do_reset();

    // ====================================================================
    // T2: valid READ -- xfcp_rx stream must match READ_REQ[9] bytes
    // T3: UDP reply   -- verify dst_mac/ip/port after mock response
    //                    (continues without reset from T2)
    // ====================================================================
    $display("--- T2+T3: READ request + UDP reply header verify ---");
    begin
      automatic logic [7:0] p[9]  = READ_REQ;
      automatic logic [7:0] r[13] = RESP;

      send_udp(SMAC, SIP, SPORT, XPORT, p, 9);
      repeat (50) @(posedge clk);   // wait for xfcp_rx to complete

      // T2 checks
      chk(xfcp_rx_done,    "T2.rx_done");
      chk(xfcp_rx_n == 9,  "T2.rx_n==9");
      for (int i = 0; i < 9; i++)
        chk(xfcp_rx_buf[i] == READ_REQ[i],
            $sformatf("T2.byte[%0d]==%02h", i, READ_REQ[i]));

      // T3: feed mock response, then verify IPv4 TX output
      send_resp(r, 13);
      repeat (50) @(posedge clk);   // wait for TX path to complete

      chk(meta_seen,                "T3.meta_seen");
      chk(meta_proto_cap == 8'h11,  "T3.proto==0x11");
      chk(meta_mac_cap   == SMAC,   "T3.dst_mac==src_mac");
      chk(meta_ip_cap    == SIP,    "T3.dst_ip==src_ip");
      chk(meta_plen_cap  == 16'd21, "T3.plen==21");    // 8 UDP hdr + 13 resp
      chk(tx_bytes_n     >= 8,      "T3.tx_hdr_present");
      if (tx_bytes_n >= 8) begin
        chk({tx_bytes_buf[0], tx_bytes_buf[1]} == XPORT,
            "T3.udp_src_port==50000");
        chk({tx_bytes_buf[2], tx_bytes_buf[3]} == SPORT,
            "T3.udp_dst_port==src_port");
      end
    end
    do_reset();

    // ====================================================================
    // T4: oversize payload (129 B > MAX_PKT_BYTES=128) -- drop, no xfcp_rx
    // ====================================================================
    $display("--- T4: oversize payload drop ---");
    begin
      automatic logic [7:0] big[129];
      for (int i = 0; i < 129; i++) big[i] = 8'(i + 1);
      send_udp(SMAC, SIP, SPORT, XPORT, big, 129);
      repeat (30) @(posedge clk);
      chk(!xfcp_rx_done,  "T4.no_rx_done");
      chk(xfcp_rx_n == 0, "T4.rx_n==0");
    end
    do_reset();

    // ====================================================================
    // T5: second request while busy -- only first packet must be forwarded
    // ====================================================================
    $display("--- T5: busy drop ---");
    begin
      automatic logic [7:0] p1[9] = READ_REQ;           // SEQ=0x01
      automatic logic [7:0] p2[9] = '{
        8'hFE, 8'h10, 8'hBB, 8'h00, 8'h00,              // SEQ=0xBB
        8'hFF, 8'h03, 8'h00, 8'h00
      };
      // Send both back-to-back; p1 completes -> rx_complete=1 before p2 byte 0
      send_udp(SMAC, SIP, SPORT, XPORT, p1, 9);
      send_udp(SMAC, SIP, SPORT, XPORT, p2, 9);
      repeat (50) @(posedge clk);
      chk(xfcp_rx_done,            "T5.rx_done");
      chk(xfcp_rx_n == 9,          "T5.rx_n==9_only_first");
      chk(xfcp_rx_buf[2] == 8'h01, "T5.seq==0x01_not_0xBB");
    end

    // ====================================================================
    // Summary
    // ====================================================================
    repeat (5) @(posedge clk);
    if (fails == 0)
      $display("PASS: all 5 udp_xfcp_server tests passed");
    else
      $display("FAIL: %0d test(s) failed", fails);
    $finish;
  end

  initial begin
    #500000;
    $display("FAIL: simulation timeout");
    $finish;
  end

endmodule
