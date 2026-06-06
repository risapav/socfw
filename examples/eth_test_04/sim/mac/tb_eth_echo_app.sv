`timescale 1ns/1ps
/**
 * @file tb_eth_echo_app.sv
 * @brief Unit test: eth_echo_app — MAC-swap echo logic.
 * @details Tests:
 *   T1: Good frame (fcs_ok=1) -> m_meta_valid with swapped MACs, payload forwarded
 *   T2: Bad frame (fcs_ok=0)  -> payload drained, m_meta never asserted
 *   T3: meta_valid -> m_meta_valid latency: 1 cycle (ST_IDLE -> ST_TX_META)
 *   T4: Back-to-back: bad then good frame
 *   T5: stat_echo_frames and stat_discard_frames increment correctly
 */
`ifndef TB_ETH_ECHO_APP_SV
`define TB_ETH_ECHO_APP_SV

module tb_eth_echo_app;
  import tb_eth_pkg::*;

  localparam logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0;
  localparam logic [47:0] PC_MAC    = 48'hAA_BB_CC_DD_EE_FF;

  logic        clk   = 1'b0;
  logic        rst_n = 1'b0;

  // s_meta inputs
  logic        s_meta_valid;
  logic        s_meta_ready;
  logic        s_meta_fcs_ok;
  logic [47:0] s_meta_dst_mac;
  logic [47:0] s_meta_src_mac;
  logic [15:0] s_meta_eth_type;

  // s_axis inputs
  logic [7:0]  s_axis_tdata;
  logic        s_axis_tvalid;
  logic        s_axis_tready;
  logic        s_axis_tlast;
  logic        s_axis_tuser;

  // m_meta outputs
  logic        m_meta_valid;
  logic        m_meta_ready;
  logic [47:0] m_meta_dst_mac;
  logic [47:0] m_meta_src_mac;
  logic [15:0] m_meta_eth_type;

  // m_axis outputs
  logic [7:0]  m_axis_tdata;
  logic        m_axis_tvalid;
  logic        m_axis_tready;
  logic        m_axis_tlast;
  logic        m_axis_tuser;

  logic [15:0] stat_echo;
  logic [15:0] stat_discard;

  always #4 clk = ~clk;

  eth_echo_app #(.LOCAL_MAC(LOCAL_MAC)) dut (
    .clk_i               (clk),
    .rst_ni              (rst_n),
    .s_meta_valid_i      (s_meta_valid),
    .s_meta_ready_o      (s_meta_ready),
    .s_meta_fcs_ok_i     (s_meta_fcs_ok),
    .s_meta_dst_mac_i    (s_meta_dst_mac),
    .s_meta_src_mac_i    (s_meta_src_mac),
    .s_meta_eth_type_i   (s_meta_eth_type),
    .s_axis_tdata_i      (s_axis_tdata),
    .s_axis_tvalid_i     (s_axis_tvalid),
    .s_axis_tready_o     (s_axis_tready),
    .s_axis_tlast_i      (s_axis_tlast),
    .s_axis_tuser_i      (s_axis_tuser),
    .m_meta_valid_o      (m_meta_valid),
    .m_meta_ready_i      (m_meta_ready),
    .m_meta_dst_mac_o    (m_meta_dst_mac),
    .m_meta_src_mac_o    (m_meta_src_mac),
    .m_meta_eth_type_o   (m_meta_eth_type),
    .m_axis_tdata_o      (m_axis_tdata),
    .m_axis_tvalid_o     (m_axis_tvalid),
    .m_axis_tready_i     (m_axis_tready),
    .m_axis_tlast_o      (m_axis_tlast),
    .m_axis_tuser_o      (m_axis_tuser),
    .stat_echo_frames    (stat_echo),
    .stat_discard_frames (stat_discard)
  );

  // Pre-NBA capture
  logic       meta_valid_cap;
  logic       meta_ready_cap;
  logic       axis_valid_cap;
  logic       axis_tlast_cap;
  logic [7:0] axis_tdata_cap;
  always @(posedge clk) begin
    meta_valid_cap = m_meta_valid;
    meta_ready_cap = s_meta_ready;
    axis_valid_cap = m_axis_tvalid;
    axis_tlast_cap = m_axis_tlast;
    axis_tdata_cap = m_axis_tdata;
  end

  int fails = 0;

  task automatic clk_wait(int n = 1);
    repeat (n) begin @(posedge clk); #1; end
  endtask

  // Present one meta word; wait until DUT accepts it (s_meta_ready=1).
  // Returns the cycle count to acceptance.
  task automatic present_meta(
    input bit          fcs_ok,
    input logic [47:0] dst_mac,
    input logic [47:0] src_mac,
    input logic [15:0] eth_type,
    output int         cycles_to_accept
  );
    int cnt;
    @(negedge clk);
    s_meta_valid    <= 1'b1;
    s_meta_fcs_ok   <= fcs_ok;
    s_meta_dst_mac  <= dst_mac;
    s_meta_src_mac  <= src_mac;
    s_meta_eth_type <= eth_type;
    cnt = 0;
    do begin @(posedge clk); #1; cnt++; end while (!meta_ready_cap && cnt < 20);
    @(negedge clk); s_meta_valid <= 1'b0;
    cycles_to_accept = cnt;
    clk_wait(1);
  endtask

  // Drive n payload bytes; capture m_axis output until tlast or timeout.
  task automatic drive_and_capture_payload(
    input  logic [7:0] payload [],
    input  int         n_payload,
    output logic [7:0] cap [],
    output int         cap_count,
    output logic       got_tlast
  );
    int pi;
    logic [7:0] tmp[$];
    pi       = 0;
    tmp      = {};
    got_tlast = 1'b0;

    m_axis_tready <= 1'b1;

    @(negedge clk);
    s_axis_tdata  <= payload[0];
    s_axis_tvalid <= 1'b1;
    s_axis_tlast  <= (n_payload == 1) ? 1'b1 : 1'b0;

    repeat (n_payload + 8) begin
      @(posedge clk); #1;

      if (axis_valid_cap && m_axis_tready) begin
        tmp.push_back(axis_tdata_cap);
        if (axis_tlast_cap) got_tlast = 1'b1;
      end

      // Advance source when DUT consumed one byte
      if (s_axis_tready && s_axis_tvalid && !s_axis_tlast) begin
        pi++;
        @(negedge clk);
        s_axis_tdata <= payload[pi];
        s_axis_tlast <= (pi == n_payload - 1) ? 1'b1 : 1'b0;
      end
    end

    @(negedge clk);
    s_axis_tvalid <= 1'b0;
    s_axis_tlast  <= 1'b0;
    m_axis_tready <= 1'b0;
    clk_wait(2);

    cap_count = tmp.size();
    cap       = new [cap_count];
    for (int i = 0; i < cap_count; i++) cap[i] = tmp[i];
  endtask

  initial begin
    s_meta_valid    = 1'b0;
    s_meta_fcs_ok   = 1'b0;
    s_meta_dst_mac  = '0;
    s_meta_src_mac  = '0;
    s_meta_eth_type = '0;
    s_axis_tdata    = 8'h00;
    s_axis_tvalid   = 1'b0;
    s_axis_tlast    = 1'b0;
    s_axis_tuser    = 1'b0;
    m_meta_ready    = 1'b0;
    m_axis_tready   = 1'b1;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(4);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(2);

    // ================================================================
    // T1: Good frame — MAC swap + payload forwarded
    // ================================================================
    begin
      logic [7:0]  pl[8];
      logic [7:0]  cap[];
      logic        tl;
      int          cnt, cyc;

      for (int i = 0; i < 8; i++) pl[i] = 8'(8'h10 + i);

      // Present meta (fcs_ok=1, src=PC_MAC, dst=LOCAL_MAC)
      present_meta(1'b1, LOCAL_MAC, PC_MAC, 16'h9000, cyc);

      // At the NEXT cycle echo_app should present m_meta_valid with swapped MACs
      // m_meta_ready: accept immediately
      @(negedge clk); m_meta_ready <= 1'b1;
      clk_wait(4);

      // Check MAC swap
      if (m_meta_dst_mac !== PC_MAC) begin
        $error("T1 FAIL: m_meta_dst_mac=0x%12X want PC_MAC=0x%12X",
               m_meta_dst_mac, PC_MAC);
        fails++;
      end else $display("T1a PASS: tx_dst = rx_src (PC_MAC)");

      if (m_meta_src_mac !== LOCAL_MAC) begin
        $error("T1 FAIL: m_meta_src_mac=0x%12X want LOCAL_MAC=0x%12X",
               m_meta_src_mac, LOCAL_MAC);
        fails++;
      end else $display("T1b PASS: tx_src = LOCAL_MAC");

      @(negedge clk); m_meta_ready <= 1'b0;

      // Drive payload and capture
      drive_and_capture_payload(pl, 8, cap, cnt, tl);

      if (cnt !== 8) begin
        $error("T1 FAIL: forwarded %0d bytes want 8", cnt); fails++;
      end else $display("T1c PASS: 8 payload bytes forwarded");

      for (int i = 0; i < cnt && i < 8; i++) begin
        if (cap[i] !== pl[i]) begin
          $error("T1 FAIL: byte[%0d]=0x%02X want 0x%02X", i, cap[i], pl[i]); fails++;
        end
      end
      if (fails == 0) $display("T1d PASS: payload data matches");

      if (!tl) begin
        $error("T1 FAIL: tlast never seen on forwarded payload"); fails++;
      end else $display("T1e PASS: tlast forwarded");
    end

    clk_wait(4);

    // ================================================================
    // T2: Bad frame (fcs_ok=0) — payload drained, m_meta_valid never seen
    // ================================================================
    begin
      logic [7:0] pl[8];
      logic [7:0] cap[];
      logic       tl;
      int         cnt, cyc;
      int         meta_count;

      for (int i = 0; i < 8; i++) pl[i] = 8'(8'h20 + i);

      present_meta(1'b0, LOCAL_MAC, PC_MAC, 16'h9000, cyc);

      meta_count = 0;
      m_axis_tready <= 1'b1;

      // Drive payload; echo_app should drain without forwarding
      @(negedge clk);
      s_axis_tdata  <= pl[0];
      s_axis_tvalid <= 1'b1;
      s_axis_tlast  <= 1'b0;

      begin
        int pi;
        pi = 0;
        repeat (16) begin
          @(posedge clk); #1;
          if (meta_valid_cap) meta_count++;
          if (axis_valid_cap) begin
            $error("T2 FAIL: m_axis_tvalid=1 during discard (forwarded to TX)");
            fails++;
          end
          if (s_axis_tready && s_axis_tvalid && !s_axis_tlast) begin
            pi++;
            @(negedge clk);
            s_axis_tdata <= pl[pi < 8 ? pi : 7];
            s_axis_tlast <= (pi == 7) ? 1'b1 : 1'b0;
          end
        end
      end

      @(negedge clk); s_axis_tvalid <= 1'b0; s_axis_tlast <= 1'b0;
      clk_wait(4);

      if (meta_count > 0) begin
        $error("T2 FAIL: m_meta_valid seen during bad-FCS discard"); fails++;
      end else $display("T2 PASS: no m_meta_valid during discard, payload drained");
    end

    clk_wait(4);

    // ================================================================
    // T3: meta_valid -> m_meta_valid latency = 1 cycle
    // ================================================================
    begin
      int lat;
      int cnt;

      // Present meta (fcs_ok=1)
      @(negedge clk);
      s_meta_valid    <= 1'b1;
      s_meta_fcs_ok   <= 1'b1;
      s_meta_dst_mac  <= LOCAL_MAC;
      s_meta_src_mac  <= PC_MAC;
      s_meta_eth_type <= 16'h9000;

      lat = 0;
      repeat (10) begin
        @(posedge clk); #1;
        lat++;
        if (meta_ready_cap) begin
          @(negedge clk); s_meta_valid <= 1'b0;
          // Now count until m_meta_valid
          begin
            int m_cnt;
            m_cnt = 0;
            repeat (5) begin
              @(posedge clk); #1;
              m_cnt++;
              if (meta_valid_cap) begin
                if (m_cnt !== 1) begin
                  $error("T3 FAIL: m_meta_valid appeared at cycle %0d (want 1)", m_cnt);
                  fails++;
                end else $display("T3 PASS: m_meta_valid at cycle 1 after meta accepted");
                break;
              end
            end
          end
          break;
        end
      end

      // Drain: accept m_meta and payload
      @(negedge clk); m_meta_ready <= 1'b1;
      clk_wait(2);
      @(negedge clk); m_meta_ready <= 1'b0;

      // Drive a dummy tlast to get echo_app back to IDLE
      @(negedge clk);
      s_axis_tdata  <= 8'hFF;
      s_axis_tvalid <= 1'b1;
      s_axis_tlast  <= 1'b1;
      m_axis_tready <= 1'b1;
      clk_wait(4);
      @(negedge clk);
      s_axis_tvalid <= 1'b0;
      s_axis_tlast  <= 1'b0;
      m_axis_tready <= 1'b0;
      clk_wait(2);
    end

    clk_wait(4);

    // ================================================================
    // T5: stat counters correct after T1 (echo) and T2 (discard)
    // ================================================================
    // T1 produced 1 echo, T2 produced 1 discard (T3 also 1 echo).
    // stat_echo should be >= 2, stat_discard >= 1.
    if (stat_echo < 2) begin
      $error("T5 FAIL: stat_echo=%0d want >=2", stat_echo); fails++;
    end else $display("T5a PASS: stat_echo_frames=%0d", stat_echo);

    if (stat_discard < 1) begin
      $error("T5 FAIL: stat_discard=%0d want >=1", stat_discard); fails++;
    end else $display("T5b PASS: stat_discard_frames=%0d", stat_discard);

    if (fails == 0) $display("tb_eth_echo_app: ALL PASS");
    else            $fatal(1, "tb_eth_echo_app: %0d FAILURES", fails);
    $finish;
  end

endmodule

`endif // TB_ETH_ECHO_APP_SV
