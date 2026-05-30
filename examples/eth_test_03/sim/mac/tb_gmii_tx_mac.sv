`timescale 1ns/1ps
/**
 * @file tb_gmii_tx_mac.sv
 * @brief Unit test for gmii_tx_mac module.
 * @details Tests:
 *   T1: 1-byte payload -> 45 pad bytes, correct FCS, 72 bytes TX_EN=1, 12 IFG
 *   T2: 46-byte payload -> 0 pad bytes, correct FCS, 72 bytes TX_EN=1
 *   T3: gmii_tx_er always 0
 *
 * Capture strategy: gmii_txd_cap is sampled with blocking (=) assignment at posedge
 * BEFORE any non-blocking (<=) updates to state_q take effect.  This gives the
 * correct GMII output for the cycle that is *ending* at this edge, even when the
 * state machine simultaneously transitions (e.g. last payload byte -> ST_FCS).
 */

module tb_gmii_tx_mac;
  import tb_eth_pkg::*;

  logic        clk    = 1'b0;
  logic        rst_n  = 1'b0;

  logic [47:0] tx_dst_mac;
  logic [47:0] tx_src_mac;
  logic [15:0] tx_ethertype;

  logic        tx_start;
  logic        tx_busy;
  logic        tx_done;

  logic [7:0]  s_axis_tdata;
  logic        s_axis_tvalid;
  logic        s_axis_tready;
  logic        s_axis_tlast;

  logic [7:0]  gmii_txd;
  logic        gmii_tx_en;
  logic        gmii_tx_er;

  always #4 clk = ~clk;

  gmii_tx_mac dut (
    .clk_i(clk), .rst_ni(rst_n),
    .tx_dst_mac_i(tx_dst_mac), .tx_src_mac_i(tx_src_mac),
    .tx_ethertype_i(tx_ethertype),
    .tx_start_i(tx_start), .tx_busy_o(tx_busy), .tx_done_o(tx_done),
    .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
    .gmii_txd_o(gmii_txd), .gmii_tx_en_o(gmii_tx_en), .gmii_tx_er_o(gmii_tx_er)
  );

  // Sample DUT outputs in the posedge ACTIVE region, before non-blocking
  // state_q update.  Blocking (=) ensures all captures are pre-NBA.
  logic [7:0] gmii_txd_cap;
  logic       gmii_tx_en_cap;
  logic       s_axis_tready_cap;
  logic       tx_busy_cap;
  always @(posedge clk) begin
    gmii_txd_cap      = gmii_txd;
    gmii_tx_en_cap    = gmii_tx_en;
    s_axis_tready_cap = s_axis_tready;
    tx_busy_cap       = tx_busy;
  end

  int fails = 0;

  localparam logic [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF;
  localparam logic [47:0] SRC_MAC = 48'h00_11_22_33_44_55;
  localparam logic [15:0] ETYPE   = 16'h0800;

  task automatic clk_wait(int n = 1);
    repeat (n) begin @(posedge clk); #1; end
  endtask

  function automatic logic [31:0] expected_fcs(
    input logic [7:0] pl[$],
    input int         pl_len,
    input int         pad_len
  );
    logic [7:0] hdr[14];
    logic [7:0] d[$];
    int total;
    build_eth_hdr(DST_MAC, SRC_MAC, ETYPE, hdr);
    total = 14 + pl_len + pad_len;
    d = {};
    for (int i = 0; i < 14;      i++) d.push_back(hdr[i]);
    for (int i = 0; i < pl_len;  i++) d.push_back(pl[i]);
    for (int i = 0; i < pad_len; i++) d.push_back(8'h00);
    return crc32(d, total);
  endfunction

  // Drive one frame and capture all GMII bytes where TX_EN=1.
  // Uses gmii_txd_cap (pre-NBA sampled value) to correctly capture the last
  // payload byte even when it coincides with a state transition.
  task automatic send_and_capture(
    input  logic [7:0] pl[$],
    output logic [7:0] cap[$],
    output int         ifg_count
  );
    int pi;
    int pl_len;
    pi        = 0;
    pl_len    = pl.size();
    cap       = {};
    ifg_count = 0;

    @(negedge clk);
    tx_dst_mac   <= DST_MAC;
    tx_src_mac   <= SRC_MAC;
    tx_ethertype <= ETYPE;
    s_axis_tdata  <= pl[0];
    s_axis_tvalid <= 1'b1;
    s_axis_tlast  <= (pl_len == 1) ? 1'b1 : 1'b0;
    tx_start      <= 1'b1;
    @(posedge clk); #1;
    @(negedge clk); tx_start <= 1'b0;

    // Wait until pre-NBA TX_EN rises (state = ST_PREAMBLE)
    do begin @(posedge clk); #1; end while (!gmii_tx_en_cap);

    // Capture while pre-NBA TX_EN=1; gmii_txd_cap is valid for this cycle
    while (gmii_tx_en_cap) begin
      cap.push_back(gmii_txd_cap);

      // Advance AXI-S source for next payload byte when the DUT consumed one.
      // Use pre-NBA tready_cap: post-NBA tready would advance pi one cycle early
      // when ETH_HEADER→ST_PAYLOAD transition happens (state_d fires before output).
      if (s_axis_tready_cap && s_axis_tvalid && !s_axis_tlast) begin
        pi++;
        @(negedge clk);
        s_axis_tdata <= pl[pi];
        s_axis_tlast <= (pi == pl_len - 1) ? 1'b1 : 1'b0;
      end

      @(posedge clk); #1;
    end

    // Count IFG cycles using pre-NBA tx_busy_cap.
    // Start immediately (we are at posedge+#1, first ST_IFG cycle already active).
    // Post-NBA tx_busy would miss the last IFG cycle (NBA→ST_IDLE before count).
    while (tx_busy_cap) begin
      ifg_count++;
      @(posedge clk); #1;
    end

    @(negedge clk); s_axis_tvalid <= 1'b0; s_axis_tlast <= 1'b0;
  endtask

  initial begin
    tx_start      <= 1'b0;
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
    s_axis_tdata  <= 8'h00;
    tx_dst_mac    <= '0;
    tx_src_mac    <= '0;
    tx_ethertype  <= '0;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(3);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(2);

    // ===== T1: 1-byte payload (45 pad bytes expected) =====
    begin
      logic [7:0]  pl1[$];
      logic [7:0]  cap1[$];
      logic [31:0] fcs1_exp, fcs1_got;
      int          ifg1, pad1_cnt;
      logic [7:0]  hdr1[14];

      pl1.push_back(8'hAA);
      send_and_capture(pl1, cap1, ifg1);
      fcs1_exp = expected_fcs(pl1, 1, 45);

      if (cap1.size() != 72) begin
        $error("T1 FAIL: TX byte count %0d != 72", cap1.size()); fails++;
      end else $display("T1a PASS: 72 bytes TX_EN=1");

      for (int i = 0; i < 7; i++) begin
        if (cap1[i] !== 8'h55) begin
          $error("T1 FAIL: preamble[%0d]=0x%02X want 0x55", i, cap1[i]); fails++;
        end
      end
      if (cap1[7] !== 8'hD5) begin
        $error("T1 FAIL: SFD=0x%02X want 0xD5", cap1[7]); fails++;
      end

      build_eth_hdr(DST_MAC, SRC_MAC, ETYPE, hdr1);
      for (int i = 0; i < 14; i++) begin
        if (cap1[8+i] !== hdr1[i]) begin
          $error("T1 FAIL: hdr[%0d]=0x%02X want 0x%02X", i, cap1[8+i], hdr1[i]); fails++;
        end
      end

      if (cap1[22] !== 8'hAA) begin
        $error("T1 FAIL: payload=0x%02X want 0xAA", cap1[22]); fails++;
      end

      pad1_cnt = 0;
      for (int i = 23; i <= 67; i++) begin
        if (cap1[i] !== 8'h00) begin
          $error("T1 FAIL: pad[%0d]=0x%02X want 0x00", i-23, cap1[i]); fails++;
        end else pad1_cnt++;
      end
      if (pad1_cnt === 45) $display("T1b PASS: 45 padding bytes");
      else begin $error("T1 FAIL: pad count=%0d want 45", pad1_cnt); fails++; end

      fcs1_got = {cap1[71], cap1[70], cap1[69], cap1[68]};
      if (fcs1_got !== fcs1_exp) begin
        $error("T1 FAIL: FCS=0x%08X want 0x%08X", fcs1_got, fcs1_exp); fails++;
      end else $display("T1c PASS: FCS=0x%08X", fcs1_got);

      if (ifg1 !== 12) begin
        $error("T1 FAIL: IFG=%0d want 12", ifg1); fails++;
      end else $display("T1d PASS: IFG=12 cycles");
    end

    clk_wait(4);

    // ===== T2: 46-byte payload (no padding) =====
    begin
      logic [7:0]  pl2[$];
      logic [7:0]  cap2[$];
      logic [31:0] fcs2_exp, fcs2_got;
      int          ifg2;

      for (int i = 0; i < 46; i++) pl2.push_back(8'(i + 1)); // 0x01..0x2E

      send_and_capture(pl2, cap2, ifg2);
      fcs2_exp = expected_fcs(pl2, 46, 0);

      if (cap2.size() != 72) begin
        $error("T2 FAIL: byte count=%0d want 72", cap2.size()); fails++;
      end else $display("T2a PASS: 72 bytes TX_EN=1 (no padding)");

      for (int i = 0; i < 46; i++) begin
        if (cap2[22+i] !== pl2[i]) begin
          $error("T2 FAIL: payload[%0d]=0x%02X want 0x%02X", i, cap2[22+i], pl2[i]); fails++;
        end
      end
      if (fails == 0) $display("T2b PASS: 46 payload bytes, no padding");

      fcs2_got = {cap2[71], cap2[70], cap2[69], cap2[68]};
      if (fcs2_got !== fcs2_exp) begin
        $error("T2 FAIL: FCS=0x%08X want 0x%08X", fcs2_got, fcs2_exp); fails++;
      end else $display("T2c PASS: FCS=0x%08X", fcs2_got);
    end

    // ===== T3: error line always 0 =====
    if (gmii_tx_er !== 1'b0) begin
      $error("T3 FAIL: gmii_tx_er=1 want 0"); fails++;
    end else $display("T3  PASS: gmii_tx_er=0");

    if (fails == 0) $display("tb_gmii_tx_mac: ALL PASS");
    else            $fatal(1, "tb_gmii_tx_mac: %0d FAILURES", fails);
    $finish;
  end

endmodule
