`timescale 1ns/1ps

// Unit test for ipsend.sv -- TX FSM smoke test
//
// ipsend has a 32-bit timer before it fires (32'h04000000 cycles).
// This testbench uses `force` to inject the magic value so we skip waiting.
//
// T1: after force, FSM starts and tx_en_o goes high
// T2: first 8 TX bytes are preamble (7x 0x55, 1x 0xD5)
// T3: tx_er_o stays 0 during preamble
//
// Run:
//   vlog -sv -suppress 2892 ../rtl/ipsend.sv unit/tb_ipsend_static_packet.sv
//   vsim -c -do "run -all; quit" tb_ipsend_static_packet

module tb_ipsend_static_packet;

  int fail_count = 0;

  logic        clk = 1'b0;
  logic        rst_ni;
  logic        tx_en_o;
  logic        tx_er_o;
  logic [7:0]  tx_data_o;
  logic [31:0] crc_i;
  logic [31:0] ram_rd_data_i;
  logic        crc_en_o;
  logic        crc_rst_no;
  logic [3:0]  tx_state_o;
  logic [15:0] tx_data_length_i;
  logic [15:0] tx_total_length_i;
  logic [8:0]  ram_rd_addr_o;

  // ipsend uses posedge clk_i (eth_tx_clk domain in HW)
  always #5 clk = ~clk;

  ipsend dut (
    .clk_i             (clk),
    .rst_ni            (rst_ni),
    .tx_en_o           (tx_en_o),
    .tx_er_o           (tx_er_o),
    .tx_data_o         (tx_data_o),
    .crc_i             (crc_i),
    .ram_rd_data_i     (ram_rd_data_i),
    .crc_en_o          (crc_en_o),
    .crc_rst_no        (crc_rst_no),
    .tx_state_o        (tx_state_o),
    .tx_data_length_i  (tx_data_length_i),
    .tx_total_length_i (tx_total_length_i),
    .ram_rd_addr_o     (ram_rd_addr_o)
  );

  task automatic chkb(input string tag, input logic [7:0] got, input logic [7:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%02x exp=0x%02x", tag, got, exp);
      fail_count++;
    end else begin
      $display("PASS %s: 0x%02x", tag, got);
    end
  endtask

  task automatic chk1(input string tag, input logic got, input logic exp);
    if (got !== exp) begin
      $display("FAIL %s: got=%0b exp=%0b", tag, got, exp);
      fail_count++;
    end else begin
      $display("PASS %s: %0b", tag, got);
    end
  endtask

  // Capture 8 bytes of TX data starting at the first byte where tx_en_o=1
  task automatic capture_preamble(output logic [7:0] bytes [0:7]);
    int i;
    // wait for tx_en_o
    @(negedge clk);
    while (!tx_en_o) @(negedge clk);
    for (i = 0; i < 8; i++) begin
      bytes[i] = tx_data_o;
      if (i < 7) @(negedge clk);
    end
  endtask

  initial begin
    rst_ni            = 1'b0;
    crc_i             = 32'd0;
    ram_rd_data_i     = 32'hAABBCCDD;
    tx_data_length_i  = 16'd28;
    tx_total_length_i = 16'd48;

    repeat (4) @(negedge clk); #1;
    rst_ni = 1'b1;
    repeat (2) @(negedge clk); #1;

    // -- Force timer to trigger value --
    // ipsend FSM is in ST_IDLE, time_counter_q increments each negedge.
    // Force it to 32'h04000000 so the condition fires on the next negedge.
    force dut.time_counter_q = 32'h04000000;
    @(negedge clk);   // FSM sees timer match -> ST_START, clears timer
    #1;
    release dut.time_counter_q;

    // Wait: ST_START(1) + ST_MAKE(6 pipeline) + enter ST_SEND_55(1) = 8 more negedges
    repeat (8) @(negedge clk); #1;

    // -- T1: tx_en_o should be 1 --
    $display("-- T1: tx_en_o active --");
    chk1("T1 tx_en_o", tx_en_o, 1'b1);

    // -- T2: first byte is preamble 0x55 --
    $display("-- T2: preamble bytes --");
    chkb("T2 byte[0]", tx_data_o, 8'h55);
    // Advance through preamble (8 bytes: 7x55 + D5)
    for (int i = 1; i < 7; i++) begin
      @(negedge clk); #1;
      chkb($sformatf("T2 byte[%0d]", i), tx_data_o, 8'h55);
    end
    @(negedge clk); #1;
    chkb("T2 byte[7] SFD", tx_data_o, 8'hD5);

    // -- T3: tx_er_o stays 0 during preamble --
    $display("-- T3: tx_er_o=0 --");
    chk1("T3 tx_er_o", tx_er_o, 1'b0);

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
