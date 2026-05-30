`timescale 1ns/1ps
/**
 * @file tb_mac_stream_tx_rx_stream.sv
 * @brief MAC integration test: AXI-Stream -> gmii_tx_mac -> GMII loopback
 *        -> gmii_rx_mac -> AXI-Stream scoreboard.
 * @details Tests:
 *   T1: 5-byte payload "HELLO" — RX captures 64 bytes (14 hdr + 5 payload + 41 pad + 4 FCS)
 *       Verifies: header, payload, padding=0x00, correct FCS, tlast
 *   T2: 46-byte payload (no padding) — RX captures 64 bytes (14 + 46 + 0 + 4)
 *       Verifies: header, all payload bytes, correct FCS
 *
 * Capture strategy: pre-NBA blocking (=) capture for all DUT combinatorial outputs
 * (s_axis_tready, m_axis_tvalid, m_axis_tdata, m_axis_tlast).
 * The combined TX-drive + RX-capture loop runs 150 posedge iterations — well over
 * the max frame length of 7+1+14+46+4+12 = 84 TX cycles plus RX pipeline delay.
 */

module tb_mac_stream_tx_rx_stream;
  import tb_eth_pkg::*;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #4 clk = ~clk;

  // TX MAC — AXI-S input
  logic [47:0] tx_dst_mac, tx_src_mac;
  logic [15:0] tx_ethertype;
  logic        tx_start, tx_busy, tx_done;
  logic [7:0]  s_axis_tdata;
  logic        s_axis_tvalid, s_axis_tready, s_axis_tlast;

  // GMII loopback wires
  logic [7:0]  gmii_txd;
  logic        gmii_tx_en, gmii_tx_er;

  // RX MAC — AXI-S output
  logic [7:0]  m_axis_tdata;
  logic        m_axis_tvalid, m_axis_tready, m_axis_tlast, m_axis_tuser;
  logic        frame_done;

  gmii_tx_mac u_tx (
    .clk_i(clk), .rst_ni(rst_n),
    .tx_dst_mac_i(tx_dst_mac), .tx_src_mac_i(tx_src_mac),
    .tx_ethertype_i(tx_ethertype),
    .tx_start_i(tx_start), .tx_busy_o(tx_busy), .tx_done_o(tx_done),
    .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
    .gmii_txd_o(gmii_txd), .gmii_tx_en_o(gmii_tx_en), .gmii_tx_er_o(gmii_tx_er)
  );

  gmii_rx_mac #(.EXPECT_PREAMBLE(1'b1)) u_rx (
    .clk_i(clk), .rst_ni(rst_n),
    .gmii_rxd_i(gmii_txd), .gmii_rx_dv_i(gmii_tx_en), .gmii_rx_er_i(gmii_tx_er),
    .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser), .frame_done_o(frame_done)
  );

  // Pre-NBA captures: sample combinatorial DUT outputs before state_q NBA fires.
  // Without these, post-NBA state_q changes combinatorial outputs mid-posedge.
  logic        s_tready_cap;
  logic        m_tvalid_cap, m_tlast_cap;
  logic [7:0]  m_tdata_cap;
  always @(posedge clk) begin
    s_tready_cap  = s_axis_tready;
    m_tvalid_cap  = m_axis_tvalid;
    m_tlast_cap   = m_axis_tlast;
    m_tdata_cap   = m_axis_tdata;
  end

  int fails = 0;

  localparam logic [47:0] DST_MAC = 48'hDE_AD_BE_EF_12_34;
  localparam logic [47:0] SRC_MAC = 48'h00_0A_35_01_FE_C0;
  localparam logic [15:0] ETYPE   = 16'h0800;

  task automatic clk_wait(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  // Compute expected FCS: CRC32(header + payload + padding)
  function automatic logic [31:0] expected_fcs(
    input logic [7:0] pl[$],
    input int         pl_len,
    input int         pad_len
  );
    logic [7:0] hdr[14];
    logic [7:0] d[$];
    build_eth_hdr(DST_MAC, SRC_MAC, ETYPE, hdr);
    d = {};
    for (int i = 0; i < 14;      i++) d.push_back(hdr[i]);
    for (int i = 0; i < pl_len;  i++) d.push_back(pl[i]);
    for (int i = 0; i < pad_len; i++) d.push_back(8'h00);
    return crc32(d, 14 + pl_len + pad_len);
  endfunction

  // Send payload through TX MAC; capture what RX MAC outputs on AXI-S.
  // Both TX driving and RX capturing run in the same posedge loop.
  // TX: advances payload pointer when s_tready_cap (pre-NBA) is asserted.
  // RX: captures m_axis bytes when m_tvalid_cap (pre-NBA) is asserted.
  task automatic tx_rx_roundtrip(
    input  logic [7:0] pl[$],
    output logic [7:0] cap[$],
    output logic       tlast_seen
  );
    int pi = 0;
    int pl_len;
    pl_len    = pl.size();
    cap       = {};
    tlast_seen = 1'b0;

    m_axis_tready <= 1'b1;

    @(negedge clk);
    tx_dst_mac    <= DST_MAC;
    tx_src_mac    <= SRC_MAC;
    tx_ethertype  <= ETYPE;
    s_axis_tdata  <= pl[0];
    s_axis_tvalid <= 1'b1;
    s_axis_tlast  <= (pl_len == 1) ? 1'b1 : 1'b0;
    tx_start      <= 1'b1;
    @(posedge clk); #1;
    @(negedge clk); tx_start <= 1'b0;

    // Combined TX-drive + RX-capture: 150 posedge iterations.
    // Max frame = preamble(7)+SFD(1)+hdr(14)+pay(46)+FCS(4)+IFG(12) = 84 TX cycles
    // + RX pipeline (~2) + margin -> 150 is sufficient.
    repeat (150) begin
      // Capture RX output using pre-NBA values
      if (m_tvalid_cap && m_axis_tready) begin
        cap.push_back(m_tdata_cap);
        if (m_tlast_cap) tlast_seen = 1'b1;
      end

      // Advance TX payload: pre-NBA s_tready_cap avoids 1-cycle-early advance
      // at the ET_HEADER->ST_PAYLOAD transition
      if (s_tready_cap && s_axis_tvalid && !s_axis_tlast) begin
        pi++;
        @(negedge clk);
        s_axis_tdata <= pl[pi];
        s_axis_tlast <= (pi == pl_len - 1) ? 1'b1 : 1'b0;
      end

      @(posedge clk); #1;
    end

    @(negedge clk);
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
  endtask

  initial begin
    tx_start      <= 1'b0;
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
    s_axis_tdata  <= 8'h00;
    tx_dst_mac    <= '0;
    tx_src_mac    <= '0;
    tx_ethertype  <= '0;
    m_axis_tready <= 1'b1;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(3);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(2);

    // ===== T1: 5-byte payload "HELLO" — 41 padding bytes expected =====
    begin
      logic [7:0]  pl[$], cap[$];
      logic [7:0]  hdr[14];
      logic [31:0] fcs_exp, fcs_got;
      logic        tlast_seen;

      pl.push_back(8'h48); // H
      pl.push_back(8'h45); // E
      pl.push_back(8'h4C); // L
      pl.push_back(8'h4C); // L
      pl.push_back(8'h4F); // O

      tx_rx_roundtrip(pl, cap, tlast_seen);

      // Byte count: 14 hdr + 5 payload + 41 pad + 4 FCS = 64
      if (cap.size() !== 64) begin
        $error("T1 FAIL: %0d bytes captured, want 64", cap.size()); fails++;
      end else $display("T1a PASS: 64 bytes (14+5+41+4)");

      if (!tlast_seen) begin
        $error("T1 FAIL: tlast never asserted"); fails++;
      end else $display("T1b PASS: tlast asserted");

      // Header check
      build_eth_hdr(DST_MAC, SRC_MAC, ETYPE, hdr);
      for (int i = 0; i < 14 && i < int'(cap.size()); i++) begin
        if (cap[i] !== hdr[i]) begin
          $error("T1 FAIL: hdr[%0d]=0x%02X want 0x%02X", i, cap[i], hdr[i]); fails++;
        end
      end
      if (fails == 0) $display("T1c PASS: Ethernet header correct");

      // Payload check
      for (int i = 0; i < 5 && (14+i) < int'(cap.size()); i++) begin
        if (cap[14+i] !== pl[i]) begin
          $error("T1 FAIL: payload[%0d]=0x%02X want 0x%02X", i, cap[14+i], pl[i]); fails++;
        end
      end
      if (fails == 0) $display("T1d PASS: payload HELLO correct");

      // Padding check (bytes 19..59 = 41 bytes of 0x00)
      for (int i = 0; i < 41 && (19+i) < int'(cap.size()); i++) begin
        if (cap[19+i] !== 8'h00) begin
          $error("T1 FAIL: pad[%0d]=0x%02X want 0x00", i, cap[19+i]); fails++;
        end
      end
      if (fails == 0) $display("T1e PASS: 41 padding bytes = 0x00");

      // FCS check (bytes 60..63, LSB first in wire order)
      if (int'(cap.size()) >= 64) begin
        fcs_exp = expected_fcs(pl, 5, 41);
        fcs_got = {cap[63], cap[62], cap[61], cap[60]};
        if (fcs_got !== fcs_exp) begin
          $error("T1 FAIL: FCS=0x%08X want 0x%08X", fcs_got, fcs_exp); fails++;
        end else $display("T1f PASS: FCS=0x%08X correct", fcs_got);
      end
    end

    clk_wait(16);

    // ===== T2: 46-byte payload (no padding) =====
    begin
      logic [7:0]  pl[$], cap[$];
      logic [7:0]  hdr[14];
      logic [31:0] fcs_exp, fcs_got;
      logic        tlast_seen;

      for (int i = 0; i < 46; i++) pl.push_back(8'(i + 1)); // 0x01..0x2E

      tx_rx_roundtrip(pl, cap, tlast_seen);

      // Byte count: 14 hdr + 46 payload + 0 pad + 4 FCS = 64
      if (cap.size() !== 64) begin
        $error("T2 FAIL: %0d bytes captured, want 64", cap.size()); fails++;
      end else $display("T2a PASS: 64 bytes (14+46+0+4)");

      // Header check
      build_eth_hdr(DST_MAC, SRC_MAC, ETYPE, hdr);
      for (int i = 0; i < 14 && i < int'(cap.size()); i++) begin
        if (cap[i] !== hdr[i]) begin
          $error("T2 FAIL: hdr[%0d]=0x%02X want 0x%02X", i, cap[i], hdr[i]); fails++;
        end
      end
      if (fails == 0) $display("T2b PASS: Ethernet header correct");

      // Payload check (no padding expected)
      for (int i = 0; i < 46 && (14+i) < int'(cap.size()); i++) begin
        if (cap[14+i] !== 8'(i+1)) begin
          $error("T2 FAIL: payload[%0d]=0x%02X want 0x%02X", i, cap[14+i], 8'(i+1)); fails++;
        end
      end
      if (fails == 0) $display("T2c PASS: 46 payload bytes correct, no padding");

      // FCS check
      if (int'(cap.size()) >= 64) begin
        fcs_exp = expected_fcs(pl, 46, 0);
        fcs_got = {cap[63], cap[62], cap[61], cap[60]};
        if (fcs_got !== fcs_exp) begin
          $error("T2 FAIL: FCS=0x%08X want 0x%08X", fcs_got, fcs_exp); fails++;
        end else $display("T2d PASS: FCS=0x%08X correct", fcs_got);
      end
    end

    if (fails == 0) $display("tb_mac_stream_tx_rx_stream: ALL PASS");
    else            $fatal(1, "tb_mac_stream_tx_rx_stream: %0d FAILURES", fails);
    $finish;
  end

endmodule
