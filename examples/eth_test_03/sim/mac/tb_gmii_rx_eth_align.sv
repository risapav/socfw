`timescale 1ns/1ps
/**
 * @file tb_gmii_rx_eth_align.sv
 * @brief Integration test: gmii_rx_mac -> eth_header_parser byte-alignment.
 * @details Verifies that preamble+SFD are correctly stripped so that dst_mac
 *   bytes arrive at eth_header_parser in the right order. Uses the exact
 *   Ethernet header captured from real HW tcpdump to detect byte-shift bugs:
 *
 *   PASS:             dst_mac = 00:0A:35:01:FE:C0
 *   SFD leak (+1):    dst_mac = D5:00:0A:35:01:FE
 *   First byte lost:  dst_mac = 0A:35:01:FE:C0:E0
 *
 * Tests:
 *   T1 : hdr_done_pulse fires for a complete frame
 *   T2 : dbg_dst_mac_o == 48'h000A3501FEC0 (alignment correct)
 *   T3 : hdr_accept_pulse fires (LOCAL_MAC match)
 *   T3b: hdr_drop_pulse silent for LOCAL_MAC frame
 *   T4 : non-matching dst_mac -> hdr_drop fires, hdr_accept silent
 */

`ifndef TB_GMII_RX_ETH_ALIGN_SV
`define TB_GMII_RX_ETH_ALIGN_SV

`default_nettype none

module tb_gmii_rx_eth_align;
  import tb_eth_pkg::*;

  // ── Clock / Reset ────────────────────────────────────────────────────
  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #4 clk = ~clk;  // 125 MHz

  // ── GMII signals ─────────────────────────────────────────────────────
  logic [7:0] gmii_rxd   = 8'h00;
  logic       gmii_rx_dv = 1'b0;
  logic       gmii_rx_er = 1'b0;

  // ── AXI-S bus: gmii_rx_mac -> eth_header_parser ──────────────────────
  logic [7:0] mac_tdata;
  logic       mac_tvalid;
  logic       mac_tready;   // driven by eth_header_parser.s_axis_tready
  logic       mac_tlast;
  logic       mac_tuser;

  // ── eth_header_parser outputs ─────────────────────────────────────────
  logic [47:0] dbg_dst_mac;
  logic        dbg_mac_accept;
  logic        hdr_done_pulse;
  logic        hdr_accept_pulse;
  logic        hdr_drop_pulse;

  // ── DUT: gmii_rx_mac ─────────────────────────────────────────────────
  gmii_rx_mac #(.EXPECT_PREAMBLE(1'b1)) u_mac (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .gmii_rxd_i   (gmii_rxd),
    .gmii_rx_dv_i (gmii_rx_dv),
    .gmii_rx_er_i (gmii_rx_er),
    .m_axis_tdata (mac_tdata),
    .m_axis_tvalid(mac_tvalid),
    .m_axis_tready(mac_tready),
    .m_axis_tlast (mac_tlast),
    .m_axis_tuser (mac_tuser),
    .frame_done_o ()
  );

  // ── DUT: eth_header_parser ───────────────────────────────────────────
  // LOCAL_MAC = 00:0A:35:01:FE:C0 — exact board MAC from HW test
  eth_header_parser u_l2 (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .local_mac_i       (48'h000A3501FEC0),
    .accept_broadcast_i(1'b0),
    .promiscuous_i     (1'b0),
    .s_axis_tdata      (mac_tdata),
    .s_axis_tvalid     (mac_tvalid),
    .s_axis_tready     (mac_tready),
    .s_axis_tlast      (mac_tlast),
    .s_axis_tuser      (mac_tuser),
    .m_axis_tdata      (),
    .m_axis_tvalid     (),
    .m_axis_tready     (1'b1),
    .m_axis_tlast      (),
    .m_axis_tuser      (),
    .rx_dst_mac_o      (),
    .rx_src_mac_o      (),
    .rx_ethertype_o    (),
    .hdr_valid_o       (),
    .drop_o            (),
    .hdr_done_pulse_o  (hdr_done_pulse),
    .hdr_accept_pulse_o(hdr_accept_pulse),
    .hdr_drop_pulse_o  (hdr_drop_pulse),
    .dbg_dst_mac_o     (dbg_dst_mac),
    .dbg_mac_accept_o  (dbg_mac_accept)
  );

  // ── Pulse latches ─────────────────────────────────────────────────────
  // Use pulse signals directly (no pre-NBA cap) — both this block and the
  // parser's always_ff evaluate pre-NBA at the same posedge, so this FF
  // correctly samples the pulse one cycle after it fires.
  logic clear_latches = 1'b0;
  logic hdr_done_seen, hdr_accept_seen, hdr_drop_seen;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || clear_latches) begin
      hdr_done_seen   <= 1'b0;
      hdr_accept_seen <= 1'b0;
      hdr_drop_seen   <= 1'b0;
    end else begin
      if (hdr_done_pulse)   hdr_done_seen   <= 1'b1;
      if (hdr_accept_pulse) hdr_accept_seen <= 1'b1;
      if (hdr_drop_pulse)   hdr_drop_seen   <= 1'b1;
    end
  end

  int fails = 0;

  task automatic clk_clk(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  // Drive a GMII frame: 7-byte preamble + SFD (D5) + data[0..data_len-1]
  task automatic drive_gmii_frame(
    input logic [7:0] data[],
    input int         data_len
  );
    // 7-byte preamble
    for (int i = 0; i < 7; i++) begin
      @(negedge clk); gmii_rxd = 8'h55; gmii_rx_dv = 1'b1;
      @(posedge clk); #1;
    end
    // SFD — consumed by RX_SFD state, must NOT appear in output
    @(negedge clk); gmii_rxd = 8'hD5; gmii_rx_dv = 1'b1;
    @(posedge clk); #1;
    // Payload data
    for (int i = 0; i < data_len; i++) begin
      @(negedge clk); gmii_rxd = data[i]; gmii_rx_dv = 1'b1;
      @(posedge clk); #1;
    end
    // Drop DV; flush pipeline and give parser time to settle
    @(negedge clk); gmii_rxd = 8'h00; gmii_rx_dv = 1'b0;
    clk_clk(16);
  endtask

  // Clear pulse latches, send a frame, wait for parser to settle.
  task automatic run_frame(
    input logic [7:0] data[],
    input int         data_len
  );
    // Synchronous clear: hold for 2 posedges to guarantee the always_ff sees it
    @(negedge clk); clear_latches = 1'b1;
    clk_clk(2);
    @(negedge clk); clear_latches = 1'b0;
    clk_clk(1);
    drive_gmii_frame(data, data_len);
    clk_clk(8);
  endtask

  initial begin
    @(negedge clk); rst_n = 1'b0;
    clk_clk(3);
    @(negedge clk); rst_n = 1'b1;
    clk_clk(4);

    // ── Frame 1: exact tcpdump header — dst=00:0A:35:01:FE:C0 ─────────
    // src=E0:4F:43:5B:59:3C, ethertype=0800, 4 payload bytes
    begin
      logic [7:0] frame[18];
      frame[0]  = 8'h00; frame[1]  = 8'h0A; frame[2]  = 8'h35; frame[3]  = 8'h01;
      frame[4]  = 8'hFE; frame[5]  = 8'hC0;  // dst_mac = 00:0A:35:01:FE:C0
      frame[6]  = 8'hE0; frame[7]  = 8'h4F; frame[8]  = 8'h43; frame[9]  = 8'h5B;
      frame[10] = 8'h59; frame[11] = 8'h3C;  // src_mac = E0:4F:43:5B:59:3C
      frame[12] = 8'h08; frame[13] = 8'h00;  // ethertype = IPv4
      frame[14] = 8'h45; frame[15] = 8'h00; frame[16] = 8'hA1; frame[17] = 8'hA2;

      run_frame(frame, 18);

      // T1: hdr_done fired
      if (!hdr_done_seen) begin
        $error("T1 FAIL: hdr_done_pulse never fired");
        fails++;
      end else
        $display("T1 PASS: hdr_done_pulse fired");

      // T2: dst_mac alignment check — core diagnostic
      case (dbg_dst_mac)
        48'h000A3501FEC0:
          $display("T2 PASS: dst_mac correctly aligned = %012h", dbg_dst_mac);
        48'hD5000A3501FE: begin
          $error("T2 FAIL: SFD leaked into dst_mac (+1 byte shift), got %012h", dbg_dst_mac);
          fails++;
        end
        48'h0A3501FEC0E0: begin
          $error("T2 FAIL: first dst_mac byte lost (-1 byte shift), got %012h", dbg_dst_mac);
          fails++;
        end
        default: begin
          $error("T2 FAIL: dst_mac unexpected = %012h (expected 000A3501FEC0)", dbg_dst_mac);
          fails++;
        end
      endcase

      // T3: hdr_accept fired
      if (!hdr_accept_seen) begin
        $error("T3 FAIL: hdr_accept_pulse never fired, dbg_dst_mac=%012h", dbg_dst_mac);
        fails++;
      end else
        $display("T3 PASS: hdr_accept_pulse fired (LOCAL_MAC match)");

      // T3b: hdr_drop silent
      if (hdr_drop_seen) begin
        $error("T3b FAIL: hdr_drop_pulse unexpectedly fired");
        fails++;
      end else
        $display("T3b PASS: hdr_drop_pulse silent");
    end

    clk_clk(12);

    // ── Frame 2: non-matching dst_mac — should be dropped ─────────────
    begin
      logic [7:0] frame[18];
      frame[0]  = 8'h00; frame[1]  = 8'h11; frame[2]  = 8'h22; frame[3]  = 8'h33;
      frame[4]  = 8'h44; frame[5]  = 8'h55;  // dst_mac = 00:11:22:33:44:55
      frame[6]  = 8'hE0; frame[7]  = 8'h4F; frame[8]  = 8'h43; frame[9]  = 8'h5B;
      frame[10] = 8'h59; frame[11] = 8'h3C;
      frame[12] = 8'h08; frame[13] = 8'h00;
      frame[14] = 8'h45; frame[15] = 8'h00; frame[16] = 8'hA1; frame[17] = 8'hA2;

      run_frame(frame, 18);

      // T4: hdr_done fired
      if (!hdr_done_seen) begin
        $error("T4 FAIL: hdr_done_pulse never fired");
        fails++;
      end else
        $display("T4 PASS: hdr_done_pulse fired for non-matching frame");

      // T4b: drop fired, accept silent
      if (hdr_drop_seen && !hdr_accept_seen)
        $display("T4b PASS: non-matching MAC correctly dropped");
      else begin
        $error("T4b FAIL: accept=%0b drop=%0b (expected accept=0 drop=1)",
               hdr_accept_seen, hdr_drop_seen);
        fails++;
      end
    end

    clk_clk(5);

    if (fails == 0)
      $display("ALL PASS (6 checks)");
    else
      $display("FAIL: %0d check(s) failed", fails);

    $finish;
  end

endmodule

`endif // TB_GMII_RX_ETH_ALIGN_SV
