`timescale 1ns/1ps
/**
 * @file tb_udp_ipv4_tx_builder.sv
 * @brief Unit test for udp_ipv4_tx_builder module.
 * @details Tests:
 *   T1: "HELLO" payload (5 B), no backpressure.
 *       src_ip=192.168.1.2 dst_ip=192.168.1.1 src_port=1234 dst_port=8080
 *       Checks total_len=33, udp_len=13, IPv4 checksum, payload passthrough.
 *   T2: Different IPs/ports, 3-byte payload.
 *       src_ip=10.0.0.1 dst_ip=10.0.0.2 src_port=5000 dst_port=1234
 *       Checks total_len=31, udp_len=11, independent checksum.
 *   T3: Back-to-back frame — FSM recovers to ST_IDLE after T2, 1-byte payload.
 */

module tb_udp_ipv4_tx_builder;
  import tb_eth_pkg::*;
  import eth_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #4 clk = ~clk;

  udp_packet_meta_t tx_meta_s;
  logic        tx_meta_valid;
  logic        tx_meta_ready;

  logic [7:0]  s_tdata;
  logic        s_tvalid;
  logic        s_tready;
  logic        s_tlast;

  logic [7:0]  m_tdata;
  logic        m_tvalid;
  logic        m_tready;
  logic        m_tlast;
  logic [15:0] ipv4_total_len;

  udp_ipv4_tx_builder dut (
    .clk_i(clk), .rst_ni(rst_n),
    .tx_meta_valid_i(tx_meta_valid), .tx_meta_ready_o(tx_meta_ready),
    .tx_meta_i(tx_meta_s),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
    .ipv4_total_len_o(ipv4_total_len)
  );

  // Pre-NBA captures (blocking in always @posedge — fires before NBA)
  logic       m_tvalid_cap, m_tlast_cap;
  logic [7:0] m_tdata_cap;
  always @(posedge clk) begin
    m_tvalid_cap = m_tvalid;
    m_tlast_cap  = m_tlast;
    m_tdata_cap  = m_tdata;
  end

  int fails = 0;

  task automatic clk_wait(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  // Reference IPv4 checksum computed in simulation.
  function automatic logic [15:0] ref_csum(input logic [159:0] hdr);
    logic [31:0] s;
    s = 32'd0;
    for (int i = 0; i < 10; i++)
      s += {16'd0, hdr[159 - i*16 -: 16]};
    // two-pass fold
    s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
    s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
    return ~s[15:0];
  endfunction

  // Drive one full packet and collect all m_axis output bytes.
  // Handshake check is done at posedge BEFORE #1 so tx_meta_ready is seen before NBA.
  task automatic run_packet(
    input  udp_packet_meta_t meta,
    input  logic [7:0] payload[$],
    output logic [7:0] cap[$],
    output logic       tlast_seen
  );
    cap        = {};
    tlast_seen = 1'b0;

    // Present tx_meta
    @(negedge clk);
    tx_meta_s     <= meta;
    tx_meta_valid <= 1'b1;

    // Wait for tx_meta_ready at posedge (before #1 so NBA hasn't fired yet).
    @(posedge clk);
    while (!tx_meta_ready) @(posedge clk);
    // Handshake occurred: state_q transitions to ST_HDR via NBA.
    #1;
    @(negedge clk);
    tx_meta_valid <= 1'b0;

    // Header phase: DUT in ST_HDR, emits 28 bytes automatically.
    for (int i = 0; i < 28; i++) begin
      @(posedge clk); #1;
      while (!(m_tvalid_cap && m_tready)) begin
        @(posedge clk); #1;
      end
      cap.push_back(m_tdata_cap);
      if (m_tlast_cap) tlast_seen = 1'b1;
    end

    // Payload phase: drive s_axis, collect m_axis in lock-step.
    for (int i = 0; i < int'(payload.size()); i++) begin
      @(negedge clk);
      s_tdata  <= payload[i];
      s_tvalid <= 1'b1;
      s_tlast  <= (i == int'(payload.size()) - 1) ? 1'b1 : 1'b0;
      @(posedge clk); #1;
      while (!(m_tvalid_cap && m_tready)) begin
        @(posedge clk); #1;
      end
      cap.push_back(m_tdata_cap);
      if (m_tlast_cap) tlast_seen = 1'b1;
    end

    @(negedge clk);
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
    clk_wait(2);
  endtask

  initial begin
    tx_meta_valid <= 1'b0;
    s_tdata       <= 8'h00;
    s_tvalid      <= 1'b0;
    s_tlast       <= 1'b0;
    m_tready      <= 1'b1;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(3);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(2);

    // ===== T1: "HELLO" payload, 192.168.1.2 -> 192.168.1.1 =====
    begin
      udp_packet_meta_t meta;
      logic [7:0]  pl[$], cap[$];
      logic        tlast;
      logic [15:0] csum;
      logic [159:0] ref_hdr;

      meta.src_mac     = 48'h000A3501FEC0;
      meta.dst_mac     = 48'hFFFFFFFFFFFF;
      meta.src_ip      = 32'hC0A80102; // 192.168.1.2
      meta.dst_ip      = 32'hC0A80101; // 192.168.1.1
      meta.src_port    = 16'd1234;
      meta.dst_port    = 16'd8080;
      meta.payload_len = 16'd5;

      pl.push_back(8'h48); pl.push_back(8'h45); // H E
      pl.push_back(8'h4C); pl.push_back(8'h4C); // L L
      pl.push_back(8'h4F);                       // O

      run_packet(meta, pl, cap, tlast);

      if (cap.size() !== 33) begin
        $error("T1 FAIL: output size=%0d want 33", cap.size()); fails++;
      end else $display("T1a PASS: 33 bytes output (28 hdr + 5 payload)");

      if (!tlast) begin
        $error("T1 FAIL: m_axis_tlast never seen"); fails++;
      end else $display("T1b PASS: m_axis_tlast on last byte");

      if (cap[0] !== 8'h45) begin
        $error("T1 FAIL: byte0=0x%02X want 0x45", cap[0]); fails++;
      end else $display("T1c PASS: VER/IHL=0x45");

      if ({cap[2], cap[3]} !== 16'd33) begin
        $error("T1 FAIL: total_len=%0d want 33", {cap[2], cap[3]}); fails++;
      end else $display("T1d PASS: total_len=33");

      if ({cap[6], cap[7]} !== 16'h4000) begin
        $error("T1 FAIL: flags=0x%04X want 0x4000", {cap[6], cap[7]}); fails++;
      end else $display("T1e PASS: flags=0x4000 (DF)");

      if (cap[8] !== 8'h40) begin
        $error("T1 FAIL: ttl=0x%02X want 0x40", cap[8]); fails++;
      end else $display("T1f PASS: TTL=64");

      if (cap[9] !== 8'h11) begin
        $error("T1 FAIL: proto=0x%02X want 0x11", cap[9]); fails++;
      end else $display("T1g PASS: protocol=0x11 (UDP)");

      // Verify IPv4 checksum
      ref_hdr = {
        8'h45, 8'h00, 16'd33,
        8'h00, 8'h00, 8'h40, 8'h00,
        8'h40, 8'h11, 8'h00, 8'h00,
        meta.src_ip[31:24], meta.src_ip[23:16],
        meta.src_ip[15:8],  meta.src_ip[7:0],
        meta.dst_ip[31:24], meta.dst_ip[23:16],
        meta.dst_ip[15:8],  meta.dst_ip[7:0]
      };
      csum = ref_csum(ref_hdr);
      if ({cap[10], cap[11]} !== csum) begin
        $error("T1 FAIL: csum=0x%04X want 0x%04X", {cap[10], cap[11]}, csum); fails++;
      end else $display("T1h PASS: IPv4 checksum=0x%04X correct", csum);

      if ({cap[12], cap[13], cap[14], cap[15]} !== meta.src_ip) begin
        $error("T1 FAIL: src_ip wrong"); fails++;
      end else $display("T1i PASS: src_ip=192.168.1.2");

      if ({cap[16], cap[17], cap[18], cap[19]} !== meta.dst_ip) begin
        $error("T1 FAIL: dst_ip wrong"); fails++;
      end else $display("T1j PASS: dst_ip=192.168.1.1");

      if ({cap[20], cap[21]} !== meta.src_port) begin
        $error("T1 FAIL: src_port=%0d want 1234", {cap[20], cap[21]}); fails++;
      end else $display("T1k PASS: UDP src_port=1234");

      if ({cap[22], cap[23]} !== meta.dst_port) begin
        $error("T1 FAIL: dst_port=%0d want 8080", {cap[22], cap[23]}); fails++;
      end else $display("T1l PASS: UDP dst_port=8080");

      if ({cap[24], cap[25]} !== 16'd13) begin
        $error("T1 FAIL: udp_len=%0d want 13", {cap[24], cap[25]}); fails++;
      end else $display("T1m PASS: UDP length=13");

      if ({cap[26], cap[27]} !== 16'h0000) begin
        $error("T1 FAIL: UDP csum=0x%02X%02X want 0x0000", cap[26], cap[27]); fails++;
      end else $display("T1n PASS: UDP checksum=0x0000");

      begin
        automatic logic ok = 1'b1;
        for (int i = 0; i < 5 && (28 + i) < int'(cap.size()); i++)
          if (cap[28+i] !== pl[i]) ok = 1'b0;
        if (!ok) begin $error("T1 FAIL: payload mismatch"); fails++; end
        else      $display("T1o PASS: payload HELLO correct");
      end
    end

    clk_wait(4);

    // ===== T2: 3-byte payload, 10.0.0.1 -> 10.0.0.2 =====
    begin
      udp_packet_meta_t meta;
      logic [7:0]  pl[$], cap[$];
      logic        tlast;
      logic [15:0] csum;
      logic [159:0] ref_hdr;

      meta.src_mac     = 48'h001122334455;
      meta.dst_mac     = 48'h665544332211;
      meta.src_ip      = 32'h0A000001; // 10.0.0.1
      meta.dst_ip      = 32'h0A000002; // 10.0.0.2
      meta.src_port    = 16'd5000;
      meta.dst_port    = 16'd1234;
      meta.payload_len = 16'd3;

      pl.push_back(8'hAA); pl.push_back(8'hBB); pl.push_back(8'hCC);

      run_packet(meta, pl, cap, tlast);

      if (cap.size() !== 31) begin
        $error("T2 FAIL: output size=%0d want 31", cap.size()); fails++;
      end else $display("T2a PASS: 31 bytes output (28 hdr + 3 payload)");

      if ({cap[2], cap[3]} !== 16'd31) begin
        $error("T2 FAIL: total_len=%0d want 31", {cap[2], cap[3]}); fails++;
      end else $display("T2b PASS: total_len=31");

      ref_hdr = {
        8'h45, 8'h00, 16'd31,
        8'h00, 8'h00, 8'h40, 8'h00,
        8'h40, 8'h11, 8'h00, 8'h00,
        meta.src_ip[31:24], meta.src_ip[23:16],
        meta.src_ip[15:8],  meta.src_ip[7:0],
        meta.dst_ip[31:24], meta.dst_ip[23:16],
        meta.dst_ip[15:8],  meta.dst_ip[7:0]
      };
      csum = ref_csum(ref_hdr);
      if ({cap[10], cap[11]} !== csum) begin
        $error("T2 FAIL: csum=0x%04X want 0x%04X", {cap[10], cap[11]}, csum); fails++;
      end else $display("T2c PASS: IPv4 checksum=0x%04X correct", csum);

      if ({cap[24], cap[25]} !== 16'd11) begin
        $error("T2 FAIL: udp_len=%0d want 11", {cap[24], cap[25]}); fails++;
      end else $display("T2d PASS: UDP length=11");

      if (!tlast) begin
        $error("T2 FAIL: m_axis_tlast not seen"); fails++;
      end else $display("T2e PASS: m_axis_tlast on last byte");
    end

    clk_wait(4);

    // ===== T3: Back-to-back, 1-byte payload (FSM recovery test) =====
    begin
      udp_packet_meta_t meta;
      logic [7:0]  pl[$], cap[$];
      logic        tlast;

      meta.src_mac     = 48'h000000000000;
      meta.dst_mac     = 48'hFFFFFFFFFFFF;
      meta.src_ip      = 32'hC0A80101;
      meta.dst_ip      = 32'hC0A80102;
      meta.src_port    = 16'd9999;
      meta.dst_port    = 16'd9999;
      meta.payload_len = 16'd1;

      pl.push_back(8'h5A);

      run_packet(meta, pl, cap, tlast);

      if (cap.size() !== 29 || !tlast) begin
        $error("T3 FAIL: size=%0d want 29, tlast=%0b want 1", cap.size(), tlast); fails++;
      end else $display("T3  PASS: back-to-back 1-byte packet, 29 bytes output");
    end

    if (fails == 0) $display("tb_udp_ipv4_tx_builder: ALL PASS");
    else            $fatal(1, "tb_udp_ipv4_tx_builder: %0d FAILURES", fails);
    $finish;
  end

endmodule
