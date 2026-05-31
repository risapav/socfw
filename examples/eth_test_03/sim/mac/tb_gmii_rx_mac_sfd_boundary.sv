`timescale 1ns/1ps
/**
 * @file tb_gmii_rx_mac_sfd_boundary.sv
 * @brief Unit test: gmii_rx_mac SFD boundary using exact HW tcpdump frame.
 * @details Drives the exact Ethernet header captured from real HW to diagnose
 *   byte-shift bugs at the SFD/data boundary:
 *
 *   PASS (correct):   first 6 bytes = 00:0A:35:01:FE:C0
 *   SFD leak (+1):    first 6 bytes = D5:00:0A:35:01:FE
 *   First byte lost:  first 6 bytes = 0A:35:01:FE:C0:E0
 *
 * Tests:
 *   T1: captured byte count == 18 (frame_len exact, no extra or missing bytes)
 *   T2: dst_mac[47:0] alignment -- explicit 3-way case diagnosis
 *   T3: tlast fires on the last byte
 */

`ifndef TB_GMII_RX_MAC_SFD_BOUNDARY_SV
`define TB_GMII_RX_MAC_SFD_BOUNDARY_SV

`default_nettype none

module tb_gmii_rx_mac_sfd_boundary;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #4 clk = ~clk;

  logic [7:0] gmii_rxd   = 8'h00;
  logic       gmii_rx_dv = 1'b0;
  logic       gmii_rx_er = 1'b0;
  logic [7:0] m_axis_tdata;
  logic       m_axis_tvalid;
  logic       m_axis_tready = 1'b1;
  logic       m_axis_tlast;
  logic       m_axis_tuser;
  logic       frame_done;

  gmii_rx_mac #(.EXPECT_PREAMBLE(1'b1)) dut (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .gmii_rxd_i   (gmii_rxd),
    .gmii_rx_dv_i (gmii_rx_dv),
    .gmii_rx_er_i (gmii_rx_er),
    .m_axis_tdata (m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast (m_axis_tlast),
    .m_axis_tuser (m_axis_tuser),
    .frame_done_o (frame_done)
  );

  // Pre-NBA capture: sample combinatorial AXI-S outputs before DUT's NBA updates.
  logic [7:0] tdata_cap;
  logic       tvalid_cap, tlast_cap;
  always @(posedge clk) begin
    tdata_cap  = m_axis_tdata;
    tvalid_cap = m_axis_tvalid;
    tlast_cap  = m_axis_tlast;
  end

  int fails = 0;

  task automatic clk_clk(int n = 1);
    repeat (n) @(posedge clk); #1;
  endtask

  task automatic drive_and_capture(
    input  logic [7:0] data[],
    input  int         data_len,
    output logic [7:0] cap[$],
    output logic       tlast_seen
  );
    cap        = {};
    tlast_seen = 1'b0;

    // 7-byte preamble
    for (int i = 0; i < 7; i++) begin
      @(negedge clk); gmii_rxd = 8'h55; gmii_rx_dv = 1'b1;
      @(posedge clk); #1;
      if (tvalid_cap && m_axis_tready) begin
        cap.push_back(tdata_cap);
        if (tlast_cap) tlast_seen = 1'b1;
      end
    end

    // SFD byte -- consumed by RX_SFD state, must NOT appear in output
    @(negedge clk); gmii_rxd = 8'hD5; gmii_rx_dv = 1'b1;
    @(posedge clk); #1;
    if (m_axis_tvalid && m_axis_tready) begin
      cap.push_back(m_axis_tdata);
      if (m_axis_tlast) tlast_seen = 1'b1;
    end

    // Payload bytes
    for (int i = 0; i < data_len; i++) begin
      @(negedge clk); gmii_rxd = data[i]; gmii_rx_dv = 1'b1;
      @(posedge clk); #1;
      if (tvalid_cap && m_axis_tready) begin
        cap.push_back(tdata_cap);
        if (tlast_cap) tlast_seen = 1'b1;
      end
    end

    // Drop DV; flush pipeline to capture last byte with tlast
    @(negedge clk); gmii_rxd = 8'h00; gmii_rx_dv = 1'b0;
    repeat (4) begin
      @(posedge clk); #1;
      if (tvalid_cap && m_axis_tready) begin
        cap.push_back(tdata_cap);
        if (tlast_cap) tlast_seen = 1'b1;
      end
    end
    @(negedge clk);
    clk_clk(2);
  endtask

  initial begin
    @(negedge clk); rst_n = 1'b0;
    clk_clk(3);
    @(negedge clk); rst_n = 1'b1;
    clk_clk(4);

    // Exact tcpdump frame: dst=00:0A:35:01:FE:C0, src=E0:4F:43:5B:59:3C, ethertype=0x0800
    begin
      logic [7:0] frame[18];
      logic [7:0] cap[$];
      logic       tlast_seen;
      logic [47:0] got_dst_mac;

      frame[0]  = 8'h00; frame[1]  = 8'h0A; frame[2]  = 8'h35; frame[3]  = 8'h01;
      frame[4]  = 8'hFE; frame[5]  = 8'hC0;
      frame[6]  = 8'hE0; frame[7]  = 8'h4F; frame[8]  = 8'h43; frame[9]  = 8'h5B;
      frame[10] = 8'h59; frame[11] = 8'h3C;
      frame[12] = 8'h08; frame[13] = 8'h00;
      frame[14] = 8'h45; frame[15] = 8'h00; frame[16] = 8'hA1; frame[17] = 8'hA2;

      drive_and_capture(frame, 18, cap, tlast_seen);

      // T1: exact byte count
      if (cap.size() !== 18) begin
        $error("T1 FAIL: captured %0d bytes, expected 18", cap.size());
        fails++;
      end else
        $display("T1 PASS: captured 18 bytes");

      // T2: dst_mac alignment -- 3-way diagnosis
      if (cap.size() >= 6) begin
        got_dst_mac = {cap[0], cap[1], cap[2], cap[3], cap[4], cap[5]};
        case (got_dst_mac)
          48'h000A3501FEC0:
            $display("T2 PASS: dst_mac correctly aligned = %012h", got_dst_mac);
          48'hD5000A3501FE: begin
            $error("T2 FAIL: SFD (0xD5) leaked into output (+1 byte shift), got %012h", got_dst_mac);
            fails++;
          end
          48'h0A3501FEC0E0: begin
            $error("T2 FAIL: first dst_mac byte lost (-1 byte shift), got %012h", got_dst_mac);
            fails++;
          end
          default: begin
            $error("T2 FAIL: unexpected dst_mac = %012h (expected 000A3501FEC0)", got_dst_mac);
            fails++;
          end
        endcase
      end

      // T3: tlast on last byte
      if (!tlast_seen) begin
        $error("T3 FAIL: tlast never asserted");
        fails++;
      end else
        $display("T3 PASS: tlast asserted on last byte");
    end

    if (fails == 0)
      $display("ALL PASS (3 checks)");
    else
      $display("FAIL: %0d check(s) failed", fails);

    $finish;
  end

endmodule

`endif // TB_GMII_RX_MAC_SFD_BOUNDARY_SV
