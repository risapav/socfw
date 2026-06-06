`timescale 1ns/1ps
/**
 * @file tb_rx_tx_loopback.sv
 * @brief Integration test: eth_rx_mac -> FIFOs -> eth_echo_app -> eth_tx_mac.
 * @details Single clock (RX=TX=125 MHz). async_fifo in single-clock mode adds
 *   ~2-cycle pointer latency (Gray-code synchronizers).
 *
 *   Tests:
 *   I1: 10-byte payload to LOCAL_MAC -> TX GMII has swapped MACs, correct FCS
 *   I2: Frame to wrong DST MAC -> TX stays idle (frame discarded)
 *   I3: Broadcast frame -> TX GMII has swapped MACs, correct FCS
 *   I4: Stream byte count: only payload bytes forwarded, header+FCS stripped
 */
`ifndef TB_RX_TX_LOOPBACK_SV
`define TB_RX_TX_LOOPBACK_SV

module tb_rx_tx_loopback;
  import tb_eth_pkg::*;

  localparam logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0;
  localparam logic [47:0] PC_MAC    = 48'hAA_BB_CC_DD_EE_FF;
  localparam logic [15:0] ETYPE     = 16'h9000;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #4 clk = ~clk; // 125 MHz

  // GMII RX inputs
  logic [7:0] gmii_rxd;
  logic       gmii_rxdv;
  logic       gmii_rxer;

  // GMII TX outputs
  logic [7:0] gmii_txd;
  logic       gmii_txen;
  logic       gmii_txer;

  // -------------------------------------------------------------------------
  // eth_rx_mac
  // -------------------------------------------------------------------------
  logic [7:0]  rx_tdata;
  logic        rx_tvalid;
  logic        rx_tready;
  logic        rx_tlast;
  logic        rx_tuser;

  logic        rx_meta_valid;
  logic        rx_meta_ready;
  logic [47:0] rx_meta_dst;
  logic [47:0] rx_meta_src;
  logic [15:0] rx_meta_etype;
  logic        rx_meta_fcs_ok;

  eth_rx_mac #(
    .LOCAL_MAC       (LOCAL_MAC),
    .ACCEPT_BROADCAST(1'b1),
    .MAX_FRAME_LEN   (1518)
  ) u_rx_mac (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .gmii_rx_dv_i   (gmii_rxdv),
    .gmii_rx_er_i   (gmii_rxer),
    .gmii_rxd_i     (gmii_rxd),
    .m_axis_tdata   (rx_tdata),
    .m_axis_tvalid  (rx_tvalid),
    .m_axis_tready  (rx_tready),
    .m_axis_tlast   (rx_tlast),
    .m_axis_tuser   (rx_tuser),
    .m_meta_valid   (rx_meta_valid),
    .m_meta_ready   (rx_meta_ready),
    .m_meta_dst_mac (rx_meta_dst),
    .m_meta_src_mac (rx_meta_src),
    .m_meta_eth_type(rx_meta_etype),
    .m_meta_fcs_ok  (rx_meta_fcs_ok),
    .m_meta_mac_ok  (),
    .stat_overflow  (),
    .stat_rx_frames (),
    .stat_rx_drop   ()
  );

  // -------------------------------------------------------------------------
  // Payload async FIFO: DATA_WIDTH=10 ({tuser,tlast,tdata}), DEPTH=64
  // -------------------------------------------------------------------------
  localparam int PW = 10;
  logic [PW-1:0] pfifo_wr;
  logic          pfifo_wr_ready;
  logic [PW-1:0] pfifo_rd;
  logic          pfifo_rd_valid;
  logic          pfifo_rd_ready;

  logic [7:0] echo_tdata;
  logic       echo_tlast;
  logic       echo_tuser;

  assign pfifo_wr = {rx_tuser, rx_tlast, rx_tdata};
  assign rx_tready = pfifo_wr_ready;
  assign {echo_tuser, echo_tlast, echo_tdata} = pfifo_rd;

  async_fifo #(.DATA_WIDTH(PW), .DEPTH(64)) u_pfifo (
    .wr_clk_i   (clk), .wr_rst_ni  (rst_n),
    .wr_data_i  (pfifo_wr),  .wr_valid_i (rx_tvalid),
    .wr_ready_o (pfifo_wr_ready),
    .rd_clk_i   (clk), .rd_rst_ni  (rst_n),
    .rd_data_o  (pfifo_rd),  .rd_valid_o (pfifo_rd_valid),
    .rd_ready_i (pfifo_rd_ready)
  );

  // -------------------------------------------------------------------------
  // Meta async FIFO: DATA_WIDTH=113, DEPTH=8
  // -------------------------------------------------------------------------
  localparam int MW = 113;
  logic [MW-1:0] mfifo_wr;
  logic          mfifo_wr_ready;
  logic [MW-1:0] mfifo_rd;
  logic          mfifo_rd_valid;
  logic          mfifo_rd_ready;

  logic        meta_fcs_ok;
  logic [47:0] meta_dst;
  logic [47:0] meta_src;
  logic [15:0] meta_etype;

  assign mfifo_wr       = {rx_meta_fcs_ok, rx_meta_dst, rx_meta_src, rx_meta_etype};
  assign rx_meta_ready  = mfifo_wr_ready;
  assign {meta_fcs_ok, meta_dst, meta_src, meta_etype} = mfifo_rd;

  async_fifo #(.DATA_WIDTH(MW), .DEPTH(8)) u_mfifo (
    .wr_clk_i   (clk), .wr_rst_ni  (rst_n),
    .wr_data_i  (mfifo_wr),  .wr_valid_i (rx_meta_valid),
    .wr_ready_o (mfifo_wr_ready),
    .rd_clk_i   (clk), .rd_rst_ni  (rst_n),
    .rd_data_o  (mfifo_rd),  .rd_valid_o (mfifo_rd_valid),
    .rd_ready_i (mfifo_rd_ready)
  );

  // -------------------------------------------------------------------------
  // eth_echo_app
  // -------------------------------------------------------------------------
  logic        txm_meta_valid;
  logic        txm_meta_ready;
  logic [47:0] txm_meta_dst;
  logic [47:0] txm_meta_src;
  logic [15:0] txm_meta_etype;

  logic [7:0]  txm_tdata;
  logic        txm_tvalid;
  logic        txm_tready;
  logic        txm_tlast;
  logic        txm_tuser;

  eth_echo_app #(.LOCAL_MAC(LOCAL_MAC)) u_echo (
    .clk_i               (clk),
    .rst_ni              (rst_n),
    .s_meta_valid_i      (mfifo_rd_valid),
    .s_meta_ready_o      (mfifo_rd_ready),
    .s_meta_fcs_ok_i     (meta_fcs_ok),
    .s_meta_dst_mac_i    (meta_dst),
    .s_meta_src_mac_i    (meta_src),
    .s_meta_eth_type_i   (meta_etype),
    .s_axis_tdata_i      (echo_tdata),
    .s_axis_tvalid_i     (pfifo_rd_valid),
    .s_axis_tready_o     (pfifo_rd_ready),
    .s_axis_tlast_i      (echo_tlast),
    .s_axis_tuser_i      (echo_tuser),
    .m_meta_valid_o      (txm_meta_valid),
    .m_meta_ready_i      (txm_meta_ready),
    .m_meta_dst_mac_o    (txm_meta_dst),
    .m_meta_src_mac_o    (txm_meta_src),
    .m_meta_eth_type_o   (txm_meta_etype),
    .m_axis_tdata_o      (txm_tdata),
    .m_axis_tvalid_o     (txm_tvalid),
    .m_axis_tready_i     (txm_tready),
    .m_axis_tlast_o      (txm_tlast),
    .m_axis_tuser_o      (txm_tuser),
    .stat_echo_frames    (),
    .stat_discard_frames ()
  );

  // -------------------------------------------------------------------------
  // eth_tx_mac
  // -------------------------------------------------------------------------
  eth_tx_mac #(.IFG_CYCLES(12)) u_tx_mac (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .s_meta_valid_i    (txm_meta_valid),
    .s_meta_ready_o    (txm_meta_ready),
    .s_meta_dst_mac_i  (txm_meta_dst),
    .s_meta_src_mac_i  (txm_meta_src),
    .s_meta_eth_type_i (txm_meta_etype),
    .s_axis_tdata_i    (txm_tdata),
    .s_axis_tvalid_i   (txm_tvalid),
    .s_axis_tready_o   (txm_tready),
    .s_axis_tlast_i    (txm_tlast),
    .s_axis_tuser_i    (txm_tuser),
    .gmii_txd_o        (gmii_txd),
    .gmii_tx_en_o      (gmii_txen),
    .gmii_tx_er_o      (gmii_txer),
    .stat_tx_frames    (),
    .stat_tx_underflow ()
  );

  // Pre-NBA capture
  logic [7:0] txd_cap;
  logic       txen_cap;
  logic       txer_cap;
  always @(posedge clk) begin
    txd_cap  = gmii_txd;
    txen_cap = gmii_txen;
    txer_cap = gmii_txer;
  end

  int fails = 0;

  task automatic clk_wait(int n = 1);
    repeat (n) begin @(posedge clk); #1; end
  endtask

  // Drive a complete Ethernet frame on GMII RX.
  task automatic drive_rx_frame(
    input logic [47:0] dst_mac,
    input logic [47:0] src_mac,
    input logic [7:0]  payload [],
    input int          n_payload,
    input bit          corrupt_fcs
  );
    logic [7:0] frame[];
    logic [7:0] hdr[14];
    logic [31:0] fcs;
    logic [7:0]  fcs_b[4];

    build_eth_hdr(dst_mac, src_mac, ETYPE, hdr);
    frame = new [14 + n_payload];
    for (int i = 0; i < 14;       i++) frame[i]     = hdr[i];
    for (int i = 0; i < n_payload; i++) frame[14+i]  = payload[i];

    fcs = crc32(frame, 14 + n_payload);
    fcs_b[0] = fcs[7:0]; fcs_b[1] = fcs[15:8];
    fcs_b[2] = fcs[23:16]; fcs_b[3] = fcs[31:24];
    if (corrupt_fcs) fcs_b[3] ^= 8'hFF;

    // Preamble
    for (int i = 0; i < 7; i++) begin
      @(negedge clk); gmii_rxd = 8'h55; gmii_rxdv = 1'b1; gmii_rxer = 1'b0;
    end
    // SFD
    @(negedge clk); gmii_rxd = 8'hD5;
    // Header + payload
    for (int i = 0; i < 14 + n_payload; i++) begin
      @(negedge clk); gmii_rxd = frame[i];
    end
    // FCS
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); gmii_rxd = fcs_b[i];
    end
    // Drop DV
    @(negedge clk); gmii_rxd = 8'h00; gmii_rxdv = 1'b0;
  endtask

  // Capture TX GMII until TXEN=0 after a frame, or timeout.
  task automatic capture_tx_frame(
    output logic [7:0] cap [],
    output int         cap_count
  );
    logic [7:0] tmp[$];
    int         timeout;

    tmp     = {};
    timeout = 0;

    // Wait for TXEN (with timeout)
    while (!txen_cap && timeout < 300) begin
      @(posedge clk); #1;
      timeout++;
    end

    if (!txen_cap) begin
      cap_count = 0;
      cap       = {};
      return;
    end

    // Capture while TXEN=1
    while (txen_cap) begin
      tmp.push_back(txd_cap);
      @(posedge clk); #1;
    end

    cap_count = tmp.size();
    cap       = new [cap_count];
    for (int i = 0; i < cap_count; i++) cap[i] = tmp[i];
  endtask

  initial begin
    gmii_rxd  = 8'h00;
    gmii_rxdv = 1'b0;
    gmii_rxer = 1'b0;

    @(negedge clk); rst_n = 1'b0;
    clk_wait(8);
    @(negedge clk); rst_n = 1'b1;
    clk_wait(8);

    // ================================================================
    // I1: 10-byte payload to LOCAL_MAC
    //     Expected TX: dst=PC_MAC, src=LOCAL_MAC, 72 bytes, correct FCS
    // ================================================================
    begin
      logic [7:0]  pl[10];
      logic [7:0]  cap[];
      logic [7:0]  hdr_exp[14];
      logic [31:0] fcs_exp;
      logic [7:0]  fcs_b[4];
      int          cnt;

      for (int i = 0; i < 10; i++) pl[i] = 8'(i + 1);

      drive_rx_frame(LOCAL_MAC, PC_MAC, pl, 10, 0);
      capture_tx_frame(cap, cnt);

      if (cnt == 0) begin
        $error("I1 FAIL: no TX frame received (TXEN never rose)"); fails++;
      end else if (cnt !== 72) begin
        $error("I1 FAIL: TX byte count=%0d want 72", cnt); fails++;
      end else $display("I1a PASS: 72 TX GMII bytes");

      if (cnt >= 8) begin
        // Preamble
        for (int i = 0; i < 7; i++) begin
          if (cap[i] !== 8'h55) begin
            $error("I1 FAIL: preamble[%0d]=0x%02X want 0x55", i, cap[i]); fails++;
          end
        end
        if (cap[7] !== 8'hD5) begin
          $error("I1 FAIL: SFD=0x%02X want 0xD5", cap[7]); fails++;
        end
        if (fails == 0) $display("I1b PASS: preamble+SFD OK");
      end

      if (cnt >= 22) begin
        // Header: dst=PC_MAC, src=LOCAL_MAC
        build_eth_hdr(PC_MAC, LOCAL_MAC, ETYPE, hdr_exp);
        for (int i = 0; i < 14; i++) begin
          if (cap[8+i] !== hdr_exp[i]) begin
            $error("I1 FAIL: hdr[%0d]=0x%02X want 0x%02X", i, cap[8+i], hdr_exp[i]);
            fails++;
          end
        end
        if (fails == 0) $display("I1c PASS: MAC-swapped header OK (dst=PC, src=LOCAL)");
      end

      // FCS
      if (cnt == 72) begin
        fcs_exp = frame_fcs(PC_MAC, LOCAL_MAC, ETYPE, pl, 10);
        fcs_b[0] = fcs_exp[7:0]; fcs_b[1] = fcs_exp[15:8];
        fcs_b[2] = fcs_exp[23:16]; fcs_b[3] = fcs_exp[31:24];
        for (int i = 0; i < 4; i++) begin
          if (cap[68+i] !== fcs_b[i]) begin
            $error("I1 FAIL: FCS[%0d]=0x%02X want 0x%02X", i, cap[68+i], fcs_b[i]);
            fails++;
          end
        end
        if (fails == 0) $display("I1d PASS: FCS=0x%08X correct", fcs_exp);
      end
    end

    clk_wait(30);

    // ================================================================
    // I2: Frame to wrong DST MAC -> discarded, no TX output
    // ================================================================
    begin
      logic [47:0] wrong_dst;
      logic [7:0]  pl[10];
      logic [7:0]  cap[];
      int          cnt;
      wrong_dst = 48'hDE_AD_BE_EF_00_01;
      for (int i = 0; i < 10; i++) pl[i] = 8'(i + 8'h10);
      drive_rx_frame(wrong_dst, PC_MAC, pl, 10, 0);

      // Wait a fixed number of cycles; TXEN should never rise
      cap_count: begin
        int timeout;
        timeout = 0;
        cnt     = 0;
        while (timeout < 200) begin
          @(posedge clk); #1;
          timeout++;
          if (txen_cap) cnt++;
        end
      end

      if (cnt > 0) begin
        $error("I2 FAIL: TX GMII active (%0d cycles) for discard frame", cnt); fails++;
      end else $display("I2 PASS: TX idle for wrong-DST frame (discarded)");
    end

    clk_wait(30);

    // ================================================================
    // I3: Broadcast frame -> TX output with MAC swap (dst=PC_MAC)
    // ================================================================
    begin
      logic [47:0] bcast;
      logic [7:0]  pl[10];
      logic [7:0]  cap[];
      logic [7:0]  hdr_exp[14];
      int          cnt;
      bcast = 48'hFF_FF_FF_FF_FF_FF;
      for (int i = 0; i < 10; i++) pl[i] = 8'(i + 8'h20);

      drive_rx_frame(bcast, PC_MAC, pl, 10, 0);
      capture_tx_frame(cap, cnt);

      if (cnt == 0) begin
        $error("I3 FAIL: no TX frame for broadcast"); fails++;
      end else if (cnt !== 72) begin
        $error("I3 FAIL: TX count=%0d want 72", cnt); fails++;
      end else $display("I3a PASS: broadcast echoed, 72 bytes");

      if (cnt >= 22) begin
        build_eth_hdr(PC_MAC, LOCAL_MAC, ETYPE, hdr_exp);
        for (int i = 0; i < 14; i++) begin
          if (cap[8+i] !== hdr_exp[i]) begin
            $error("I3 FAIL: hdr[%0d]=0x%02X want 0x%02X", i, cap[8+i], hdr_exp[i]);
            fails++;
          end
        end
        if (fails == 0) $display("I3b PASS: broadcast echo header OK");
      end
    end

    clk_wait(30);

    // ================================================================
    // I4: Back-to-back: second frame processed after first IFG
    // ================================================================
    begin
      logic [7:0] pl_a[20], pl_b[20];
      logic [7:0] cap_a[], cap_b[];
      int         cnt_a, cnt_b;

      for (int i = 0; i < 20; i++) begin pl_a[i] = 8'(i); pl_b[i] = 8'(i + 20); end

      drive_rx_frame(LOCAL_MAC, PC_MAC, pl_a, 20, 0);
      capture_tx_frame(cap_a, cnt_a);
      clk_wait(20); // IFG gap
      drive_rx_frame(LOCAL_MAC, PC_MAC, pl_b, 20, 0);
      capture_tx_frame(cap_b, cnt_b);

      if (cnt_a < 72 || cnt_b < 72) begin
        $error("I4 FAIL: frame sizes %0d/%0d want 72/72 each (20B payload pads to 46B)", cnt_a, cnt_b); fails++;
      end else $display("I4 PASS: back-to-back frames, %0d and %0d bytes", cnt_a, cnt_b);
    end

    if (fails == 0) $display("tb_rx_tx_loopback: ALL PASS");
    else            $fatal(1, "tb_rx_tx_loopback: %0d FAILURES", fails);
    $finish;
  end

endmodule

`endif // TB_RX_TX_LOOPBACK_SV
