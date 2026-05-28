`timescale 1ns/1ps

// Integration test: kompletna UDP echo cesta (bez GMII PHY)
//
// Test injectuje ipreceive "done" signal a metadata priamo do
// udp_rx_ram_to_stream -> eth_udp_echo_test -> udp_tx_stream_to_ram -> ipsend.
//
// RX RAM je inicializovany s testovacim payloadom "HELLO" (5 bajtov).
//
// T1: echo modul dostane metadata (src_ip, dst_ip, porty)
// T2: echo modul zachyti 5 bajtov payloadu
// T3: TX RAM je naplneny spravnym payload od adresy 1 (MSB-first)
// T4: ipsend dostane tx_start_o pulz
// T5: ipsend vysiela (tx_en_o sa asserted)
// T6: dst_ip v TX pakete = src_ip z RX paketu (echo)
// T7: tx_data_length = 5+8 = 13; tx_total_length = 5+28 = 33
// T8: FCS platne (CRC reziduum 0xDEBB20E3)

module tb_udp_echo_path;

  int fail_count = 0;

  // Hodiny — obe 125 MHz, mierne faza posunute aby testovaci async CDC
  logic rx_clk = 0;
  logic tx_clk = 0;
  logic sys_clk = 0;
  logic rst_ni;

  always #4    rx_clk  = ~rx_clk;
  always #4.05 tx_clk  = ~tx_clk;
  always #10   sys_clk = ~sys_clk;  // 50 MHz

  // ---------------------------------------------------------------------------
  // DUT
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
    .BOARD_IP  (32'hC0A81432),  // 192.168.20.50
    .ECHO_PORT (16'd8080)
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
  // Predzenie testovania: inject priamo do ipreceive mockovych vystupov
  // ---------------------------------------------------------------------------

  // Naplnenie RX RAM testovacim payloadom "HELLO" (5 bajtov = 0x48454C4C4F)
  // Slovo 0: 0x48454C4C (H E L L)
  // Slovo 1: 0x4F000000 (O + 3x padding)
  initial begin
    // Force RX RAM obsah — ipreceive zapisuje od adresy 1 (addr 0 sa preskakuje)
    force dut.u_rx_ram.mem[1] = 32'h48454C4C;
    force dut.u_rx_ram.mem[2] = 32'h4F000000;
  end

  // Mock ipreceive metadata (normalne ich vytvori ipreceive HW)
  // Simulujeme prichod UDP paketu od 192.168.20.100:4567 na port 8080
  // s 5-bajtovym payloadom (UDP dlzka = 5 + 8 = 13)
  localparam logic [31:0] SRC_IP  = 32'hC0A81464; // 192.168.20.100
  localparam logic [31:0] DST_IP  = 32'hC0A81432; // 192.168.20.50 (nas board)
  localparam logic [15:0] SRC_PORT = 16'd4567;
  localparam logic [15:0] DST_PORT = 16'd8080;
  localparam logic [15:0] UDP_LEN  = 16'd13;       // 5 payload + 8 UDP header

  // ---------------------------------------------------------------------------
  // Zachytenie TX bajtov
  // ---------------------------------------------------------------------------
  byte unsigned tx_bytes[$];
  int           tx_err_seen = 0;

  always @(negedge tx_clk) begin
    if (eth_tx_en)  tx_bytes.push_back(eth_tx_data);
    if (eth_tx_er)  tx_err_seen = 1;
  end

  // Reflected CRC-32/ISO-HDLC residue check
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

  // ---------------------------------------------------------------------------
  // Hlavny test
  // ---------------------------------------------------------------------------
  initial begin
    rst_ni = 0;
    repeat (8) @(posedge tx_clk); #1;
    rst_ni = 1;

    // Obchod PHY reset countera (sys_clk)
    force dut.phy_rst_done_q = 1'b1;
    @(posedge tx_clk); #1;

    // Nastavime metadata mock pre ipreceive (force signaly v DUT)
    force dut.ipr_pc_ip_w      = SRC_IP;
    force dut.ipr_board_ip_w   = DST_IP;
    force dut.ipr_udp_layer_w  = {SRC_PORT, DST_PORT, UDP_LEN, 16'd0};
    force dut.ipr_rx_data_len_w = UDP_LEN;

    // Vydaj 1-cyklovy data_receive pulz (v rx_clk domene)
    @(posedge rx_clk); #1;
    force dut.ipr_data_receive_w = 1'b1;
    @(posedge rx_clk); #1;
    force dut.ipr_data_receive_w = 1'b0;
    release dut.ipr_data_receive_w;

    // Cakaj na dokoncenie TX paketu (max 1000 tx cyklov)
    @(posedge eth_tx_en);
    @(negedge eth_tx_en);
    repeat (4) @(negedge tx_clk);

    // -- T5: ipsend vysilal (tx_en bol asserted) --
    $display("-- T5: TX aktivity --");
    if (tx_bytes.size() == 0) begin
      $display("FAIL T5: ziadne TX bajty");
      fail_count++;
      $display("\n       FAILED (%0d failures)", fail_count);
      $finish;
    end else
      $display("PASS T5: TX prebehlo (%0d bajtov)", tx_bytes.size());

    // -- T7: dlzky --
    $display("-- T7: tx_data/total length --");
    chk16("T7 tx_data_length",  dut.tx_data_length_w,  16'd13);
    chk16("T7 tx_total_length", dut.tx_total_length_w, 16'd33);

    // Ramec: 8 preamble + 14 MAC/ethtype + 20 IP + 8 UDP + 5 payload + 13 pad + 4 FCS
    // = 8 + 14 + 20 + 8 + 5 + 13 + 4 = 72 bajtov
    $display("-- Frame length (expected 72) --");
    if (tx_bytes.size() !== 72) begin
      $display("FAIL frame length: got=%0d exp=72", tx_bytes.size());
      fail_count++;
    end else
      $display("PASS frame length: 72");

    // -- T6: dst IP v pakete = SRC_IP (echo na odosielatela) --
    // IP dst je na bajtoch 38-41 (8 preamble + 14 MAC/ethtype + 16 IP offset pre dst)
    $display("-- T6: dst IP = echo ciel --");
    begin
      logic [31:0] pkt_dst_ip;
      pkt_dst_ip = {tx_bytes[38], tx_bytes[39], tx_bytes[40], tx_bytes[41]};
      chk32("T6 dst_ip", pkt_dst_ip, SRC_IP);
    end

    // -- T1/T2/T3: payload v TX = "HELLO" --
    // payload zacina na bajte 50 (8 pream + 14 MAC + 20 IP + 8 UDP)
    $display("-- T1-T3: payload --");
    chkb("T3 payload[0]", tx_bytes[50], 8'h48); // H
    chkb("T3 payload[1]", tx_bytes[51], 8'h45); // E
    chkb("T3 payload[2]", tx_bytes[52], 8'h4C); // L
    chkb("T3 payload[3]", tx_bytes[53], 8'h4C); // L
    chkb("T3 payload[4]", tx_bytes[54], 8'h4F); // O

    // -- T9: padding 13x 0x00 (bytes 55-67) --
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

    // -- T8: CRC reziduum (pokryva bajty 8..68, FCS na 68..72) --
    $display("-- T8: CRC residue --");
    begin
      automatic logic [31:0] residue;
      residue = 32'hFFFF_FFFF;
      for (int i = 8; i < 72; i++)
        residue = crc32_update(residue, tx_bytes[i]);
      chk32("T8 CRC residue", residue, 32'hDEBB_20E3);
    end

    // -- T10: tx_er nikdy nebol asserted --
    $display("-- T10: tx_er_o --");
    if (tx_err_seen) begin
      $display("FAIL T10: tx_er_o bol asserted");
      fail_count++;
    end else
      $display("PASS T10: tx_er_o nikdy");

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

  // Timeout
  initial begin
    #200000;
    $display("FAIL: TIMEOUT");
    $finish;
  end

endmodule
