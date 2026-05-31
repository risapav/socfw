`timescale 1ns/1ps
/**
 * @file tb_eth_header_parser.sv
 * @brief Unit test for eth_header_parser module.
 * @details Tests:
 *   T1: Matching dst_mac — payload forwarded, hdr_valid_o=1, drop_o=0
 *   T2: Broadcast frame (accept_broadcast_i=1) — forwarded
 *   T3: Mismatched dst_mac — dropped (drop_o=1, no m_axis output), no downstream stall
 *   T4: Short frame (< 14 bytes, early tlast in ST_HEADER) — parser resets cleanly
 *   T5: Back-to-back frames — second frame parsed correctly after first
 */

module tb_eth_header_parser;
  import tb_eth_pkg::*;

  logic        clk   = 1'b0;
  logic        rst_n = 1'b0;

  logic [47:0] local_mac;
  logic        accept_bc;
  logic        promisc;

  logic [7:0]  s_tdata;
  logic        s_tvalid;
  logic        s_tready;
  logic        s_tlast;
  logic        s_tuser;

  logic [7:0]  m_tdata;
  logic        m_tvalid;
  logic        m_tready;
  logic        m_tlast;
  logic        m_tuser;

  logic [47:0] rx_dst_mac;
  logic [47:0] rx_src_mac;
  logic [15:0] rx_ethertype;
  logic        hdr_valid;
  logic        drop;

  logic        hdr_done_pulse;
  logic        hdr_accept_pulse;
  logic        hdr_drop_pulse;
  logic [47:0] dbg_dst_mac;
  logic        dbg_mac_accept;

  always #4 clk = ~clk;

  eth_header_parser dut (
    .clk_i(clk), .rst_ni(rst_n),
    .local_mac_i(local_mac), .accept_broadcast_i(accept_bc), .promiscuous_i(promisc),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
    .rx_dst_mac_o(rx_dst_mac), .rx_src_mac_o(rx_src_mac), .rx_ethertype_o(rx_ethertype),
    .hdr_valid_o(hdr_valid), .drop_o(drop),
    .hdr_done_pulse_o  (hdr_done_pulse),
    .hdr_accept_pulse_o(hdr_accept_pulse),
    .hdr_drop_pulse_o  (hdr_drop_pulse),
    .dbg_dst_mac_o     (dbg_dst_mac),
    .dbg_mac_accept_o  (dbg_mac_accept)
  );

  // Pre-NBA capture — sample DUT outputs before state_q NBA
  logic        m_tvalid_cap, m_tlast_cap, hdr_valid_cap, drop_cap;
  logic [7:0]  m_tdata_cap;
  logic        s_tready_cap;
  logic        hdr_acc_cap, hdr_drp_cap;
  always @(posedge clk) begin
    m_tvalid_cap  = m_tvalid;
    m_tlast_cap   = m_tlast;
    m_tdata_cap   = m_tdata;
    hdr_valid_cap = hdr_valid;
    drop_cap      = drop;
    s_tready_cap  = s_tready;
    hdr_acc_cap   = hdr_accept_pulse;
    hdr_drp_cap   = hdr_drop_pulse;
  end

  int fails = 0;

  localparam logic [47:0] LOCAL_MAC = 48'hAA_BB_CC_DD_EE_FF;
  localparam logic [47:0] SRC_MAC   = 48'h11_22_33_44_55_66;
  localparam logic [47:0] BCAST_MAC = 48'hFF_FF_FF_FF_FF_FF;
  localparam logic [47:0] OTHER_MAC = 48'hDE_AD_BE_EF_00_01;
  localparam logic [15:0] ETYPE     = 16'h0800;

  task automatic clk_wait(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  // Send a complete Ethernet frame and capture payload bytes seen at m_axis.
  // dst_mac: destination MAC in frame header
  // payload: bytes to send as payload (after 14-byte header)
  // m_tready_val: downstream ready value to hold during the frame
  task automatic send_frame(
    input  logic [47:0] dst_mac,
    input  logic [7:0]  payload[$],
    input  logic        m_tready_val,
    output logic [7:0]  cap[$],
    output logic        hdr_valid_seen,
    output logic        drop_seen,
    output logic        tlast_seen,
    output logic        hdr_acc_seen,
    output logic        hdr_drp_seen
  );
    logic [7:0] hdr[14];
    int total;

    cap            = {};
    hdr_valid_seen = 1'b0;
    drop_seen      = 1'b0;
    tlast_seen     = 1'b0;
    hdr_acc_seen   = 1'b0;
    hdr_drp_seen   = 1'b0;

    build_eth_hdr(dst_mac, SRC_MAC, ETYPE, hdr);
    total = 14 + payload.size();

    @(negedge clk);
    m_tready <= m_tready_val;

    // Send header + payload byte by byte
    for (int i = 0; i < total; i++) begin
      @(negedge clk);
      s_tdata  <= (i < 14) ? hdr[i] : payload[i - 14];
      s_tvalid <= 1'b1;
      s_tlast  <= (i == total - 1) ? 1'b1 : 1'b0;
      @(posedge clk); #1;
      if (m_tvalid_cap && m_tready) begin
        cap.push_back(m_tdata_cap);
        if (m_tlast_cap) tlast_seen = 1'b1;
      end
      if (hdr_valid_cap) hdr_valid_seen = 1'b1;
      if (drop_cap)      drop_seen      = 1'b1;
      if (hdr_acc_cap)   hdr_acc_seen   = 1'b1;
      if (hdr_drp_cap)   hdr_drp_seen   = 1'b1;
    end

    @(negedge clk);
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;

    // Flush: a few more cycles to let FSM settle
    repeat (3) begin
      @(posedge clk); #1;
      if (m_tvalid_cap && m_tready) begin
        cap.push_back(m_tdata_cap);
        if (m_tlast_cap) tlast_seen = 1'b1;
      end
      if (hdr_acc_cap) hdr_acc_seen = 1'b1;
      if (hdr_drp_cap) hdr_drp_seen = 1'b1;
    end
  endtask

  // Send raw bytes (for short-frame test)
  task automatic send_raw(
    input logic [7:0] data[$],
    input int         last_idx
  );
    for (int i = 0; i < data.size(); i++) begin
      @(negedge clk);
      s_tdata  <= data[i];
      s_tvalid <= 1'b1;
      s_tlast  <= (i == last_idx) ? 1'b1 : 1'b0;
      @(posedge clk); #1;
    end
    @(negedge clk);
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
    clk_wait(3);
  endtask

  initial begin
    s_tdata  <= 8'h00;
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
    s_tuser  <= 1'b0;
    m_tready <= 1'b1;
    local_mac <= LOCAL_MAC;
    accept_bc <= 1'b1;
    promisc   <= 1'b0;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(3);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(2);

    // ===== T1: matching dst_mac — forwarded =====
    begin
      logic [7:0]  pl[$], cap[$];
      logic        hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen;

      for (int i = 0; i < 5; i++) pl.push_back(8'(8'hA0 + i)); // A0..A4

      send_frame(LOCAL_MAC, pl, 1'b1, cap, hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen);

      if (!hdr_seen) begin
        $error("T1 FAIL: hdr_valid never asserted"); fails++;
      end else $display("T1a PASS: hdr_valid asserted");

      if (drop_seen) begin
        $error("T1 FAIL: drop_o asserted for matching MAC"); fails++;
      end else $display("T1b PASS: drop_o=0 for matching MAC");

      if (cap.size() !== 5) begin
        $error("T1 FAIL: forwarded %0d bytes, want 5", cap.size()); fails++;
      end else $display("T1c PASS: 5 payload bytes forwarded");

      if (!tlast_seen) begin
        $error("T1 FAIL: tlast never asserted"); fails++;
      end else $display("T1d PASS: tlast asserted");

      for (int i = 0; i < 5 && i < cap.size(); i++) begin
        if (cap[i] !== 8'(8'hA0 + i)) begin
          $error("T1 FAIL: payload[%0d]=0x%02X want 0x%02X", i, cap[i], 8'hA0+i);
          fails++;
        end
      end
      if (fails == 0) $display("T1e PASS: payload bytes match");

      if (!acc_seen) begin
        $error("T1 FAIL: hdr_accept_pulse never fired"); fails++;
      end else $display("T1f PASS: hdr_accept_pulse fired");

      if (drp_seen) begin
        $error("T1 FAIL: hdr_drop_pulse fired for matching MAC"); fails++;
      end else $display("T1g PASS: hdr_drop_pulse=0 for matching MAC");
    end

    clk_wait(4);

    // ===== T2: broadcast dst_mac — forwarded =====
    begin
      logic [7:0]  pl[$], cap[$];
      logic        hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen;

      pl.push_back(8'hBB);
      send_frame(BCAST_MAC, pl, 1'b1, cap, hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen);

      if (drop_seen) begin
        $error("T2 FAIL: drop_o asserted for broadcast"); fails++;
      end else $display("T2a PASS: broadcast forwarded (drop_o=0)");

      if (cap.size() !== 1) begin
        $error("T2 FAIL: %0d bytes forwarded, want 1", cap.size()); fails++;
      end else $display("T2b PASS: broadcast payload forwarded");
    end

    clk_wait(4);

    // ===== T3: mismatched dst_mac — dropped, downstream not stalled =====
    begin
      logic [7:0]  pl[$], cap[$];
      logic        hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen;

      for (int i = 0; i < 5; i++) pl.push_back(8'(8'hC0 + i));

      // m_tready=0 to verify ST_DROP doesn't stall
      send_frame(OTHER_MAC, pl, 1'b0, cap, hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen);

      if (!drop_seen) begin
        $error("T3 FAIL: drop_o never asserted for mismatch MAC"); fails++;
      end else $display("T3a PASS: drop_o=1 for mismatched MAC");

      if (cap.size() !== 0) begin
        $error("T3 FAIL: %0d bytes forwarded, want 0", cap.size()); fails++;
      end else $display("T3b PASS: 0 bytes forwarded (frame dropped)");

      // Verify FSM is back in ST_HEADER (hdr_valid=0, drop=0)
      clk_wait(2);
      if (hdr_valid || drop) begin
        $error("T3 FAIL: FSM stuck after drop (hdr_valid=%0b drop=%0b)", hdr_valid, drop);
        fails++;
      end else $display("T3c PASS: FSM reset after drop");

      if (!drp_seen) begin
        $error("T3 FAIL: hdr_drop_pulse never fired for mismatch MAC"); fails++;
      end else $display("T3d PASS: hdr_drop_pulse fired for mismatch MAC");

      if (acc_seen) begin
        $error("T3 FAIL: hdr_accept_pulse fired for mismatch MAC"); fails++;
      end else $display("T3e PASS: hdr_accept_pulse=0 for mismatch MAC");
    end

    clk_wait(4);

    // ===== T4: short frame (tlast at byte 5, < 14) — FSM resets cleanly =====
    begin
      logic [7:0] raw[$];
      // Partial header: only 6 bytes with tlast on last one
      raw.push_back(8'hDE); raw.push_back(8'hAD); raw.push_back(8'hBE);
      raw.push_back(8'hEF); raw.push_back(8'h00); raw.push_back(8'h01);

      send_raw(raw, 5); // tlast on index 5

      // After reset, send a valid frame and verify it parses correctly
      begin
        logic [7:0]  pl[$], cap[$];
        logic        hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen;

        pl.push_back(8'hD1);
        send_frame(LOCAL_MAC, pl, 1'b1, cap, hdr_seen, drop_seen, tlast_seen, acc_seen, drp_seen);

        if (!hdr_seen || drop_seen || cap.size() !== 1) begin
          $error("T4 FAIL: frame after short-frame not parsed correctly (hdr=%0b drop=%0b cap=%0d)",
                 hdr_seen, drop_seen, cap.size());
          fails++;
        end else $display("T4  PASS: FSM reset after short frame, next frame parsed OK");
      end
    end

    clk_wait(4);

    // ===== T5: back-to-back frames — both parsed correctly =====
    begin
      logic [7:0] pl1[$], pl2[$], cap1[$], cap2[$];
      logic hdr1, drop1, tlast1, acc1, drp1;
      logic hdr2, drop2, tlast2, acc2, drp2;

      pl1.push_back(8'hE1); pl1.push_back(8'hE2);
      pl2.push_back(8'hF1); pl2.push_back(8'hF2); pl2.push_back(8'hF3);

      send_frame(LOCAL_MAC, pl1, 1'b1, cap1, hdr1, drop1, tlast1, acc1, drp1);
      send_frame(LOCAL_MAC, pl2, 1'b1, cap2, hdr2, drop2, tlast2, acc2, drp2);

      if (cap1.size() !== 2 || cap2.size() !== 3) begin
        $error("T5 FAIL: back-to-back byte counts cap1=%0d (want 2), cap2=%0d (want 3)",
               cap1.size(), cap2.size());
        fails++;
      end else $display("T5  PASS: back-to-back frames parsed (2+3 bytes)");
    end

    if (fails == 0) $display("tb_eth_header_parser: ALL PASS");
    else            $fatal(1, "tb_eth_header_parser: %0d FAILURES", fails);
    $finish;
  end

endmodule
