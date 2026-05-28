`timescale 1ns/1ps

// Integration test: ipsend.sv + crc.sv -- complete Ethernet TX frame
//
// Sends static "HELLO QM TECH BOARD\n\r" payload with broadcast dst MAC.
// Timer is forced to skip the 0.5 s idle delay.
//
// T1:  Preamble 7x 0x55 + SFD 0xD5
// T2:  Destination MAC = FF:FF:FF:FF:FF:FF (broadcast)
// T3:  Source MAC = 00:0A:35:01:FE:C0
// T4:  EtherType = 0x0800 (IPv4)
// T5:  IP version/IHL = 0x45, protocol = 0x11 (UDP)
// T6:  IP header checksum valid (sum of all 10 words = 0xFFFF)
// T7:  UDP payload = "HELLO QM TECH BOARD\n\r" (20 bytes)
// T8:  Frame length = 74 bytes (8 preamble + 66 Ethernet frame)
// T9:  Ethernet CRC residue = 0xC704_DD7B (FCS correct)
// T10: tx_er_o never asserted
//
// Run (from sim/):
//   vlog -sv -suppress 2892 \
//        ../rtl/eth/crc.sv ../rtl/eth/ipsend.sv \
//        integration/tb_ipsend_full_frame.sv
//   vsim -c -do "run -all; quit" tb_ipsend_full_frame

module tb_ipsend_full_frame;

  int fail_count = 0;

  logic        clk = 1'b0;
  logic        rst_ni;
  logic        tx_en_o;
  logic        tx_er_o;
  logic [7:0]  tx_data_o;
  logic [31:0] crc_next_w;
  logic [31:0] crc_w;
  logic        crc_en_w;
  logic        crc_rst_nw;
  logic [31:0] ram_rd_data_i;
  logic [3:0]  tx_state_o;
  logic [8:0]  ram_rd_addr_o;

  always #4 clk = ~clk;  // 125 MHz

  // Combinational RAM model with static payload
  logic [31:0] ram_mem [0:511];
  initial begin
    for (int i = 0; i < 512; i++) ram_mem[i] = 32'd0;
    ram_mem[1] = 32'h48454C4C; // H E L L
    ram_mem[2] = 32'h4F20514D; // O   Q M
    ram_mem[3] = 32'h54454348; // T E C H
    ram_mem[4] = 32'h20424F41; //   B O A
    ram_mem[5] = 32'h52440A0D; // R D \n \r
  end
  assign ram_rd_data_i = ram_mem[ram_rd_addr_o];

  ipsend u_ipsend (
    .clk_i             (clk),
    .rst_ni            (rst_ni),
    .tx_en_o           (tx_en_o),
    .tx_er_o           (tx_er_o),
    .tx_data_o         (tx_data_o),
    .crc_i             (crc_next_w),
    .ram_rd_data_i     (ram_rd_data_i),
    .crc_en_o          (crc_en_w),
    .crc_rst_no        (crc_rst_nw),
    .tx_state_o        (tx_state_o),
    .tx_data_length_i  (16'd28),
    .tx_total_length_i (16'd48),
    .ram_rd_addr_o     (ram_rd_addr_o)
  );

  crc u_crc (
    .clk_i      (clk),
    .rst_ni     (crc_rst_nw),
    .data_i     (tx_data_o),
    .en_i       (crc_en_w),
    .crc_o      (crc_w),
    .crc_next_o (crc_next_w)
  );

  // TX byte capture at negedge (stable after posedge NBA update)
  byte unsigned tx_bytes[$];
  int           tx_err_seen;
  initial       tx_err_seen = 0;

  always @(negedge clk) begin
    if (tx_en_o)   tx_bytes.push_back(tx_data_o);
    if (tx_er_o)   tx_err_seen = 1;
  end

  // Reflected CRC32 model (polynomial 0xEDB88320) for residue check
  function automatic logic [31:0] crc32_update(
    input logic [31:0] crc,
    input logic [7:0]  data
  );
    logic [31:0] c;
    logic        fb;
    c = crc;
    for (int i = 0; i < 8; i++) begin
      fb = c[0] ^ data[i];
      c  = c >> 1;
      if (fb) c ^= 32'hEDB8_8320;
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

  initial begin
    rst_ni = 1'b0;
    repeat (4) @(posedge clk); #1;
    rst_ni = 1'b1;
    repeat (2) @(posedge clk); #1;

    // Skip 0.5 s idle timer: force match value, let FSM fire at next posedge
    force u_ipsend.time_counter_q = 32'h04000000;
    @(posedge clk); #1;
    release u_ipsend.time_counter_q;

    // Wait for TX packet to start and finish
    @(posedge tx_en_o);
    @(negedge tx_en_o);
    repeat (4) @(negedge clk);

    // -- T8: Frame length --
    $display("-- T8: Frame length (expected 74) --");
    if (tx_bytes.size() !== 74) begin
      $display("FAIL T8 frame length: got=%0d exp=74", tx_bytes.size());
      fail_count++;
      $display("\n       FAILED (%0d failures)", fail_count);
      $finish;
    end else
      $display("PASS T8 frame length: 74");

    // -- T1: Preamble --
    $display("-- T1: Preamble --");
    for (int i = 0; i < 7; i++)
      chkb($sformatf("T1 preamble[%0d]", i), tx_bytes[i], 8'h55);
    chkb("T1 SFD", tx_bytes[7], 8'hD5);

    // -- T2: Destination MAC (broadcast FF:FF:FF:FF:FF:FF) --
    $display("-- T2: Destination MAC --");
    for (int i = 0; i < 6; i++)
      chkb($sformatf("T2 dst_mac[%0d]", i), tx_bytes[8+i], 8'hFF);

    // -- T3: Source MAC (00:0A:35:01:FE:C0) --
    $display("-- T3: Source MAC --");
    begin
      byte unsigned exp_src[6] = '{8'h00, 8'h0A, 8'h35, 8'h01, 8'hFE, 8'hC0};
      for (int i = 0; i < 6; i++)
        chkb($sformatf("T3 src_mac[%0d]", i), tx_bytes[14+i], exp_src[i]);
    end

    // -- T4: EtherType = 0x0800 (IPv4) --
    $display("-- T4: EtherType --");
    chkb("T4 ethertype[0]", tx_bytes[20], 8'h08);
    chkb("T4 ethertype[1]", tx_bytes[21], 8'h00);

    // -- T5: IP version/IHL, protocol --
    $display("-- T5: IP version/protocol --");
    chkb("T5 ip_ver_ihl", tx_bytes[22], 8'h45); // IPv4, IHL=5
    chkb("T5 ip_proto",   tx_bytes[31], 8'h11); // UDP

    // -- T6: IP header checksum (sum of all 10 words = 0xFFFF) --
    $display("-- T6: IP header checksum --");
    begin
      logic [31:0] ip_sum;
      logic [15:0] ip_fold;
      ip_sum = 32'd0;
      for (int i = 0; i < 20; i += 2)
        ip_sum += {tx_bytes[22+i], tx_bytes[22+i+1]};
      ip_fold = ip_sum[15:0] + ip_sum[31:16];
      if (ip_fold !== 16'hFFFF) begin
        $display("FAIL T6 IP checksum: folded_sum=0x%04x exp=0xFFFF", ip_fold);
        fail_count++;
      end else
        $display("PASS T6 IP checksum: 0xFFFF (valid)");
    end

    // -- T7: Payload "HELLO QM TECH BOARD\n\r" (bytes 50..69) --
    // Frame layout: 8 preamble + 6 dstMAC + 6 srcMAC + 2 ethertype
    //               + 20 IP hdr + 8 UDP hdr = 50 bytes before payload
    $display("-- T7: Payload --");
    begin
      byte unsigned exp_payload[20] = '{
        8'h48, 8'h45, 8'h4C, 8'h4C,  // H E L L
        8'h4F, 8'h20, 8'h51, 8'h4D,  // O   Q M
        8'h54, 8'h45, 8'h43, 8'h48,  // T E C H
        8'h20, 8'h42, 8'h4F, 8'h41,  //   B O A
        8'h52, 8'h44, 8'h0A, 8'h0D   // R D \n \r
      };
      for (int i = 0; i < 20; i++)
        chkb($sformatf("T7 payload[%0d]", i), tx_bytes[50+i], exp_payload[i]);
    end

    // -- T10: tx_er_o never asserted --
    $display("-- T10: tx_er_o never asserted --");
    if (tx_err_seen) begin
      $display("FAIL T10: tx_er_o was asserted");
      fail_count++;
    end else
      $display("PASS T10: tx_er_o never asserted");

    // -- T9: Ethernet CRC residue = 0xDEBB_20E3 --
    // Feed all 66 bytes after preamble (DA+SA+EtherType+IP+UDP+payload+FCS)
    // through the reflected CRC-32/ISO-HDLC engine initialized to 0xFFFFFFFF.
    // Correct Ethernet FCS yields residue 0xDEBB_20E3 (reflected-algorithm
    // convention; the IEEE 802.3 MSB-first equivalent is 0xC704_DD7B =
    // BITREV32(0xDEBB_20E3)).
    $display("-- T9: Ethernet CRC residue --");
    begin
      logic [31:0] residue;
      residue = 32'hFFFF_FFFF;
      for (int i = 8; i < 74; i++)
        residue = crc32_update(residue, tx_bytes[i]);
      chk32("T9 CRC residue", residue, 32'hDEBB_20E3);
    end

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
