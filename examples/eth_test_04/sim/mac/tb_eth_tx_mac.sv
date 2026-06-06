`timescale 1ns/1ps
/**
 * @file tb_eth_tx_mac.sv
 * @brief Unit test: eth_tx_mac — meta + AXI-Stream -> GMII.
 * @details Tests:
 *   T1: 1-byte payload: 8(pre+SFD)+14(hdr)+46(1pl+45pad)+4(FCS) = 72 GMII bytes, IFG=12
 *   T2: 46-byte payload: 72 GMII bytes, zero padding
 *   T3: 100-byte payload: 8+14+100+4 = 126 GMII bytes, correct FCS
 *   T4: Meta->first-GMII latency: 2 cycles
 *   T5: Underflow (tvalid drops mid-payload): TXER=1, frame aborted
 *   T6: Back-to-back frames: second frame starts correctly after IFG
 */
`ifndef TB_ETH_TX_MAC_SV
`define TB_ETH_TX_MAC_SV

module tb_eth_tx_mac;
  import tb_eth_pkg::*;

  localparam logic [47:0] DST_MAC = 48'hFF_FF_FF_FF_FF_FF;
  localparam logic [47:0] SRC_MAC = 48'h00_0A_35_01_FE_C0;
  localparam logic [15:0] ETYPE   = 16'h9000;

  logic        clk   = 1'b0;
  logic        rst_n = 1'b0;

  logic        s_meta_valid;
  logic        s_meta_ready;
  logic [47:0] s_meta_dst_mac;
  logic [47:0] s_meta_src_mac;
  logic [15:0] s_meta_eth_type;

  logic [7:0]  s_axis_tdata;
  logic        s_axis_tvalid;
  logic        s_axis_tready;
  logic        s_axis_tlast;
  logic        s_axis_tuser;

  logic [7:0]  gmii_txd;
  logic        gmii_tx_en;
  logic        gmii_tx_er;

  logic [15:0] stat_tx_frames;
  logic [15:0] stat_tx_underflow;

  always #4 clk = ~clk; // 125 MHz

  eth_tx_mac #(.IFG_CYCLES(12)) dut (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .s_meta_valid_i    (s_meta_valid),
    .s_meta_ready_o    (s_meta_ready),
    .s_meta_dst_mac_i  (s_meta_dst_mac),
    .s_meta_src_mac_i  (s_meta_src_mac),
    .s_meta_eth_type_i (s_meta_eth_type),
    .s_axis_tdata_i    (s_axis_tdata),
    .s_axis_tvalid_i   (s_axis_tvalid),
    .s_axis_tready_o   (s_axis_tready),
    .s_axis_tlast_i    (s_axis_tlast),
    .s_axis_tuser_i    (s_axis_tuser),
    .gmii_txd_o        (gmii_txd),
    .gmii_tx_en_o      (gmii_tx_en),
    .gmii_tx_er_o      (gmii_tx_er),
    .stat_tx_frames    (stat_tx_frames),
    .stat_tx_underflow (stat_tx_underflow)
  );

  // Pre-NBA capture
  logic [7:0] txd_cap;
  logic       txen_cap;
  logic       txer_cap;
  logic       tready_cap;
  always @(posedge clk) begin
    txd_cap    = gmii_txd;
    txen_cap   = gmii_tx_en;
    txer_cap   = gmii_tx_er;
    tready_cap = s_axis_tready;
  end

  int fails = 0;

  task automatic clk_wait(int n = 1);
    repeat (n) begin @(posedge clk); #1; end
  endtask

  // Send one frame: present meta, drive payload bytes, capture GMII output.
  // Returns captured bytes (TX_EN=1 only) and IFG cycle count.
  task automatic send_and_capture(
    input  logic [7:0] payload [],
    input  int         n_payload,
    input  bit         drop_valid_at, // 0=never drop; >0 = drop tvalid after this many fire()s
    input  int         drop_at_byte,
    output logic [7:0] cap [],
    output int         cap_count,
    output int         txer_count,
    output int         ifg_count
  );
    int  pi;
    int  fires;
    logic [7:0] cap_tmp[$];
    int tc, ic;

    pi     = 0;
    fires  = 0;
    tc     = 0;
    ic     = 2;   // pipeline offset: txen_cap lags tx_en by 1, last IFG->IDLE not counted
    cap_tmp = {};

    @(negedge clk);
    s_meta_valid    <= 1'b1;
    s_meta_dst_mac  <= DST_MAC;
    s_meta_src_mac  <= SRC_MAC;
    s_meta_eth_type <= ETYPE;
    if (n_payload > 0) begin
      s_axis_tdata  <= payload[0];
      s_axis_tvalid <= 1'b1;
      s_axis_tlast  <= (n_payload == 1) ? 1'b1 : 1'b0;
    end

    // One posedge: DUT (ST_IDLE) captures meta, transitions to ST_PREAMBLE
    @(posedge clk); #1;
    @(negedge clk); s_meta_valid <= 1'b0;

    // Wait until TXEN rises
    do begin @(posedge clk); #1; end while (!txen_cap);

    // Capture while TXEN=1
    while (txen_cap) begin
      cap_tmp.push_back(txd_cap);
      if (txer_cap) tc++;

      // Advance AXI-S source when DUT consumed a byte (tready_cap=1 in ST_PAYLOAD)
      if (tready_cap && s_axis_tvalid && !s_axis_tlast) begin
        fires++;
        pi++;
        if (drop_valid_at && fires >= drop_at_byte) begin
          @(negedge clk); s_axis_tvalid <= 1'b0;
        end else begin
          @(negedge clk);
          s_axis_tdata <= payload[pi];
          s_axis_tlast <= (pi == n_payload - 1) ? 1'b1 : 1'b0;
        end
      end

      @(posedge clk); #1;
    end
    // Underflow: tx_en and tx_er change in the same NBA cycle; capture loop exits on
    // txen_cap=0 but txer_cap=1 is visible at that same exit posedge — catch it here.
    if (txer_cap) tc++;

    // IFG cycles: count while s_meta_ready=0 (DUT in ST_IFG or ST_PAD or ST_FCS wait)
    // s_meta_ready_o = (state==ST_IDLE), so count posedges until ready again
    begin
      int timeout;
      timeout = 0;
      while (!s_meta_ready && timeout < 50) begin
        ic++;
        @(posedge clk); #1;
        timeout++;
      end
    end

    @(negedge clk);
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
    clk_wait(2);

    cap_count  = cap_tmp.size();
    cap        = new [cap_count];
    for (int i = 0; i < cap_count; i++) cap[i] = cap_tmp[i];
    txer_count = tc;
    ifg_count  = ic;
  endtask

  initial begin
    s_meta_valid    = 1'b0;
    s_meta_dst_mac  = '0;
    s_meta_src_mac  = '0;
    s_meta_eth_type = '0;
    s_axis_tdata    = 8'h00;
    s_axis_tvalid   = 1'b0;
    s_axis_tlast    = 1'b0;
    s_axis_tuser    = 1'b0;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(4);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(4);

    // ================================================================
    // T1: 1-byte payload -> 72 GMII bytes (preamble+SFD+hdr+46data+FCS)
    //     IFG = 12 cycles
    // ================================================================
    begin
      logic [7:0]  pl[1];
      logic [7:0]  cap[];
      logic [7:0]  hdr[14];
      logic [31:0] fcs_exp;
      logic [7:0]  fcs_b[4];
      int          cnt, tc, ifg;
      logic [7:0]  pl_padded[46];

      pl[0] = 8'hAB;
      send_and_capture(pl, 1, 0, 0, cap, cnt, tc, ifg);

      // Expected frame size: 7 preamble + 1 SFD + 14 hdr + 46 (1+45 pad) + 4 FCS = 72
      if (cnt !== 72) begin
        $error("T1 FAIL: GMII byte count=%0d want 72", cnt); fails++;
      end else $display("T1a PASS: 72 GMII bytes");

      // Preamble: 7 x 0x55
      for (int i = 0; i < 7; i++) begin
        if (cap[i] !== 8'h55) begin
          $error("T1 FAIL: preamble[%0d]=0x%02X want 0x55", i, cap[i]); fails++;
        end
      end
      if (fails == 0) $display("T1b PASS: preamble OK");

      // SFD
      if (cap[7] !== 8'hD5) begin
        $error("T1 FAIL: SFD=0x%02X want 0xD5", cap[7]); fails++;
      end else $display("T1c PASS: SFD=0xD5");

      // Header
      build_eth_hdr(DST_MAC, SRC_MAC, ETYPE, hdr);
      for (int i = 0; i < 14; i++) begin
        if (cap[8+i] !== hdr[i]) begin
          $error("T1 FAIL: hdr[%0d]=0x%02X want 0x%02X", i, cap[8+i], hdr[i]); fails++;
        end
      end
      if (fails == 0) $display("T1d PASS: header OK");

      // Payload byte
      if (cap[22] !== 8'hAB) begin
        $error("T1 FAIL: payload=0x%02X want 0xAB", cap[22]); fails++;
      end else $display("T1e PASS: payload byte OK");

      // Padding: 45 zero bytes
      for (int i = 23; i < 68; i++) begin
        if (cap[i] !== 8'h00) begin
          $error("T1 FAIL: pad[%0d]=0x%02X want 0x00", i-23, cap[i]); fails++;
        end
      end
      if (fails == 0) $display("T1f PASS: 45 pad bytes OK");

      // FCS
      for (int i = 0; i < 46; i++) pl_padded[i] = (i == 0) ? 8'hAB : 8'h00;
      fcs_exp = frame_fcs(DST_MAC, SRC_MAC, ETYPE, pl, 1);
      fcs_b[0] = fcs_exp[7:0]; fcs_b[1] = fcs_exp[15:8];
      fcs_b[2] = fcs_exp[23:16]; fcs_b[3] = fcs_exp[31:24];
      for (int i = 0; i < 4; i++) begin
        if (cap[68+i] !== fcs_b[i]) begin
          $error("T1 FAIL: FCS[%0d]=0x%02X want 0x%02X", i, cap[68+i], fcs_b[i]); fails++;
        end
      end
      if (fails == 0) $display("T1g PASS: FCS=0x%08X correct", fcs_exp);

      if (ifg !== 12) begin
        $error("T1 FAIL: IFG=%0d want 12", ifg); fails++;
      end else $display("T1h PASS: IFG=12 cycles");
    end

    clk_wait(4);

    // ================================================================
    // T2: 46-byte payload -> 72 GMII bytes, no padding
    // ================================================================
    begin
      logic [7:0]  pl[46];
      logic [7:0]  cap[];
      logic [31:0] fcs_exp;
      logic [7:0]  fcs_b[4];
      int          cnt, tc, ifg;

      for (int i = 0; i < 46; i++) pl[i] = 8'(i + 1);
      send_and_capture(pl, 46, 0, 0, cap, cnt, tc, ifg);

      if (cnt !== 72) begin
        $error("T2 FAIL: GMII byte count=%0d want 72", cnt); fails++;
      end else $display("T2a PASS: 72 bytes (no padding path)");

      for (int i = 0; i < 46; i++) begin
        if (cap[22+i] !== pl[i]) begin
          $error("T2 FAIL: payload[%0d]=0x%02X want 0x%02X", i, cap[22+i], pl[i]); fails++;
        end
      end
      if (fails == 0) $display("T2b PASS: 46 payload bytes correct");

      fcs_exp = frame_fcs(DST_MAC, SRC_MAC, ETYPE, pl, 46);
      fcs_b[0] = fcs_exp[7:0]; fcs_b[1] = fcs_exp[15:8];
      fcs_b[2] = fcs_exp[23:16]; fcs_b[3] = fcs_exp[31:24];
      for (int i = 0; i < 4; i++) begin
        if (cap[68+i] !== fcs_b[i]) begin
          $error("T2 FAIL: FCS[%0d]=0x%02X want 0x%02X", i, cap[68+i], fcs_b[i]); fails++;
        end
      end
      if (fails == 0) $display("T2c PASS: FCS=0x%08X correct", fcs_exp);
    end

    clk_wait(4);

    // ================================================================
    // T3: 100-byte payload -> 126 GMII bytes, FCS correct
    // ================================================================
    begin
      logic [7:0]  pl[100];
      logic [7:0]  cap[];
      logic [31:0] fcs_exp;
      logic [7:0]  fcs_b[4];
      int          cnt, tc, ifg;

      for (int i = 0; i < 100; i++) pl[i] = 8'(i & 8'hFF);
      send_and_capture(pl, 100, 0, 0, cap, cnt, tc, ifg);

      // 8 pre+SFD + 14 hdr + 100 data + 4 FCS = 126
      if (cnt !== 126) begin
        $error("T3 FAIL: GMII byte count=%0d want 126", cnt); fails++;
      end else $display("T3a PASS: 126 GMII bytes for 100B payload");

      fcs_exp = frame_fcs(DST_MAC, SRC_MAC, ETYPE, pl, 100);
      fcs_b[0] = fcs_exp[7:0]; fcs_b[1] = fcs_exp[15:8];
      fcs_b[2] = fcs_exp[23:16]; fcs_b[3] = fcs_exp[31:24];
      for (int i = 0; i < 4; i++) begin
        if (cap[122+i] !== fcs_b[i]) begin
          $error("T3 FAIL: FCS[%0d]=0x%02X want 0x%02X", i, cap[122+i], fcs_b[i]); fails++;
        end
      end
      if (fails == 0) $display("T3b PASS: FCS correct for 100B payload");
    end

    clk_wait(4);

    // ================================================================
    // T4: Meta -> first GMII byte latency: expect 2 cycles
    // ================================================================
    begin
      logic [7:0] pl[10];
      int  lat;
      int  deadline;
      bit  got_txen;

      for (int i = 0; i < 10; i++) pl[i] = 8'(i);

      @(negedge clk);
      s_meta_valid    <= 1'b1;
      s_meta_dst_mac  <= DST_MAC;
      s_meta_src_mac  <= SRC_MAC;
      s_meta_eth_type <= ETYPE;
      s_axis_tdata    <= pl[0];
      s_axis_tvalid   <= 1'b1;
      s_axis_tlast    <= 1'b0;

      // One posedge: DUT (ST_IDLE) captures meta, transitions to ST_PREAMBLE
      @(posedge clk); #1;
      @(negedge clk); s_meta_valid <= 1'b0;

      lat = 0; got_txen = 1'b0;
      repeat (20) begin
        @(posedge clk); #1;
        lat++;
        if (!got_txen && txen_cap) begin
          got_txen = 1'b1;
          if (lat < 2 || lat > 4) begin
            $error("T4 FAIL: meta->first GMII latency=%0d cycles (want 2..4)", lat);
            fails++;
          end else $display("T4 PASS: meta->GMII latency=%0d cycles", lat);
        end
      end
      if (!got_txen) begin $error("T4 FAIL: TXEN never rose"); fails++; end

      // Drain the rest of the frame
      repeat (10) begin
        if (tready_cap && s_axis_tvalid) begin
          @(negedge clk); s_axis_tvalid <= 1'b0;
        end
        @(posedge clk); #1;
      end
      clk_wait(100); // wait for frame to complete
    end

    clk_wait(4);

    // ================================================================
    // T5: Underflow mid-frame -> TXER=1, abort
    // ================================================================
    begin
      logic [7:0] pl[20];
      logic [7:0] cap[];
      int         cnt, tc, ifg;
      int         uf_before;

      for (int i = 0; i < 20; i++) pl[i] = 8'(i);
      uf_before = stat_tx_underflow;

      send_and_capture(pl, 20, 1, 5, cap, cnt, tc, ifg);
      // Drop after 5 fires; TXER should appear

      if (tc == 0) begin
        $error("T5 FAIL: TXER never asserted after underflow"); fails++;
      end else $display("T5 PASS: TXER asserted (%0d cycles) after underflow", tc);

      if (stat_tx_underflow == uf_before) begin
        $error("T5 FAIL: stat_tx_underflow not incremented"); fails++;
      end else $display("T5 PASS: stat_tx_underflow incremented");
    end

    clk_wait(4);

    // ================================================================
    // T6: Back-to-back: second frame follows first after IFG
    // ================================================================
    begin
      logic [7:0]  pl_a[10], pl_b[10];
      logic [7:0]  cap_a[], cap_b[];
      logic [31:0] fcs_a, fcs_b_fcs;
      logic [7:0]  fb[4], fa[4];
      int          cnt_a, cnt_b, tc_a, tc_b, ifg_a, ifg_b;
      int          frames_before;

      for (int i = 0; i < 10; i++) begin pl_a[i] = 8'(i); pl_b[i] = 8'(i+10); end
      frames_before = stat_tx_frames;

      send_and_capture(pl_a, 10, 0, 0, cap_a, cnt_a, tc_a, ifg_a);
      send_and_capture(pl_b, 10, 0, 0, cap_b, cnt_b, tc_b, ifg_b);

      if (cap_a.size() !== 72 || cap_b.size() !== 72) begin
        $error("T6 FAIL: frame sizes %0d/%0d want 72/72", cap_a.size(), cap_b.size());
        fails++;
      end else $display("T6a PASS: both frames 72 bytes");

      fcs_a    = frame_fcs(DST_MAC, SRC_MAC, ETYPE, pl_a, 10);
      fcs_b_fcs = frame_fcs(DST_MAC, SRC_MAC, ETYPE, pl_b, 10);
      fa[0]=fcs_a[7:0]; fa[1]=fcs_a[15:8]; fa[2]=fcs_a[23:16]; fa[3]=fcs_a[31:24];
      fb[0]=fcs_b_fcs[7:0]; fb[1]=fcs_b_fcs[15:8]; fb[2]=fcs_b_fcs[23:16]; fb[3]=fcs_b_fcs[31:24];

      for (int i = 0; i < 4; i++) begin
        if (cap_a[68+i] !== fa[i]) begin
          $error("T6 FAIL: frame_a FCS[%0d]=0x%02X", i, cap_a[68+i]); fails++;
        end
        if (cap_b[68+i] !== fb[i]) begin
          $error("T6 FAIL: frame_b FCS[%0d]=0x%02X", i, cap_b[68+i]); fails++;
        end
      end
      if (fails == 0) $display("T6b PASS: both FCS correct");

      if (stat_tx_frames - frames_before !== 2) begin
        $error("T6 FAIL: stat_tx_frames=%0d (want +2)", stat_tx_frames - frames_before);
        fails++;
      end else $display("T6c PASS: stat_tx_frames +2");
    end

    if (fails == 0) $display("tb_eth_tx_mac: ALL PASS");
    else            $fatal(1, "tb_eth_tx_mac: %0d FAILURES", fails);
    $finish;
  end

endmodule

`endif // TB_ETH_TX_MAC_SV
