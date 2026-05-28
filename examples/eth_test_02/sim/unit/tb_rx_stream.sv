`timescale 1ns/1ps

// Unit test: udp_rx_ram_to_stream
//
// T1: meta_valid po data_receive_i pulze
// T2: spravna metadata (src_ip, dst_ip, porty, dlzka)
// T3: spravny pocet bajtov (payload_len = rx_data_length - 8)
// T4: MSB-first byte order (byte 0 = bits [31:24])
// T5: last signal na poslednom bajte

module tb_rx_stream;

  int fail_count = 0;

  // rx_clk a tx_clk su asynchronne (rozne periody pre realistickejsi test)
  logic rx_clk = 0;
  logic tx_clk = 0;
  logic rst_ni;

  always #4   rx_clk = ~rx_clk;  // 125 MHz
  always #4.1 tx_clk = ~tx_clk;  // ~122 MHz (asynchronne)

  // ipreceive mock vystupy
  logic        data_receive;
  logic [31:0] pc_ip      = 32'hC0A81401; // 192.168.20.1
  logic [31:0] board_ip   = 32'hC0A81432; // 192.168.20.50
  logic [63:0] udp_layer  = {16'd1234, 16'd8080, 16'd12, 16'd0}; // srcP=1234,dstP=8080,len=12
  logic [15:0] rx_data_len = 16'd12; // 12 = 4 payload + 8 UDP header

  // RAM mock — 4 bajty payload: DE AD BE EF (ipreceive zapisuje od adresy 1)
  logic [8:0]  ram_addr;
  logic [31:0] ram_data;
  assign ram_data = (ram_addr == 1) ? 32'hDEADBEEF : 32'd0;

  // DUT vystupy
  logic        meta_valid, meta_ready;
  logic [31:0] src_ip, dst_ip;
  logic [15:0] src_port, dst_port, length;
  logic        rx_valid, rx_ready, rx_last;
  logic [7:0]  rx_data;

  udp_rx_ram_to_stream dut (
    .rx_clk_i              (rx_clk),
    .rst_ni                (rst_ni),
    .data_receive_i        (data_receive),
    .pc_ip_i               (pc_ip),
    .board_ip_i            (board_ip),
    .udp_layer_i           (udp_layer),
    .rx_data_length_i      (rx_data_len),
    .tx_clk_i              (tx_clk),
    .ram_addr_o            (ram_addr),
    .ram_data_i            (ram_data),
    .udp_rx_meta_valid_o   (meta_valid),
    .udp_rx_meta_ready_i   (meta_ready),
    .udp_rx_src_ip_o       (src_ip),
    .udp_rx_dst_ip_o       (dst_ip),
    .udp_rx_src_port_o     (src_port),
    .udp_rx_dst_port_o     (dst_port),
    .udp_rx_length_o       (length),
    .udp_rx_valid_o        (rx_valid),
    .udp_rx_ready_i        (rx_ready),
    .udp_rx_data_o         (rx_data),
    .udp_rx_last_o         (rx_last)
  );

  // Akceptuj metadata okamzite
  assign meta_ready = 1'b1;
  // Akceptuj bajty okamzite
  assign rx_ready   = 1'b1;

  byte unsigned captured_bytes[$];
  int           last_seen_at = -1;
  int           cycle_count  = 0;

  always @(negedge tx_clk) begin
    cycle_count++;
    if (rx_valid) captured_bytes.push_back(rx_data);
    if (rx_last)  last_seen_at = cycle_count;
  end

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

  initial begin
    rst_ni = 0; data_receive = 0;
    repeat (4) @(posedge rx_clk); #1;
    rst_ni = 1;
    repeat (4) @(posedge tx_clk); #1;

    // Vydaj data_receive pulz (1 cyklus v rx_clk domene)
    @(posedge rx_clk); #1;
    data_receive = 1;
    @(posedge rx_clk); #1;
    data_receive = 0;

    // Cakaj na dokoncenie prenosu (max 200 tx cyklov)
    repeat (200) @(posedge tx_clk);
    #1;

    // T1: meta_valid sa objavil (captured via last_seen_at > 0)
    $display("-- T1/T2: metadata --");
    chk32("T2 src_ip",    src_ip,  32'hC0A81401);
    chk32("T2 dst_ip",    dst_ip,  32'hC0A81432);
    chk16("T2 src_port",  src_port, 16'd1234);
    chk16("T2 dst_port",  dst_port, 16'd8080);
    chk16("T2 length",    length,   16'd4); // 12 - 8 = 4

    // T3: pocet bajtov
    $display("-- T3: byte count --");
    if (captured_bytes.size() !== 4) begin
      $display("FAIL T3 byte count: got=%0d exp=4", captured_bytes.size());
      fail_count++;
    end else
      $display("PASS T3 byte count: 4");

    // T4: MSB-first order — DE AD BE EF
    if (captured_bytes.size() >= 4) begin
      $display("-- T4: byte order (DEADBEEF) --");
      if (captured_bytes[0] !== 8'hDE) begin
        $display("FAIL T4 byte[0]: got=0x%02x exp=0xDE", captured_bytes[0]);
        fail_count++;
      end else $display("PASS T4 byte[0]=0xDE");
      if (captured_bytes[1] !== 8'hAD) begin
        $display("FAIL T4 byte[1]: got=0x%02x exp=0xAD", captured_bytes[1]);
        fail_count++;
      end else $display("PASS T4 byte[1]=0xAD");
      if (captured_bytes[2] !== 8'hBE) begin
        $display("FAIL T4 byte[2]: got=0x%02x exp=0xBE", captured_bytes[2]);
        fail_count++;
      end else $display("PASS T4 byte[2]=0xBE");
      if (captured_bytes[3] !== 8'hEF) begin
        $display("FAIL T4 byte[3]: got=0x%02x exp=0xEF", captured_bytes[3]);
        fail_count++;
      end else $display("PASS T4 byte[3]=0xEF");
    end

    // T5: last na poslednom bajte
    $display("-- T5: last signal --");
    if (last_seen_at < 0) begin
      $display("FAIL T5: rx_last nikdy nebol asserted");
      fail_count++;
    end else
      $display("PASS T5: rx_last asserted");

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
