`timescale 1ns/1ps

// Integration test for udp.sv -- RX path only
//
// Sends one Ethernet/IPv4/UDP frame through the udp module and verifies
// the RX outputs. TX is wired with static lengths; we don't check TX output.
//
// T1: data_receive_o goes high after frame ends
// T2: ram_wr_data_o == 32'h54455354 ("TEST") on the last data write
// T3: rx_data_length_o == 16'h000C (UDP length field = 8 header + 4 payload)
// T4: rx_total_length_o == 16'h0020 (IP total length = 32)
//
// Run (from sim/):
//   vlog -sv -suppress 2892 \
//        ../rtl/crc.sv ../rtl/ipsend.sv ../rtl/ipreceive.sv ../rtl/udp.sv \
//        integration/tb_udp_rx_path.sv
//   vsim -c -do "run -all; quit" tb_udp_rx_path

module tb_udp_rx_path;

  int fail_count = 0;

  logic        clk = 1'b0;
  logic        rst_ni;
  logic [7:0]  rx_data_i;
  logic        rx_dv_i;

  logic        tx_en_o;
  logic [7:0]  tx_data_o;
  logic        tx_er_o;
  logic        data_o_valid_o;
  logic [31:0] ram_wr_data_o;
  logic [15:0] rx_total_length_o;
  logic [3:0]  rx_state_o;
  logic [15:0] rx_data_length_o;
  logic [8:0]  ram_wr_addr_o;
  logic [3:0]  tx_state_o;
  logic [8:0]  ram_rd_addr_o;
  logic        data_receive_o;

  // Static TX inputs (TX path not under test here)
  logic [31:0] ram_rd_data_i  = 32'd0;
  logic [15:0] tx_data_length_i  = 16'd28;
  logic [15:0] tx_total_length_i = 16'd48;

  always #4 clk = ~clk;  // 125 MHz

  udp dut (
    .rst_ni            (rst_ni),
    .clk_i             (clk),
    .rx_data_i         (rx_data_i),
    .rx_dv_i           (rx_dv_i),
    .tx_en_o           (tx_en_o),
    .tx_data_o         (tx_data_o),
    .tx_er_o           (tx_er_o),
    .data_o_valid_o    (data_o_valid_o),
    .ram_wr_data_o     (ram_wr_data_o),
    .rx_total_length_o (rx_total_length_o),
    .rx_state_o        (rx_state_o),
    .rx_data_length_o  (rx_data_length_o),
    .ram_wr_addr_o     (ram_wr_addr_o),
    .ram_rd_data_i     (ram_rd_data_i),
    .tx_state_o        (tx_state_o),
    .tx_data_length_i  (tx_data_length_i),
    .tx_total_length_i (tx_total_length_i),
    .ram_rd_addr_o     (ram_rd_addr_o),
    .data_receive_o    (data_receive_o)
  );

  task automatic chk(input string tag, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08x exp=0x%08x", tag, got, exp);
      fail_count++;
    end else begin
      $display("PASS %s: 0x%08x", tag, got);
    end
  endtask

  task automatic send_byte(input logic [7:0] b);
    @(negedge clk); #1;
    rx_data_i = b;
    rx_dv_i   = 1'b1;
  endtask

  localparam int FRAME_LEN = 54;
  logic [7:0] frame [0:FRAME_LEN-1];

  initial begin
    // Preamble + SFD
    frame[0] =8'h55; frame[1] =8'h55; frame[2] =8'h55; frame[3] =8'h55;
    frame[4] =8'h55; frame[5] =8'h55; frame[6] =8'h55; frame[7] =8'hD5;
    // Dst MAC: 00:0A:35:01:FE:C0 (FPGA MAC)
    frame[8] =8'h00; frame[9] =8'h0A; frame[10]=8'h35; frame[11]=8'h01;
    frame[12]=8'hFE; frame[13]=8'hC0;
    // Src MAC: DE:AD:BE:EF:12:34
    frame[14]=8'hDE; frame[15]=8'hAD; frame[16]=8'hBE; frame[17]=8'hEF;
    frame[18]=8'h12; frame[19]=8'h34;
    // EtherType: IPv4
    frame[20]=8'h08; frame[21]=8'h00;
    // IPv4 header
    frame[22]=8'h45; frame[23]=8'h00; frame[24]=8'h00; frame[25]=8'h20;
    frame[26]=8'h00; frame[27]=8'h01; frame[28]=8'h40; frame[29]=8'h00;
    frame[30]=8'h40; frame[31]=8'h11; frame[32]=8'h00; frame[33]=8'h00;
    frame[34]=8'hC0; frame[35]=8'hA8; frame[36]=8'h01; frame[37]=8'h01;
    frame[38]=8'hC0; frame[39]=8'hA8; frame[40]=8'h01; frame[41]=8'h32;
    // UDP header: src=12345 dst=50000 len=12 chk=0
    frame[42]=8'h30; frame[43]=8'h39; frame[44]=8'hC3; frame[45]=8'h50;
    frame[46]=8'h00; frame[47]=8'h0C; frame[48]=8'h00; frame[49]=8'h00;
    // Payload: "TEST"
    frame[50]=8'h54; frame[51]=8'h45; frame[52]=8'h53; frame[53]=8'h54;
  end

  // Latch ram_wr_data_o on the last valid write
  logic [31:0] last_wr_data;
  always_ff @(posedge clk) begin
    if (data_o_valid_o) last_wr_data <= ram_wr_data_o;
  end

  initial begin
    rx_data_i = 8'h00;
    rx_dv_i   = 1'b0;
    rst_ni    = 1'b0;
    repeat (4) @(posedge clk); #1;
    rst_ni = 1'b1;
    repeat (2) @(posedge clk); #1;

    for (int i = 0; i < FRAME_LEN; i++) send_byte(frame[i]);
    @(negedge clk); #1;
    rx_dv_i = 1'b0;

    // Wait for ST_RX_FINISH -> ST_IDLE
    repeat (6) @(posedge clk); #1;

    chk("T1 data_receive_o", {31'd0, data_receive_o}, 32'd1);
    chk("T2 last ram_wr_data (TEST)", last_wr_data, 32'h54455354);
    chk("T3 rx_data_length_o", {16'd0, rx_data_length_o}, 32'h0000000C);
    chk("T4 rx_total_length_o", {16'd0, rx_total_length_o}, 32'h00000020);

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
