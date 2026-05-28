`timescale 1ns/1ps

// Integration test: echo cesta s GMII RX bez preambuly (EXPECT_PREAMBLE=0)
//
// Overuje spravanie pri EXPECT_PREAMBLE=0: ipsend stale musi vyslat
// korektny 72-bajtovy ramec aj ked vstupny RX stream nezacina preambulou.
// Prvy bajt rx_dv_i je priamo destination MAC[0].
//
// Rovnake ocakavane vystupy ako tb_ethernet_test_echo_gmii_packet:
// T5: TX aktivita (72 B ramec)
// T6: dst IP = src IP z RX (echo)
// T7: tx_data_length=13, tx_total_length=33
// T8: CRC reziduum 0xDEBB20E3
// T9: 13 bajtov paddingu = 0x00
// T10: eth_tx_er_o nikdy

module tb_ethernet_test_echo_gmii_no_preamble;

  int fail_count = 0;

  logic rx_clk  = 0;
  logic tx_clk  = 0;
  logic sys_clk = 0;
  logic rst_ni;

  always #4    rx_clk  = ~rx_clk;
  always #4.05 tx_clk  = ~tx_clk;
  always #10   sys_clk = ~sys_clk;

  // ---------------------------------------------------------------------------
  // DUT — EXPECT_PREAMBLE=0: parser ocakava MAC priamo bez preambuly/SFD
  // ---------------------------------------------------------------------------
  logic       eth_rx_dv   = 0;
  logic [7:0] eth_rx_data = 0;
  logic       eth_rx_er   = 0;
  logic       eth_gtx_clk;
  logic       eth_tx_en;
  logic       eth_tx_er;
  logic [7:0] eth_tx_data;
  logic       eth_mdc;
  wire        eth_mdio;
  logic       eth_rst_no;
  logic [5:0] status_led;

  ethernet_test_echo #(
    .BOARD_IP        (32'hC0A81432),
    .ECHO_PORT       (16'd8080),
    .EXPECT_PREAMBLE (1'b0)
  ) dut (
    .rst_ni         (rst_ni),
    .sys_clk_i      (sys_clk),
    .eth_rx_clk_i   (rx_clk),
    .eth_tx_clk_i   (tx_clk),
    .eth_rx_dv_i    (eth_rx_dv),
    .eth_rx_data_i  (eth_rx_data),
    .eth_rx_er_i    (eth_rx_er),
    .eth_gtx_clk_o  (eth_gtx_clk),
    .eth_tx_en_o    (eth_tx_en),
    .eth_tx_er_o    (eth_tx_er),
    .eth_tx_data_o  (eth_tx_data),
    .eth_mdc_o      (eth_mdc),
    .eth_mdio_io    (eth_mdio),
    .eth_rst_no     (eth_rst_no),
    .status_led_o   (status_led)
  );

  // ---------------------------------------------------------------------------
  // Zachytenie TX bajtov
  // ---------------------------------------------------------------------------
  byte unsigned tx_bytes[$];
  int           tx_err_seen = 0;

  always @(negedge tx_clk) begin
    if (eth_tx_en)  tx_bytes.push_back(eth_tx_data);
    if (eth_tx_er)  tx_err_seen = 1;
  end

  // ---------------------------------------------------------------------------
  // CRC-32/ISO-HDLC helper
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] crc32_update(
    input logic [31:0] crc,
    input logic [7:0]  data
  );
    logic [31:0] c;
    logic fb;
    c = crc;
    for (int i = 0; i < 8; i++) begin
      fb = c[0] ^ data[i];
      c = c >> 1;
      if (fb) c ^= 32'hEDB88320;
    end
    return c;
  endfunction

  task automatic chkb(input string tag, input byte unsigned got, input byte unsigned exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%02x exp=0x%02x", tag, got, exp);
      fail_count++;
    end else
      $display("PASS %s: 0x%02x", tag, got);
  endtask

  task automatic chk32(input string tag, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08x exp=0x%08x", tag, got, exp);
      fail_count++;
    end else
      $display("PASS %s: 0x%08x", tag, got);
  endtask

  task automatic chk16(input string tag, input logic [15:0] got, input logic [15:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%04x exp=0x%04x", tag, got, exp);
      fail_count++;
    end else
      $display("PASS %s: 0x%04x", tag, got);
  endtask

  // RX frame BEZ preambuly/SFD — prvy bajt je destination MAC[0]
  task automatic send_gmii_frame_no_preamble();
    automatic byte f [] = '{
      // bez 55 55 55 55 55 55 55 D5
      8'h00, 8'h0A, 8'h35, 8'h01, 8'hFE, 8'hC0,                  // DST MAC (FPGA)
      8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h12, 8'h34,                  // SRC MAC
      8'h08, 8'h00,                                                 // EtherType IPv4
      8'h45, 8'h00, 8'h00, 8'h21,                                  // IP: v4/IHL/DSCP/len=33
      8'h00, 8'h01, 8'h00, 8'h00,                                  // ID/flags/frag
      8'h40, 8'h11, 8'h00, 8'h00,                                  // TTL=64/UDP/cksum=0
      8'hC0, 8'hA8, 8'h14, 8'h64,                                  // src IP 192.168.20.100
      8'hC0, 8'hA8, 8'h14, 8'h32,                                  // dst IP 192.168.20.50
      8'h11, 8'hD7, 8'h1F, 8'h90,                                  // UDP src=4567 dst=8080
      8'h00, 8'h0D, 8'h00, 8'h00,                                  // UDP len=13 cksum=0
      8'h48, 8'h45, 8'h4C, 8'h4C, 8'h4F                           // payload HELLO
    };
    foreach (f[i]) begin
      @(posedge rx_clk); #1;
      eth_rx_dv   = 1'b1;
      eth_rx_data = f[i];
    end
    @(posedge rx_clk); #1;
    eth_rx_dv   = 1'b0;
    eth_rx_data = 8'h00;
  endtask

  // ---------------------------------------------------------------------------
  // Test
  // ---------------------------------------------------------------------------
  localparam logic [31:0] SRC_IP = 32'hC0A81464; // 192.168.20.100

  initial begin
    rst_ni = 0;
    repeat (8) @(posedge tx_clk); #1;
    rst_ni = 1;

    force dut.phy_rst_done_q = 1'b1;
    @(posedge tx_clk); #1;

    send_gmii_frame_no_preamble();

    fork
      begin
        @(posedge eth_tx_en);
        @(negedge eth_tx_en);
        repeat (4) @(negedge tx_clk);
      end
      begin
        repeat (5000) @(posedge tx_clk);
        $display("FAIL: TIMEOUT - eth_tx_en nikdy neassertovany");
        fail_count++;
      end
    join_any
    disable fork;

    $display("-- T5: TX aktivita --");
    if (tx_bytes.size() == 0) begin
      $display("FAIL T5: ziadne TX bajty");
      fail_count++;
      $display("\n       FAILED (%0d failures)", fail_count);
      $finish;
    end else
      $display("PASS T5: TX prebehlo (%0d bajtov)", tx_bytes.size());

    $display("-- T7: tx_data/total length --");
    chk16("T7 tx_data_length",  dut.tx_data_length_w,  16'd13);
    chk16("T7 tx_total_length", dut.tx_total_length_w, 16'd33);

    $display("-- Frame length (expected 72) --");
    if (tx_bytes.size() !== 72) begin
      $display("FAIL frame length: got=%0d exp=72", tx_bytes.size());
      fail_count++;
    end else
      $display("PASS frame length: 72");

    $display("-- T6: dst IP = echo ciel --");
    begin
      logic [31:0] pkt_dst_ip;
      pkt_dst_ip = {tx_bytes[38], tx_bytes[39], tx_bytes[40], tx_bytes[41]};
      chk32("T6 dst_ip", pkt_dst_ip, SRC_IP);
    end

    $display("-- payload HELLO --");
    chkb("payload[0]", tx_bytes[50], 8'h48);
    chkb("payload[1]", tx_bytes[51], 8'h45);
    chkb("payload[2]", tx_bytes[52], 8'h4C);
    chkb("payload[3]", tx_bytes[53], 8'h4C);
    chkb("payload[4]", tx_bytes[54], 8'h4F);

    $display("-- T9: Ethernet padding --");
    begin
      automatic int pad_fail = 0;
      for (int i = 55; i < 68; i++) begin
        if (tx_bytes[i] !== 8'h00) begin
          $display("FAIL T9 pad[%0d]: got=0x%02x exp=0x00", i-55, tx_bytes[i]);
          pad_fail++;
          fail_count++;
        end
      end
      if (pad_fail == 0)
        $display("PASS T9: 13 padding bytes = 0x00");
    end

    $display("-- T8: CRC residue --");
    begin
      automatic logic [31:0] residue;
      residue = 32'hFFFF_FFFF;
      for (int i = 8; i < 72; i++)
        residue = crc32_update(residue, tx_bytes[i]);
      chk32("T8 CRC residue", residue, 32'hDEBB_20E3);
    end

    $display("-- T10: tx_er_o --");
    if (tx_err_seen) begin
      $display("FAIL T10: eth_tx_er_o bol asserted");
      fail_count++;
    end else
      $display("PASS T10: eth_tx_er_o nikdy");

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

  initial begin
    #500000;
    $display("FAIL: TIMEOUT");
    $finish;
  end

endmodule
