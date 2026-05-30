`timescale 1ns/1ps
/**
 * @file tb_gmii_rx_mac.sv
 * @brief Unit test for gmii_rx_mac module.
 * @details Tests:
 *   T1: Preamble+SFD stripped — first AXI-S byte is dst_mac[47:40], NOT 0xD5
 *   T2: tlast asserts on the final byte when DV drops
 *   T3: No output during preamble/SFD phases
 *   T4: Correct byte count for a 14+5 = 19 byte frame
 */

module tb_gmii_rx_mac;
  import tb_eth_pkg::*;

  logic        clk     = 1'b0;
  logic        rst_n   = 1'b0;
  logic [7:0]  gmii_rxd;
  logic        gmii_rx_dv;
  logic        gmii_rx_er;
  logic [7:0]  m_axis_tdata;
  logic        m_axis_tvalid;
  logic        m_axis_tready;
  logic        m_axis_tlast;
  logic        m_axis_tuser;
  logic        frame_done;

  always #4 clk = ~clk;

  gmii_rx_mac #(.EXPECT_PREAMBLE(1'b1)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .gmii_rxd_i(gmii_rxd), .gmii_rx_dv_i(gmii_rx_dv), .gmii_rx_er_i(gmii_rx_er),
    .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser), .frame_done_o(frame_done)
  );

  // Pre-NBA capture: sample AXI-S outputs in the posedge active region before
  // state_q non-blocking update.  Needed for tlast/tvalid on the final byte
  // where state_q transitions RX_DATA->RX_IDLE in the same posedge.
  logic [7:0] m_axis_tdata_cap;
  logic       m_axis_tvalid_cap;
  logic       m_axis_tlast_cap;
  always @(posedge clk) begin
    m_axis_tdata_cap  = m_axis_tdata;
    m_axis_tvalid_cap = m_axis_tvalid;
    m_axis_tlast_cap  = m_axis_tlast;
  end

  int fails = 0;

  task automatic clk_clk(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  // Drive a complete GMII frame (preamble + SFD + data[]) and capture AXI-S output.
  // Strategy: interleave negedge drive with posedge sample throughout.
  // The DUT has a 1-cycle rxd_q/dv_q pipeline, so data[i] driven on negedge N
  // appears at m_axis_tdata at the posedge two cycles later (after RX_DATA is
  // entered). The flush after dv=0 captures the last byte from the pipeline.
  task automatic drive_and_capture(
    input  logic [7:0] data[],
    input  int         data_len,
    output logic [7:0] cap[$],
    output logic       tlast_seen
  );
    cap        = {};
    tlast_seen = 1'b0;
    m_axis_tready = 1'b1;

    // Preamble (7 bytes): no AXI-S output yet
    for (int i = 0; i < 7; i++) begin
      @(negedge clk); gmii_rxd = 8'h55; gmii_rx_dv = 1'b1;
      @(posedge clk); #1;
      if (m_axis_tvalid_cap && m_axis_tready) begin
        cap.push_back(m_axis_tdata_cap);
        if (m_axis_tlast_cap) tlast_seen = 1'b1;
      end
    end

    // SFD: DUT transitions RX_PRE -> RX_SFD; still no AXI-S output
    @(negedge clk); gmii_rxd = 8'hD5; gmii_rx_dv = 1'b1;
    @(posedge clk); #1;
    if (m_axis_tvalid && m_axis_tready) begin
      cap.push_back(m_axis_tdata);
      if (m_axis_tlast) tlast_seen = 1'b1;
    end

    // Data bytes: AXI-S output lags one posedge (rxd_q pipeline).
    // data[0] driven on negedge -> RX_DATA entered at posedge -> data[0] captured
    // one posedge later (when driving data[1]).
    for (int i = 0; i < data_len; i++) begin
      @(negedge clk); gmii_rxd = data[i]; gmii_rx_dv = 1'b1;
      @(posedge clk); #1;
      if (m_axis_tvalid_cap && m_axis_tready) begin
        cap.push_back(m_axis_tdata_cap);
        if (m_axis_tlast_cap) tlast_seen = 1'b1;
      end
    end

    // Drop DV; flush pipeline — captures last data byte with tlast
    @(negedge clk); gmii_rxd = 8'h00; gmii_rx_dv = 1'b0;
    repeat (4) begin
      @(posedge clk); #1;
      if (m_axis_tvalid_cap && m_axis_tready) begin
        cap.push_back(m_axis_tdata_cap);
        if (m_axis_tlast_cap) tlast_seen = 1'b1;
      end
    end

    @(negedge clk); m_axis_tready = 1'b0;
    clk_clk(2);
  endtask

  initial begin
    gmii_rxd = 8'h00; gmii_rx_dv = 1'b0; gmii_rx_er = 1'b0;
    m_axis_tready = 1'b1;

    @(negedge clk); rst_n = 1'b0;
    clk_clk(3);
    @(negedge clk); rst_n = 1'b1;
    clk_clk(2);

    // Build test frame: 14 header bytes + 5 payload bytes = 19 bytes total
    begin
      logic [7:0] hdr[14];
      logic [7:0] frame_data[19];
      logic [7:0] cap[$];
      logic       tlast_seen;

      build_eth_hdr(48'hAABBCCDDEEFF, 48'h001122334455, 16'h0800, hdr);
      for (int i = 0; i < 14; i++) frame_data[i]    = hdr[i];
      for (int i = 0; i < 5;  i++) frame_data[14+i] = 8'(8'hB0 + i); // B0..B4

      drive_and_capture(frame_data, 19, cap, tlast_seen);

      // --- T1: SFD must NOT appear in output; first byte = dst_mac[47:40] = 0xAA ---
      if (cap.size() == 0) begin
        $error("T1 FAIL: no bytes captured");
        fails++;
      end else if (cap[0] !== 8'hAA) begin
        $error("T1 FAIL: first byte = 0x%02X, expected 0xAA (not 0xD5)", cap[0]);
        fails++;
      end else begin
        $display("T1 PASS: first byte = 0x%02X (not SFD)", cap[0]);
      end

      // --- T2: tlast asserted ---
      if (!tlast_seen) begin
        $error("T2 FAIL: tlast never asserted");
        fails++;
      end else begin
        $display("T2 PASS: tlast asserted on last byte");
      end

      // --- T3: No 0xD5 in captured stream ---
      for (int i = 0; i < cap.size(); i++) begin
        if (cap[i] === 8'hD5 && i == 0) begin
          $error("T3 FAIL: 0xD5 (SFD) leaked as first byte");
          fails++;
        end
      end
      if (fails == 0) $display("T3 PASS: 0xD5 not forwarded");

      // --- T4: Correct byte count = 19 ---
      if (cap.size() !== 19) begin
        $error("T4 FAIL: captured %0d bytes, expected 19", cap.size());
        fails++;
      end else begin
        $display("T4 PASS: captured 19 bytes");
      end

      // --- Verify all frame bytes match ---
      for (int i = 0; i < 19 && i < cap.size(); i++) begin
        if (cap[i] !== frame_data[i]) begin
          $error("DATA FAIL: byte[%0d] = 0x%02X, expected 0x%02X", i, cap[i], frame_data[i]);
          fails++;
        end
      end
      if (fails == 0) $display("DATA PASS: all 19 bytes match");
    end

    if (fails == 0) $display("tb_gmii_rx_mac: ALL PASS");
    else            $fatal(1, "tb_gmii_rx_mac: %0d FAILURES", fails);
    $finish;
  end

endmodule
