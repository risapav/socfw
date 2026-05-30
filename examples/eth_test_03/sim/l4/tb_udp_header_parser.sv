`timescale 1ns/1ps
/**
 * @file tb_udp_header_parser.sv
 * @brief Unit test for udp_header_parser module.
 * @details Tests:
 *   T1: Valid UDP dst_port=8080, payload "HELLO" + 4-byte trailing (padding+FCS sim)
 *       -> forwards only "HELLO" (5 bytes), m_axis_tlast on byte 5 not on s_axis_tlast
 *   T2: Wrong dst_port -> ST_DROP, 0 bytes forwarded
 *   T3: udp_len < 8 -> ST_DROP, 0 bytes forwarded
 *   T4: Short frame during header (< 8 bytes) -> FSM resets, next valid frame OK
 *   T5: Back-to-back valid frames -> both forwarded correctly
 *   T6: Zero payload (udp_len == 8) -> 0 bytes forwarded, frame consumed
 *   T7: DROP_NONZERO_CHECKSUM=0 (default) -> nonzero checksum accepted
 */

module tb_udp_header_parser;
  import tb_eth_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #4 clk = ~clk;

  logic [15:0] local_port;
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

  logic [15:0] src_port;
  logic [15:0] dst_port;
  logic [15:0] udp_len;
  logic [15:0] payload_len;
  logic        hdr_valid;
  logic        hdr_pre_valid;
  logic [15:0] src_port_pre, dst_port_pre, payload_len_pre;
  logic        drop;
  logic        csum_zero;
  logic        csum_unchecked;

  udp_header_parser #(.DROP_NONZERO_CHECKSUM(1'b0)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .local_port_i(local_port), .promiscuous_i(promisc),
    .s_axis_tdata(s_tdata),   .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
    .s_axis_tuser(s_tuser),
    .m_axis_tdata(m_tdata),   .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
    .m_axis_tuser(m_tuser),
    .src_port_o(src_port), .dst_port_o(dst_port),
    .udp_len_o(udp_len),   .payload_len_o(payload_len),
    .hdr_valid_o(hdr_valid), .hdr_pre_valid_o(hdr_pre_valid),
    .src_port_pre_o(src_port_pre), .dst_port_pre_o(dst_port_pre),
    .payload_len_pre_o(payload_len_pre),
    .drop_o(drop),
    .udp_checksum_zero_o(csum_zero),
    .udp_checksum_unchecked_o(csum_unchecked)
  );

  // Pre-NBA captures
  logic       m_tvalid_cap, m_tlast_cap, hdr_valid_cap, drop_cap;
  logic       csum_zero_pre, csum_unchecked_pre;
  logic [7:0] m_tdata_cap;
  always @(posedge clk) begin
    m_tvalid_cap       = m_tvalid;
    m_tlast_cap        = m_tlast;
    m_tdata_cap        = m_tdata;
    hdr_valid_cap      = hdr_valid;
    drop_cap           = drop;
    csum_zero_pre      = csum_zero;
    csum_unchecked_pre = csum_unchecked;
  end

  int fails = 0;

  localparam logic [15:0] LOCAL_PORT = 16'd8080;
  localparam logic [15:0] OTHER_PORT = 16'd9090;
  localparam logic [15:0] SRC_PORT   = 16'd1234;

  task automatic clk_wait(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  // Build 8-byte UDP header.
  function automatic void build_udp_hdr(
    input  logic [15:0] sp, dp, ulen, csum,
    output logic [7:0]  hdr[8]
  );
    hdr[0] = sp[15:8];   hdr[1] = sp[7:0];
    hdr[2] = dp[15:8];   hdr[3] = dp[7:0];
    hdr[4] = ulen[15:8]; hdr[5] = ulen[7:0];
    hdr[6] = csum[15:8]; hdr[7] = csum[7:0];
  endfunction

  // Send UDP frame: hdr(8) + payload + trailing(with tlast on last).
  // Captures m_axis output and fields at first hdr_valid_cap.
  task automatic send_frame(
    input  logic [7:0] hdr[8],
    input  logic [7:0] payload[$],
    input  logic [7:0] trailing[$],
    input  logic       m_tready_val,
    output logic [7:0] cap[$],
    output logic       hdr_valid_seen,
    output logic       drop_seen,
    output logic       tlast_seen,
    output logic [15:0] src_port_cap,
    output logic [15:0] dst_port_cap,
    output logic [15:0] udp_len_cap,
    output logic [15:0] payload_len_cap,
    output logic        csum_zero_cap,
    output logic        csum_unchecked_cap
  );
    int total;
    logic fields_taken;

    cap               = {};
    hdr_valid_seen    = 1'b0;
    drop_seen         = 1'b0;
    tlast_seen        = 1'b0;
    src_port_cap      = 16'd0;
    dst_port_cap      = 16'd0;
    udp_len_cap       = 16'd0;
    payload_len_cap   = 16'd0;
    csum_zero_cap     = 1'b0;
    csum_unchecked_cap = 1'b0;
    fields_taken      = 1'b0;
    total           = 8 + payload.size() + trailing.size();

    @(negedge clk); m_tready <= m_tready_val;

    for (int i = 0; i < total; i++) begin
      automatic int pi = i - 8;
      automatic int ti = i - 8 - int'(payload.size());
      automatic logic is_hdr     = (i < 8);
      automatic logic is_payload = (i >= 8) && (i < 8 + int'(payload.size()));
      automatic logic is_trail   = (i >= 8 + int'(payload.size()));
      automatic logic is_last    = (i == total - 1);
      @(negedge clk);
      s_tdata  <= is_hdr     ? hdr[i]         :
                  is_payload ? payload[pi]     :
                               trailing[ti];
      s_tvalid <= 1'b1;
      s_tlast  <= is_last ? 1'b1 : 1'b0;
      @(posedge clk); #1;
      if (hdr_valid_cap) hdr_valid_seen = 1'b1;
      if (drop_cap)      drop_seen      = 1'b1;
      if (hdr_valid_cap && !fields_taken) begin
        src_port_cap       = src_port;
        dst_port_cap       = dst_port;
        udp_len_cap        = udp_len;
        payload_len_cap    = payload_len;
        csum_zero_cap      = csum_zero_pre;
        csum_unchecked_cap = csum_unchecked_pre;
        fields_taken       = 1'b1;
      end
      if (m_tvalid_cap && m_tready) begin
        cap.push_back(m_tdata_cap);
        if (m_tlast_cap) tlast_seen = 1'b1;
      end
    end

    @(negedge clk); s_tvalid <= 1'b0; s_tlast <= 1'b0;
    repeat (3) begin
      @(posedge clk); #1;
      if (m_tvalid_cap && m_tready) begin
        cap.push_back(m_tdata_cap);
        if (m_tlast_cap) tlast_seen = 1'b1;
      end
    end
  endtask

  // Send raw bytes (short-frame test).
  task automatic send_raw(input logic [7:0] data[$], input int last_idx);
    for (int i = 0; i < data.size(); i++) begin
      @(negedge clk);
      s_tdata  <= data[i];
      s_tvalid <= 1'b1;
      s_tlast  <= (i == last_idx) ? 1'b1 : 1'b0;
      @(posedge clk); #1;
    end
    @(negedge clk); s_tvalid <= 1'b0; s_tlast <= 1'b0;
    clk_wait(3);
  endtask

  initial begin
    s_tdata  <= 8'h00;
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
    s_tuser  <= 1'b0;
    m_tready <= 1'b1;
    local_port <= LOCAL_PORT;
    promisc    <= 1'b0;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(3);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(2);

    // ===== T1: Valid UDP, "HELLO" payload + 4-byte trailing =====
    // udp_len = 13 (8 hdr + 5 payload), trailing simulates Ethernet padding/FCS
    begin
      logic [7:0]  hdr[8], pl[$], trail[$], cap[$];
      logic        hv, dv, tlast, cz, cu;
      logic [15:0] sp, dp, ul, pll;

      build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd13, 16'h0000, hdr);
      pl.push_back(8'h48); pl.push_back(8'h45); // H E
      pl.push_back(8'h4C); pl.push_back(8'h4C); // L L
      pl.push_back(8'h4F);                       // O
      trail.push_back(8'hAA); trail.push_back(8'hBB);
      trail.push_back(8'hCC); trail.push_back(8'hDD); // fake FCS

      send_frame(hdr, pl, trail, 1'b1, cap, hv, dv, tlast, sp, dp, ul, pll, cz, cu);

      if (!hv) begin
        $error("T1 FAIL: hdr_valid never asserted"); fails++;
      end else $display("T1a PASS: hdr_valid asserted");

      if (cap.size() !== 5) begin
        $error("T1 FAIL: %0d bytes captured, want 5", cap.size()); fails++;
      end else $display("T1b PASS: 5 payload bytes forwarded (padding+FCS discarded)");

      if (!tlast) begin
        $error("T1 FAIL: m_axis_tlast never asserted"); fails++;
      end else $display("T1c PASS: m_axis_tlast on last UDP payload byte");

      for (int i = 0; i < 5 && i < int'(cap.size()); i++) begin
        if (cap[i] !== pl[i]) begin
          $error("T1 FAIL: payload[%0d]=0x%02X want 0x%02X", i, cap[i], pl[i]);
          fails++;
        end
      end
      if (fails == 0) $display("T1d PASS: payload bytes HELLO correct");

      if (sp !== SRC_PORT) begin
        $error("T1 FAIL: src_port=0x%04X want 0x%04X", sp, SRC_PORT); fails++;
      end else $display("T1e PASS: src_port=0x%04X correct", sp);

      if (dp !== LOCAL_PORT) begin
        $error("T1 FAIL: dst_port=0x%04X want 0x%04X", dp, LOCAL_PORT); fails++;
      end else $display("T1f PASS: dst_port=0x%04X correct", dp);

      if (ul !== 16'd13) begin
        $error("T1 FAIL: udp_len=%0d want 13", ul); fails++;
      end else $display("T1g PASS: udp_len=13");

      if (pll !== 16'd5) begin
        $error("T1 FAIL: payload_len=%0d want 5", pll); fails++;
      end else $display("T1h PASS: payload_len=5");
    end

    clk_wait(4);

    // ===== T2: Wrong dst_port — ST_DROP =====
    begin
      logic [7:0]  hdr[8], pl[$], trail[$], cap[$];
      logic        hv, dv, tlast, cz, cu;
      logic [15:0] sp, dp, ul, pll;

      build_udp_hdr(SRC_PORT, OTHER_PORT, 16'd12, 16'h0000, hdr);
      for (int i = 0; i < 4; i++) pl.push_back(8'(i));
      trail.push_back(8'hFF);

      send_frame(hdr, pl, trail, 1'b1, cap, hv, dv, tlast, sp, dp, ul, pll, cz, cu);

      if (hv) begin
        $error("T2 FAIL: hdr_valid asserted for wrong dst_port"); fails++;
      end else $display("T2a PASS: hdr_valid=0 for wrong dst_port");

      if (!dv) begin
        $error("T2 FAIL: drop_o never asserted for wrong dst_port"); fails++;
      end else $display("T2b PASS: drop_o asserted");

      if (cap.size() !== 0) begin
        $error("T2 FAIL: %0d bytes forwarded, want 0", cap.size()); fails++;
      end else $display("T2c PASS: 0 bytes forwarded");
    end

    clk_wait(4);

    // ===== T3: udp_len < 8 — ST_DROP =====
    begin
      logic [7:0]  hdr[8], pl[$], trail[$], cap[$];
      logic        hv, dv, tlast, cz, cu;
      logic [15:0] sp, dp, ul, pll;

      build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd7, 16'h0000, hdr); // len=7 < 8
      pl.push_back(8'hDE); pl.push_back(8'hAD);
      trail.push_back(8'hFF);

      send_frame(hdr, pl, trail, 1'b1, cap, hv, dv, tlast, sp, dp, ul, pll, cz, cu);

      if (hv) begin
        $error("T3 FAIL: hdr_valid asserted for udp_len=7"); fails++;
      end else $display("T3a PASS: udp_len=7 frame dropped");

      if (!dv) begin
        $error("T3 FAIL: drop_o never asserted for udp_len=7"); fails++;
      end else $display("T3b PASS: drop_o asserted");

      if (cap.size() !== 0) begin
        $error("T3 FAIL: %0d bytes forwarded, want 0", cap.size()); fails++;
      end else $display("T3c PASS: 0 bytes forwarded");
    end

    clk_wait(4);

    // ===== T4: Short frame during header (< 8 bytes), then valid frame =====
    begin
      logic [7:0] raw[$];
      for (int i = 0; i < 5; i++) raw.push_back(8'(i)); // only 5 bytes
      send_raw(raw, 4); // tlast on byte 4

      begin
        logic [7:0]  hdr[8], pl[$], trail[$], cap[$];
        logic        hv, dv, tlast, cz, cu;
        logic [15:0] sp, dp, ul, pll;

        build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd9, 16'h0000, hdr); // 1-byte payload
        pl.push_back(8'hD5);
        trail.push_back(8'hFF);

        send_frame(hdr, pl, trail, 1'b1, cap, hv, dv, tlast, sp, dp, ul, pll, cz, cu);

        if (!hv || cap.size() !== 1) begin
          $error("T4 FAIL: after short header, next frame not forwarded (hv=%0b cap=%0d)",
                 hv, cap.size());
          fails++;
        end else $display("T4  PASS: FSM reset after short header, next frame OK");
      end
    end

    clk_wait(4);

    // ===== T5: Back-to-back valid frames =====
    begin
      logic [7:0]  hdr1[8], hdr2[8];
      logic [7:0]  pl1[$], pl2[$], trail1[$], trail2[$];
      logic [7:0]  cap1[$], cap2[$];
      logic        hv1, dv1, tl1, cz1, cu1, hv2, dv2, tl2, cz2, cu2;
      logic [15:0] sp1, dp1, ul1, pll1, sp2, dp2, ul2, pll2;

      build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd10, 16'h0000, hdr1); // 2-byte payload
      build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd11, 16'h0000, hdr2); // 3-byte payload
      pl1.push_back(8'hE1); pl1.push_back(8'hE2);
      pl2.push_back(8'hF1); pl2.push_back(8'hF2); pl2.push_back(8'hF3);
      trail1.push_back(8'hFF);
      trail2.push_back(8'hFF);

      send_frame(hdr1, pl1, trail1, 1'b1, cap1, hv1, dv1, tl1, sp1, dp1, ul1, pll1, cz1, cu1);
      send_frame(hdr2, pl2, trail2, 1'b1, cap2, hv2, dv2, tl2, sp2, dp2, ul2, pll2, cz2, cu2);

      if (cap1.size() !== 2 || cap2.size() !== 3) begin
        $error("T5 FAIL: back-to-back cap1=%0d (want 2), cap2=%0d (want 3)",
               cap1.size(), cap2.size());
        fails++;
      end else $display("T5  PASS: back-to-back frames (2+3 bytes)");
    end

    clk_wait(4);

    // ===== T6: Zero payload (udp_len == 8) — no bytes forwarded, frame consumed =====
    begin
      logic [7:0]  hdr[8], pl[$], trail[$], cap[$];
      logic        hv, dv, tlast, cz, cu;
      logic [15:0] sp, dp, ul, pll;

      build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd8, 16'h0000, hdr);
      // no payload
      trail.push_back(8'hAA); trail.push_back(8'hBB); // some trailing bytes

      send_frame(hdr, pl, trail, 1'b1, cap, hv, dv, tlast, sp, dp, ul, pll, cz, cu);

      if (dv) begin
        $error("T6 FAIL: drop_o asserted for valid zero-payload frame"); fails++;
      end else $display("T6a PASS: zero-payload frame not dropped");

      if (cap.size() !== 0) begin
        $error("T6 FAIL: %0d bytes captured, want 0", cap.size()); fails++;
      end else $display("T6b PASS: 0 bytes forwarded for zero-payload");

      // Verify FSM recovered: send a valid frame after
      begin
        logic [7:0]  hdr2[8], pl2[$], tr2[$], cap2[$];
        logic        hv2, dv2, tl2, cz2, cu2;
        logic [15:0] sp2, dp2, ul2, pll2;

        build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd9, 16'h0000, hdr2);
        pl2.push_back(8'hCC);
        tr2.push_back(8'hDD);

        send_frame(hdr2, pl2, tr2, 1'b1, cap2, hv2, dv2, tl2, sp2, dp2, ul2, pll2, cz2, cu2);

        if (!hv2 || cap2.size() !== 1) begin
          $error("T6 FAIL: after zero-payload, next frame not forwarded (hv=%0b cap=%0d)",
                 hv2, cap2.size());
          fails++;
        end else $display("T6c PASS: FSM OK after zero-payload, next frame forwarded");
      end
    end

    clk_wait(4);

    // ===== T7: Nonzero checksum accepted (DROP_NONZERO_CHECKSUM=0) =====
    begin
      logic [7:0]  hdr[8], pl[$], trail[$], cap[$];
      logic        hv, dv, tlast, cz, cu;
      logic [15:0] sp, dp, ul, pll;

      build_udp_hdr(SRC_PORT, LOCAL_PORT, 16'd9, 16'hBEEF, hdr); // nonzero checksum
      pl.push_back(8'hAB);
      trail.push_back(8'hFF);

      send_frame(hdr, pl, trail, 1'b1, cap, hv, dv, tlast, sp, dp, ul, pll, cz, cu);

      if (!hv || cap.size() !== 1) begin
        $error("T7 FAIL: nonzero checksum rejected with DROP_NONZERO_CHECKSUM=0"); fails++;
      end else $display("T7a PASS: nonzero checksum accepted (DROP_NONZERO_CHECKSUM=0)");

      if (!cu) begin
        $error("T7 FAIL: udp_checksum_unchecked_o not set"); fails++;
      end else $display("T7b PASS: udp_checksum_unchecked_o=1 for nonzero checksum");
    end

    if (fails == 0) $display("tb_udp_header_parser: ALL PASS");
    else            $fatal(1, "tb_udp_header_parser: %0d FAILURES", fails);
    $finish;
  end

endmodule
