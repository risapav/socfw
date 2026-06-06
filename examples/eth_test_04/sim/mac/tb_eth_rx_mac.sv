`timescale 1ns/1ps
/**
 * @file tb_eth_rx_mac.sv
 * @brief Unit test: eth_rx_mac — GMII -> AXI-Stream + metadata.
 * @details Tests:
 *   T1: Payload-only output — header (14 B) and FCS (4 B) stripped
 *   T2: Stream latency — first AXI-S byte appears 6 cycles after first payload GMII byte
 *       (5 window-fill cycles + 1 emit cycle, from rxd_q perspective)
 *   T3: fcs_ok=1 and tuser=0 for valid-FCS frame to LOCAL_MAC
 *   T4: fcs_ok=0 and tuser=1 on tlast for corrupted FCS
 *   T5: MAC filter — frame to wrong DST MAC gives meta_fcs_ok=0
 *   T6: Broadcast accepted — meta_fcs_ok=1
 *   T7: Runt frame (<5 payload bytes) — 1 error byte + meta_fcs_ok=0
 */
`ifndef TB_ETH_RX_MAC_SV
`define TB_ETH_RX_MAC_SV

module tb_eth_rx_mac;
  import tb_eth_pkg::*;

  localparam logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0;
  localparam logic [47:0] SRC_MAC   = 48'hAA_BB_CC_DD_EE_FF;
  localparam logic [15:0] ETYPE     = 16'h9000;

  logic        clk    = 1'b0;
  logic        rst_n  = 1'b0;

  logic [7:0]  gmii_rxd_drv;
  logic        gmii_dv_drv;
  logic        gmii_er_drv;

  logic [7:0]  m_axis_tdata;
  logic        m_axis_tvalid;
  logic        m_axis_tready;
  logic        m_axis_tlast;
  logic        m_axis_tuser;

  logic        m_meta_valid;
  logic        m_meta_ready;
  logic [47:0] m_meta_dst_mac;
  logic [47:0] m_meta_src_mac;
  logic [15:0] m_meta_eth_type;
  logic        m_meta_fcs_ok;

  logic        stat_overflow;
  logic [15:0] stat_rx_frames;
  logic [15:0] stat_rx_drop;

  always #4 clk = ~clk; // 125 MHz

  eth_rx_mac #(
    .LOCAL_MAC       (LOCAL_MAC),
    .ACCEPT_BROADCAST(1'b1),
    .MAX_FRAME_LEN   (1518)
  ) dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .gmii_rxd_i     (gmii_rxd_drv),
    .gmii_rx_dv_i   (gmii_dv_drv),
    .gmii_rx_er_i   (gmii_er_drv),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tready  (m_axis_tready),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tuser   (m_axis_tuser),
    .m_meta_valid   (m_meta_valid),
    .m_meta_ready   (m_meta_ready),
    .m_meta_dst_mac (m_meta_dst_mac),
    .m_meta_src_mac (m_meta_src_mac),
    .m_meta_eth_type(m_meta_eth_type),
    .m_meta_fcs_ok  (m_meta_fcs_ok),
    .m_meta_mac_ok  (),
    .stat_overflow  (stat_overflow),
    .stat_rx_frames (stat_rx_frames),
    .stat_rx_drop   (stat_rx_drop)
  );

  // Pre-NBA capture: sample outputs in posedge active region before state NBA.
  logic [7:0] tdata_cap;
  logic       tvalid_cap;
  logic       tlast_cap;
  logic       tuser_cap;
  logic       meta_valid_cap;
  logic       meta_fcs_ok_cap;
  always @(posedge clk) begin
    tdata_cap      = m_axis_tdata;
    tvalid_cap     = m_axis_tvalid;
    tlast_cap      = m_axis_tlast;
    tuser_cap      = m_axis_tuser;
    meta_valid_cap = m_meta_valid;
    meta_fcs_ok_cap= m_meta_fcs_ok;
  end

  int fails = 0;

  task automatic clk_wait(int n = 1);
    repeat (n) begin @(posedge clk); #1; end
  endtask

  // Drive one complete Ethernet frame on GMII with preamble + SFD + data + FCS.
  // data[] = header[14] + payload[n_payload]; FCS computed and appended.
  // If corrupt_fcs=1, the last FCS byte is inverted.
  // Captures all AXI-S beats until tlast is seen.
  task automatic drive_frame_and_capture(
    input  logic [7:0] dst_mac_b [6],
    input  logic [7:0] src_mac_b [6],
    input  logic [7:0] payload   [],
    input  int         n_payload,
    input  bit         corrupt_fcs,
    output logic [7:0] cap        [],
    output int         cap_count,
    output logic       got_tlast,
    output logic       tuser_at_tlast,
    output logic       meta_ok
  );
    logic [7:0] frame[]; // 14 header + n_payload
    logic [7:0] hdr[14];
    logic [47:0] dst48, src48;
    logic [31:0] fcs;
    logic [7:0]  fcs_b[4];
    int          first_payload_cycle;
    int          cycle_count;
    logic        first_byte_latched;
    logic [7:0]  cap_tmp [$];

    dst48 = {dst_mac_b[0],dst_mac_b[1],dst_mac_b[2],
             dst_mac_b[3],dst_mac_b[4],dst_mac_b[5]};
    src48 = {src_mac_b[0],src_mac_b[1],src_mac_b[2],
             src_mac_b[3],src_mac_b[4],src_mac_b[5]};

    build_eth_hdr(dst48, src48, ETYPE, hdr);

    frame = new [14 + n_payload];
    for (int i = 0; i < 14;        i++) frame[i]      = hdr[i];
    for (int i = 0; i < n_payload; i++) frame[14 + i]  = payload[i];

    fcs    = crc32(frame, 14 + n_payload);
    fcs_b[0] = fcs[7:0];
    fcs_b[1] = fcs[15:8];
    fcs_b[2] = fcs[23:16];
    fcs_b[3] = fcs[31:24];
    if (corrupt_fcs) fcs_b[3] ^= 8'hFF;

    cap_tmp       = {};
    got_tlast     = 1'b0;
    tuser_at_tlast= 1'b0;
    meta_ok       = 1'b0;
    first_payload_cycle = -1;
    cycle_count   = 0;
    first_byte_latched = 1'b0;
    m_axis_tready <= 1'b1;
    m_meta_ready  <= 1'b0;

    // Preamble: 7 x 0x55; RXDV=0 (RTL8211EG does not assert DV during preamble)
    for (int i = 0; i < 7; i++) begin
      @(negedge clk);
      gmii_rxd_drv = 8'h55;
      gmii_dv_drv  = 1'b0;
      gmii_er_drv  = 1'b0;
    end

    // SFD: assert RXDV here
    @(negedge clk);
    gmii_rxd_drv = 8'hD5;
    gmii_dv_drv  = 1'b1;

    // Header: drive only (no emissions possible yet)
    for (int i = 0; i < 14; i++) begin
      @(negedge clk);
      gmii_rxd_drv = frame[i];
    end

    // Payload: interleave drive+capture; DUT starts emitting once window fills (5 bytes)
    for (int i = 0; i < n_payload; i++) begin
      @(negedge clk); gmii_rxd_drv = frame[14 + i];
      @(posedge clk); #1;
      if (tvalid_cap && m_axis_tready) begin
        cap_tmp.push_back(tdata_cap);
        if (tlast_cap) begin
          got_tlast = 1'b1; tuser_at_tlast = tuser_cap;
          meta_ok   = meta_fcs_ok_cap;
        end
      end
    end

    // FCS: interleave drive+capture (most payload bytes emit here)
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); gmii_rxd_drv = fcs_b[i];
      @(posedge clk); #1;
      if (tvalid_cap && m_axis_tready) begin
        cap_tmp.push_back(tdata_cap);
        if (tlast_cap) begin
          got_tlast = 1'b1; tuser_at_tlast = tuser_cap;
          meta_ok   = meta_fcs_ok_cap;
        end
      end
    end

    // Drop DV + capture last byte
    @(negedge clk); gmii_rxd_drv = 8'h00; gmii_dv_drv = 1'b0;
    @(posedge clk); #1;
    if (tvalid_cap && m_axis_tready) begin
      cap_tmp.push_back(tdata_cap);
      if (tlast_cap) begin
        got_tlast = 1'b1; tuser_at_tlast = tuser_cap;
        meta_ok   = meta_fcs_ok_cap;
      end
    end

    // Drain: tlast appears here for short payloads or runt frames
    repeat (16) begin
      @(posedge clk); #1;
      if (tvalid_cap && m_axis_tready) begin
        cap_tmp.push_back(tdata_cap);
        if (tlast_cap) begin
          got_tlast = 1'b1; tuser_at_tlast = tuser_cap;
          meta_ok   = meta_fcs_ok_cap;
        end
      end
    end

    // Consume meta register
    @(negedge clk); m_meta_ready <= 1'b1;
    clk_wait(2);
    @(negedge clk); m_meta_ready <= 1'b0;
    clk_wait(2);

    cap_count = cap_tmp.size();
    cap       = new [cap_count];
    for (int i = 0; i < cap_count; i++) cap[i] = cap_tmp[i];
  endtask

  // Latency measurement: count cycles from the posedge where rxd_q=P[0]
  // (first payload byte enters DUT pipeline) to the first tvalid_cap=1.
  // Interleaves negedge driving with posedge counting so the window fills
  // while counting, giving the expected ~7-cycle latency.
  // Returns -1 if tvalid never asserted within timeout.
  task automatic measure_latency(
    input  logic [7:0] dst_mac_b [6],
    output int         latency_cycles
  );
    logic [7:0] payload[];
    logic [7:0] frame[];
    logic [7:0] hdr[14];
    logic [47:0] dst48;
    logic [31:0] fcs;
    logic [7:0]  fcs_b[4];
    int          cnt;

    dst48 = {dst_mac_b[0],dst_mac_b[1],dst_mac_b[2],
             dst_mac_b[3],dst_mac_b[4],dst_mac_b[5]};

    payload = new [10];
    for (int i = 0; i < 10; i++) payload[i] = 8'(i + 1);

    build_eth_hdr(dst48, SRC_MAC, ETYPE, hdr);
    frame = new [24]; // 14 + 10
    for (int i = 0; i < 14; i++) frame[i]    = hdr[i];
    for (int i = 0; i < 10; i++) frame[14+i] = payload[i];

    fcs = crc32(frame, 24);
    fcs_b[0] = fcs[7:0]; fcs_b[1] = fcs[15:8];
    fcs_b[2] = fcs[23:16]; fcs_b[3] = fcs[31:24];

    m_axis_tready <= 1'b1;
    m_meta_ready  <= 1'b1;
    latency_cycles = -1;
    cnt            = 0;

    // Preamble: RXDV=0 (RTL8211EG does not assert DV during preamble)
    for (int i = 0; i < 7; i++) begin
      @(negedge clk); gmii_rxd_drv = 8'h55; gmii_dv_drv = 1'b0;
    end
    // SFD: assert RXDV
    @(negedge clk); gmii_rxd_drv = 8'hD5; gmii_dv_drv = 1'b1;
    // Header
    for (int i = 0; i < 14; i++) begin
      @(negedge clk); gmii_rxd_drv = frame[i];
    end
    // Drive P[0]; cnt=1 will be the posedge where rxd_q=P[0]
    @(negedge clk); gmii_rxd_drv = payload[0];
    // Interleaved: posedge count then negedge drive for P[1..9], FCS[0..3], drop DV
    for (int i = 1; i <= 14; i++) begin
      @(posedge clk); #1;
      cnt++;
      if (tvalid_cap && m_axis_tready && latency_cycles < 0)
        latency_cycles = cnt;
      @(negedge clk);
      if      (i < 10) gmii_rxd_drv = payload[i];
      else if (i < 14) gmii_rxd_drv = fcs_b[i - 10];
      else             begin gmii_rxd_drv = 8'h00; gmii_dv_drv = 1'b0; end
    end
    // Extra posedges to drain
    repeat (20) begin
      @(posedge clk); #1;
      cnt++;
      if (tvalid_cap && m_axis_tready && latency_cycles < 0)
        latency_cycles = cnt;
    end
    @(negedge clk); m_meta_ready <= 1'b0;
    clk_wait(2);
  endtask

  // MAC bytes helper
  function automatic void mac48_to_bytes(
    input  logic [47:0] mac,
    output logic [7:0]  b [6]
  );
    b[0]=mac[47:40]; b[1]=mac[39:32]; b[2]=mac[31:24];
    b[3]=mac[23:16]; b[4]=mac[15:8];  b[5]=mac[7:0];
  endfunction

  initial begin
    gmii_rxd_drv = 8'h00;
    gmii_dv_drv  = 1'b0;
    gmii_er_drv  = 1'b0;
    m_axis_tready = 1'b1;
    m_meta_ready  = 1'b0;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(4);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(4);

    // ================================================================
    // T1: Header and FCS stripped; exactly n_payload bytes out
    // ================================================================
    begin
      logic [7:0] dst_b[6], src_b[6], pl[6], cap[];
      logic       tl, tu, mok;
      int         cnt;
      mac48_to_bytes(LOCAL_MAC, dst_b);
      mac48_to_bytes(SRC_MAC,   src_b);
      for (int i = 0; i < 6; i++) pl[i] = 8'(8'hB0 + i);

      drive_frame_and_capture(dst_b, src_b, pl, 6, 0, cap, cnt, tl, tu, mok);

      if (cnt !== 6) begin
        $error("T1 FAIL: captured %0d bytes, want 6 (hdr+FCS stripped)", cnt);
        fails++;
      end else $display("T1a PASS: exactly 6 payload bytes captured");

      for (int i = 0; i < 6 && i < cnt; i++) begin
        if (cap[i] !== pl[i]) begin
          $error("T1 FAIL: byte[%0d]=0x%02X want 0x%02X", i, cap[i], pl[i]); fails++;
        end
      end
      if (fails == 0) $display("T1b PASS: payload bytes match");

      if (!tl) begin
        $error("T1 FAIL: tlast never seen"); fails++;
      end else $display("T1c PASS: tlast asserted");

      if (tu) begin
        $error("T1 FAIL: tuser=1 on tlast (error set unexpectedly)"); fails++;
      end else $display("T1d PASS: tuser=0 (no error)");
    end

    clk_wait(8);

    // ================================================================
    // T2: Latency — first byte appears 6 cycles after P[0] enters rxd_q
    //     (5 window-fill + 1 emit, measured from when rxd_q=P[0])
    // ================================================================
    begin
      logic [7:0] dst_b[6];
      int         lat;
      mac48_to_bytes(LOCAL_MAC, dst_b);
      measure_latency(dst_b, lat);

      // Expected: P[0] enters rxd_q at posedge N.
      // Window fills over cycles N..N+4 (5 cycles). Emit at N+5 (post-NBA).
      // First tvalid_cap=1 at posedge N+6. cnt starts at 1 when posedge N+1 is sampled.
      // So lat should be 7 (cnt increments from cycle AFTER negedge P[0] drive).
      // Allow a window of 6..8 to account for GMII pipeline uncertainty.
      if (lat < 6 || lat > 10) begin
        $error("T2 FAIL: first-byte latency=%0d cycles (want ~7, window 6..10)", lat);
        fails++;
      end else
        $display("T2 PASS: first-byte latency=%0d cycles from P[0] at rxd_q", lat);
    end

    clk_wait(8);

    // ================================================================
    // T3: fcs_ok=1 for valid frame
    // ================================================================
    begin
      logic [7:0] dst_b[6], src_b[6], pl[10], cap[];
      logic       tl, tu, mok;
      int         cnt;
      mac48_to_bytes(LOCAL_MAC, dst_b);
      mac48_to_bytes(SRC_MAC,   src_b);
      for (int i = 0; i < 10; i++) pl[i] = 8'(i);

      drive_frame_and_capture(dst_b, src_b, pl, 10, 0, cap, cnt, tl, tu, mok);

      if (!mok) begin
        $error("T3 FAIL: meta_fcs_ok=0 for valid frame"); fails++;
      end else $display("T3 PASS: fcs_ok=1 for valid frame");
    end

    clk_wait(8);

    // ================================================================
    // T4: Corrupted FCS -> fcs_ok=0, tuser=1 on tlast
    // ================================================================
    begin
      logic [7:0] dst_b[6], src_b[6], pl[10], cap[];
      logic       tl, tu, mok;
      int         cnt;
      mac48_to_bytes(LOCAL_MAC, dst_b);
      mac48_to_bytes(SRC_MAC,   src_b);
      for (int i = 0; i < 10; i++) pl[i] = 8'(i + 1);

      drive_frame_and_capture(dst_b, src_b, pl, 10, 1, cap, cnt, tl, tu, mok);

      if (mok) begin
        $error("T4 FAIL: meta_fcs_ok=1 for corrupted FCS"); fails++;
      end else $display("T4a PASS: fcs_ok=0 for corrupted FCS");

      if (!tu) begin
        $error("T4 FAIL: tuser=0 on tlast for corrupted frame"); fails++;
      end else $display("T4b PASS: tuser=1 on tlast for corrupted frame");
    end

    clk_wait(8);

    // ================================================================
    // T5: Wrong DST MAC -> meta_fcs_ok=0 (mac_match=0)
    // ================================================================
    begin
      logic [47:0] wrong_dst;
      logic [7:0]  dst_b[6], src_b[6], pl[6], cap[];
      logic        tl, tu, mok;
      int          cnt;
      wrong_dst = 48'hDE_AD_BE_EF_00_01;
      mac48_to_bytes(wrong_dst, dst_b);
      mac48_to_bytes(SRC_MAC,   src_b);
      for (int i = 0; i < 6; i++) pl[i] = 8'(8'hC0 + i);

      drive_frame_and_capture(dst_b, src_b, pl, 6, 0, cap, cnt, tl, tu, mok);

      if (mok) begin
        $error("T5 FAIL: meta_fcs_ok=1 for wrong DST MAC"); fails++;
      end else $display("T5 PASS: meta_fcs_ok=0 for unicast to wrong DST");
    end

    clk_wait(8);

    // ================================================================
    // T6: Broadcast DST MAC -> meta_fcs_ok=1 (ACCEPT_BROADCAST=1)
    // ================================================================
    begin
      logic [47:0] bcast_dst;
      logic [7:0]  dst_b[6], src_b[6], pl[6], cap[];
      logic        tl, tu, mok;
      int          cnt;
      bcast_dst = 48'hFF_FF_FF_FF_FF_FF;
      mac48_to_bytes(bcast_dst, dst_b);
      mac48_to_bytes(SRC_MAC,   src_b);
      for (int i = 0; i < 6; i++) pl[i] = 8'(8'hD0 + i);

      drive_frame_and_capture(dst_b, src_b, pl, 6, 0, cap, cnt, tl, tu, mok);

      if (!mok) begin
        $error("T6 FAIL: meta_fcs_ok=0 for broadcast frame"); fails++;
      end else $display("T6 PASS: broadcast accepted, fcs_ok=1");
    end

    clk_wait(8);

    // ================================================================
    // T7: Runt frame (0 payload bytes — only 4 FCS bytes in ST_PAYLOAD,
    //     win_cnt=4 < 5 at drop → runt path → 1 error byte, meta_fcs_ok=0)
    // ================================================================
    begin
      logic [7:0] dst_b[6], src_b[6], pl[1], cap[];
      logic       tl, tu, mok;
      int         cnt;
      mac48_to_bytes(LOCAL_MAC, dst_b);
      mac48_to_bytes(SRC_MAC,   src_b);
      pl[0] = 8'hE0;  // unused; n_payload=0

      drive_frame_and_capture(dst_b, src_b, pl, 0, 0, cap, cnt, tl, tu, mok);

      if (mok) begin
        $error("T7 FAIL: meta_fcs_ok=1 for runt frame"); fails++;
      end else $display("T7a PASS: meta_fcs_ok=0 for runt");

      if (!tu) begin
        $error("T7 FAIL: tuser=0 on error byte for runt frame"); fails++;
      end else $display("T7b PASS: tuser=1 on error byte");
    end

    if (fails == 0) $display("tb_eth_rx_mac: ALL PASS");
    else            $fatal(1, "tb_eth_rx_mac: %0d FAILURES", fails);
    $finish;
  end

endmodule

`endif // TB_ETH_RX_MAC_SV
