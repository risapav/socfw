`timescale 1ns/1ps
/**
 * @file tb_ipv4_header_parser.sv
 * @brief Unit test for ipv4_header_parser module.
 * @details Tests:
 *   T1: Valid IPv4/UDP to local_ip — payload forwarded, hdr_valid=1, fields correct
 *   T2: Wrong dst_ip — ST_DROP, 0 bytes forwarded, hdr_valid=0
 *   T3: Wrong protocol (TCP=0x06) — ST_DROP, 0 bytes forwarded
 *   T4: Wrong version/IHL (0x46) — ST_DROP, 0 bytes forwarded
 *   T5: Short frame (< 20 bytes) — FSM resets cleanly, next valid frame forwarded
 *   T6: Back-to-back valid frames — both forwarded correctly
 */

module tb_ipv4_header_parser;
  import tb_eth_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #4 clk = ~clk;

  logic [31:0] local_ip;

  logic [7:0]  s_tdata;
  logic        s_tvalid;
  logic        s_tready;
  logic        s_tlast;

  logic [7:0]  m_tdata;
  logic        m_tvalid;
  logic        m_tready;
  logic        m_tlast;

  logic [31:0] src_ip;
  logic [31:0] dst_ip;
  logic [7:0]  proto;
  logic        hdr_valid;

  ipv4_header_parser dut (
    .clk_i(clk), .rst_ni(rst_n),
    .local_ip_i(local_ip),
    .s_axis_tdata(s_tdata),   .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
    .m_axis_tdata(m_tdata),   .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
    .src_ip_o(src_ip), .dst_ip_o(dst_ip),
    .protocol_o(proto), .hdr_valid_o(hdr_valid)
  );

  // Pre-NBA captures
  logic       m_tvalid_cap, m_tlast_cap, hdr_valid_cap;
  logic [7:0] m_tdata_cap;
  always @(posedge clk) begin
    m_tvalid_cap  = m_tvalid;
    m_tlast_cap   = m_tlast;
    m_tdata_cap   = m_tdata;
    hdr_valid_cap = hdr_valid;
  end

  int fails = 0;

  localparam logic [31:0] LOCAL_IP = 32'hC0A8_0101; // 192.168.1.1
  localparam logic [31:0] SRC_IP   = 32'hC0A8_0102; // 192.168.1.2
  localparam logic [31:0] OTHER_IP = 32'hC0A8_0103; // 192.168.1.3

  task automatic clk_wait(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  // Build minimal 20-byte IPv4 header (no options).
  function automatic void build_ipv4_hdr(
    input  logic [7:0]  ver_ihl,
    input  logic [7:0]  proto_f,
    input  logic [31:0] sip,
    input  logic [31:0] dip,
    output logic [7:0]  hdr[20]
  );
    hdr[ 0] = ver_ihl;
    hdr[ 1] = 8'h00;
    hdr[ 2] = 8'h00; hdr[ 3] = 8'h28;
    hdr[ 4] = 8'h00; hdr[ 5] = 8'h01;
    hdr[ 6] = 8'h00; hdr[ 7] = 8'h00;
    hdr[ 8] = 8'h40;
    hdr[ 9] = proto_f;
    hdr[10] = 8'h00; hdr[11] = 8'h00;
    hdr[12] = sip[31:24]; hdr[13] = sip[23:16];
    hdr[14] = sip[15:8];  hdr[15] = sip[7:0];
    hdr[16] = dip[31:24]; hdr[17] = dip[23:16];
    hdr[18] = dip[15:8];  hdr[19] = dip[7:0];
  endfunction

  // Send header + payload; capture m_axis output and parsed field values.
  // One byte per clock; m_tready held at m_tready_val throughout.
  // In ST_HEADER and ST_DROP: s_axis_tready=1 always, so no stalls.
  // In ST_PAYLOAD with m_tready=1: s_axis_tready=1, no stalls.
  task automatic send_frame(
    input  logic [7:0]  hdr[20],
    input  logic [7:0]  payload[$],
    input  logic        m_tready_val,
    output logic [7:0]  cap[$],
    output logic        hdr_valid_seen,
    output logic        tlast_seen,
    output logic [31:0] src_ip_cap,
    output logic [31:0] dst_ip_cap,
    output logic [7:0]  proto_cap
  );
    int   total;
    logic fields_taken;

    cap            = {};
    hdr_valid_seen = 1'b0;
    tlast_seen     = 1'b0;
    src_ip_cap     = 32'd0;
    dst_ip_cap     = 32'd0;
    proto_cap      = 8'd0;
    fields_taken   = 1'b0;
    total          = 20 + payload.size();

    @(negedge clk);
    m_tready <= m_tready_val;

    for (int i = 0; i < total; i++) begin
      @(negedge clk);
      s_tdata  <= (i < 20) ? hdr[i] : payload[i - 20];
      s_tvalid <= 1'b1;
      s_tlast  <= (i == total - 1) ? 1'b1 : 1'b0;
      @(posedge clk); #1;
      if (hdr_valid_cap) hdr_valid_seen = 1'b1;
      if (hdr_valid_cap && !fields_taken) begin
        src_ip_cap   = src_ip;
        dst_ip_cap   = dst_ip;
        proto_cap    = proto;
        fields_taken = 1'b1;
      end
      if (m_tvalid_cap && m_tready) begin
        cap.push_back(m_tdata_cap);
        if (m_tlast_cap) tlast_seen = 1'b1;
      end
    end

    @(negedge clk);
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;

    repeat (3) begin
      @(posedge clk); #1;
      if (m_tvalid_cap && m_tready) begin
        cap.push_back(m_tdata_cap);
        if (m_tlast_cap) tlast_seen = 1'b1;
      end
    end
  endtask

  // Send raw bytes with tlast on last_idx (for short-frame test).
  task automatic send_raw(input logic [7:0] data[$], input int last_idx);
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
    m_tready <= 1'b1;
    local_ip <= LOCAL_IP;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(3);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(2);

    // ===== T1: Valid IPv4/UDP to local_ip — forwarded, fields correct =====
    begin
      logic [7:0]  hdr[20], pl[$], cap[$];
      logic        hdr_seen, tlast_seen;
      logic [31:0] src_got, dst_got;
      logic [7:0]  proto_got;

      build_ipv4_hdr(8'h45, 8'h11, SRC_IP, LOCAL_IP, hdr);
      pl.push_back(8'hAA); pl.push_back(8'hBB); pl.push_back(8'hCC);

      send_frame(hdr, pl, 1'b1, cap, hdr_seen, tlast_seen, src_got, dst_got, proto_got);

      if (!hdr_seen) begin
        $error("T1 FAIL: hdr_valid never asserted"); fails++;
      end else $display("T1a PASS: hdr_valid asserted");

      if (cap.size() !== 3) begin
        $error("T1 FAIL: %0d bytes forwarded, want 3", cap.size()); fails++;
      end else $display("T1b PASS: 3 payload bytes forwarded");

      if (!tlast_seen) begin
        $error("T1 FAIL: tlast never asserted"); fails++;
      end else $display("T1c PASS: tlast asserted");

      for (int i = 0; i < 3 && i < int'(cap.size()); i++) begin
        if (cap[i] !== pl[i]) begin
          $error("T1 FAIL: payload[%0d]=0x%02X want 0x%02X", i, cap[i], pl[i]); fails++;
        end
      end
      if (fails == 0) $display("T1d PASS: payload bytes correct");

      if (src_got !== SRC_IP) begin
        $error("T1 FAIL: src_ip=0x%08X want 0x%08X", src_got, SRC_IP); fails++;
      end else $display("T1e PASS: src_ip=0x%08X correct", src_got);

      if (dst_got !== LOCAL_IP) begin
        $error("T1 FAIL: dst_ip=0x%08X want 0x%08X", dst_got, LOCAL_IP); fails++;
      end else $display("T1f PASS: dst_ip=0x%08X correct", dst_got);

      if (proto_got !== 8'h11) begin
        $error("T1 FAIL: protocol=0x%02X want 0x11", proto_got); fails++;
      end else $display("T1g PASS: protocol=0x11 (UDP)");
    end

    clk_wait(4);

    // ===== T2: Wrong dst_ip — ST_DROP, 0 bytes forwarded =====
    begin
      logic [7:0]  hdr[20], pl[$], cap[$];
      logic        hdr_seen, tlast_seen;
      logic [31:0] src_got, dst_got;
      logic [7:0]  proto_got;

      build_ipv4_hdr(8'h45, 8'h11, SRC_IP, OTHER_IP, hdr);
      for (int i = 0; i < 4; i++) pl.push_back(8'(i));

      send_frame(hdr, pl, 1'b1, cap, hdr_seen, tlast_seen, src_got, dst_got, proto_got);

      if (hdr_seen) begin
        $error("T2 FAIL: hdr_valid asserted for wrong dst_ip"); fails++;
      end else $display("T2a PASS: hdr_valid=0 for wrong dst_ip");

      if (cap.size() !== 0) begin
        $error("T2 FAIL: %0d bytes forwarded, want 0", cap.size()); fails++;
      end else $display("T2b PASS: 0 bytes forwarded (dropped)");
    end

    clk_wait(4);

    // ===== T3: Wrong protocol (TCP=0x06) — ST_DROP =====
    begin
      logic [7:0]  hdr[20], pl[$], cap[$];
      logic        hdr_seen, tlast_seen;
      logic [31:0] src_got, dst_got;
      logic [7:0]  proto_got;

      build_ipv4_hdr(8'h45, 8'h06, SRC_IP, LOCAL_IP, hdr);
      pl.push_back(8'hDE); pl.push_back(8'hAD);

      send_frame(hdr, pl, 1'b1, cap, hdr_seen, tlast_seen, src_got, dst_got, proto_got);

      if (hdr_seen) begin
        $error("T3 FAIL: hdr_valid asserted for TCP (proto=0x06)"); fails++;
      end else $display("T3a PASS: TCP frame dropped (hdr_valid=0)");

      if (cap.size() !== 0) begin
        $error("T3 FAIL: %0d bytes forwarded, want 0", cap.size()); fails++;
      end else $display("T3b PASS: 0 bytes forwarded for TCP");
    end

    clk_wait(4);

    // ===== T4: Wrong version/IHL (0x46 = IPv4 with options) — ST_DROP =====
    begin
      logic [7:0]  hdr[20], pl[$], cap[$];
      logic        hdr_seen, tlast_seen;
      logic [31:0] src_got, dst_got;
      logic [7:0]  proto_got;

      build_ipv4_hdr(8'h46, 8'h11, SRC_IP, LOCAL_IP, hdr);
      pl.push_back(8'hBE); pl.push_back(8'hEF);

      send_frame(hdr, pl, 1'b1, cap, hdr_seen, tlast_seen, src_got, dst_got, proto_got);

      if (hdr_seen) begin
        $error("T4 FAIL: hdr_valid asserted for ver/IHL=0x46"); fails++;
      end else $display("T4a PASS: ver/IHL=0x46 frame dropped");

      if (cap.size() !== 0) begin
        $error("T4 FAIL: %0d bytes forwarded, want 0", cap.size()); fails++;
      end else $display("T4b PASS: 0 bytes forwarded");
    end

    clk_wait(4);

    // ===== T5: Short frame (< 20 bytes), then valid frame — FSM resets =====
    begin
      logic [7:0] raw[$];
      for (int i = 0; i < 10; i++) raw.push_back(8'(i));
      send_raw(raw, 9); // tlast on byte 9

      begin
        logic [7:0]  hdr[20], pl[$], cap[$];
        logic        hdr_seen, tlast_seen;
        logic [31:0] src_got, dst_got;
        logic [7:0]  proto_got;

        build_ipv4_hdr(8'h45, 8'h11, SRC_IP, LOCAL_IP, hdr);
        pl.push_back(8'hD5);

        send_frame(hdr, pl, 1'b1, cap, hdr_seen, tlast_seen, src_got, dst_got, proto_got);

        if (!hdr_seen || cap.size() !== 1) begin
          $error("T5 FAIL: after short frame, next frame not forwarded (hdr=%0b cap=%0d)",
                 hdr_seen, cap.size());
          fails++;
        end else $display("T5  PASS: FSM reset after short frame, next frame forwarded");
      end
    end

    clk_wait(4);

    // ===== T6: Back-to-back valid frames =====
    begin
      logic [7:0]  hdr1[20], hdr2[20];
      logic [7:0]  pl1[$], pl2[$], cap1[$], cap2[$];
      logic        hdr1_seen, hdr2_seen, tlast1, tlast2;
      logic [31:0] sg1, dg1, sg2, dg2;
      logic [7:0]  pg1, pg2;

      build_ipv4_hdr(8'h45, 8'h11, SRC_IP, LOCAL_IP, hdr1);
      build_ipv4_hdr(8'h45, 8'h11, SRC_IP, LOCAL_IP, hdr2);
      pl1.push_back(8'hE1); pl1.push_back(8'hE2);
      pl2.push_back(8'hF1); pl2.push_back(8'hF2); pl2.push_back(8'hF3);

      send_frame(hdr1, pl1, 1'b1, cap1, hdr1_seen, tlast1, sg1, dg1, pg1);
      send_frame(hdr2, pl2, 1'b1, cap2, hdr2_seen, tlast2, sg2, dg2, pg2);

      if (cap1.size() !== 2 || cap2.size() !== 3) begin
        $error("T6 FAIL: back-to-back cap1=%0d (want 2), cap2=%0d (want 3)",
               cap1.size(), cap2.size());
        fails++;
      end else $display("T6  PASS: back-to-back frames (2+3 bytes)");
    end

    if (fails == 0) $display("tb_ipv4_header_parser: ALL PASS");
    else            $fatal(1, "tb_ipv4_header_parser: %0d FAILURES", fails);
    $finish;
  end

endmodule
