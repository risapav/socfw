`timescale 1ns/1ps

// Unit test for ipreceive.sv -- receives one minimal Ethernet/IPv4/UDP frame
//
// Frame: dst=00:0A:35:01:FE:C0 (FPGA MAC, required by filter)
//        src=DE:AD:BE:EF:12:34
//        IPv4 src=192.168.1.1, dst=192.168.1.50
//        UDP src=12345, dst=50000, payload="TEST"
//
// T1: board_mac_o, pc_mac_o
// T2: rx_total_length_o, rx_data_length_o
// T3: data_receive_o, data_o (payload word)
// T4: drop on wrong dst MAC
//
// Run:
//   vlog -sv -suppress 2892 ../rtl/ipreceive.sv unit/tb_ipreceive_udp_frame.sv
//   vsim -c -do "run -all; quit" tb_ipreceive_udp_frame

module tb_ipreceive_udp_frame;

  int fail_count = 0;

  logic        clk   = 1'b0;
  logic        rst_ni;
  logic [7:0]  rx_data_i;
  logic        rx_dv_i;

  logic [47:0]  board_mac_o;
  logic [47:0]  pc_mac_o;
  logic [15:0]  ip_protocol_o;
  logic         valid_ip_p_o;
  logic [159:0] ip_layer_o;
  logic [31:0]  pc_ip_o;
  logic [31:0]  board_ip_o;
  logic [63:0]  udp_layer_o;
  logic [31:0]  data_o;
  logic [15:0]  rx_total_length_o;
  logic         data_o_valid_o;
  logic [3:0]   rx_state_o;
  logic [15:0]  rx_data_length_o;
  logic [8:0]   ram_wr_addr_o;
  logic         data_receive_o;

  always #4 clk = ~clk;  // 125 MHz

  ipreceive dut (
    .clk_i            (clk),
    .rst_ni           (rst_ni),
    .rx_data_i        (rx_data_i),
    .rx_dv_i          (rx_dv_i),
    .board_mac_o      (board_mac_o),
    .pc_mac_o         (pc_mac_o),
    .ip_protocol_o    (ip_protocol_o),
    .valid_ip_p_o     (valid_ip_p_o),
    .ip_layer_o       (ip_layer_o),
    .pc_ip_o          (pc_ip_o),
    .board_ip_o       (board_ip_o),
    .udp_layer_o      (udp_layer_o),
    .data_o           (data_o),
    .rx_total_length_o(rx_total_length_o),
    .data_o_valid_o   (data_o_valid_o),
    .rx_state_o       (rx_state_o),
    .rx_data_length_o (rx_data_length_o),
    .ram_wr_addr_o    (ram_wr_addr_o),
    .data_receive_o   (data_receive_o)
  );

  task automatic chk(input string tag, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%016x exp=0x%016x", tag, got, exp);
      fail_count++;
    end else begin
      $display("PASS %s: 0x%x", tag, got);
    end
  endtask

  // Drive one byte on negedge so it is stable when FSM samples on posedge
  task automatic send_byte(input logic [7:0] b);
    @(negedge clk); #1;
    rx_data_i = b;
    rx_dv_i   = 1'b1;
  endtask

  // Full Ethernet/IPv4/UDP frame with "TEST" payload
  // dst MAC must be FPGA's MAC (00:0A:35:01:FE:C0) to pass the filter
  localparam int FRAME_LEN = 54;
  logic [7:0] frame [0:FRAME_LEN-1];

  initial begin
    // Preamble + SFD (8 bytes)
    frame[0]  = 8'h55; frame[1]  = 8'h55; frame[2]  = 8'h55; frame[3]  = 8'h55;
    frame[4]  = 8'h55; frame[5]  = 8'h55; frame[6]  = 8'h55; frame[7]  = 8'hD5;
    // Dst MAC: 00:0A:35:01:FE:C0
    frame[8]  = 8'h00; frame[9]  = 8'h0A; frame[10] = 8'h35; frame[11] = 8'h01;
    frame[12] = 8'hFE; frame[13] = 8'hC0;
    // Src MAC: DE:AD:BE:EF:12:34
    frame[14] = 8'hDE; frame[15] = 8'hAD; frame[16] = 8'hBE; frame[17] = 8'hEF;
    frame[18] = 8'h12; frame[19] = 8'h34;
    // EtherType: 0x0800 (IPv4)
    frame[20] = 8'h08; frame[21] = 8'h00;
    // IPv4 header (20 bytes): IHL=5, TotalLen=0x0020, Proto=17 (UDP)
    frame[22] = 8'h45; frame[23] = 8'h00; frame[24] = 8'h00; frame[25] = 8'h20;
    frame[26] = 8'h00; frame[27] = 8'h01; frame[28] = 8'h40; frame[29] = 8'h00;
    frame[30] = 8'h40; frame[31] = 8'h11; frame[32] = 8'h00; frame[33] = 8'h00;
    // Src IP: 192.168.1.1
    frame[34] = 8'hC0; frame[35] = 8'hA8; frame[36] = 8'h01; frame[37] = 8'h01;
    // Dst IP: 192.168.1.50
    frame[38] = 8'hC0; frame[39] = 8'hA8; frame[40] = 8'h01; frame[41] = 8'h32;
    // UDP: src=12345, dst=50000, len=12, checksum=0
    frame[42] = 8'h30; frame[43] = 8'h39; frame[44] = 8'hC3; frame[45] = 8'h50;
    frame[46] = 8'h00; frame[47] = 8'h0C; frame[48] = 8'h00; frame[49] = 8'h00;
    // Payload: "TEST"
    frame[50] = 8'h54; frame[51] = 8'h45; frame[52] = 8'h53; frame[53] = 8'h54;
  end

  initial begin
    rx_data_i = 8'h00;
    rx_dv_i   = 1'b0;
    rst_ni    = 1'b0;
    repeat (4) @(posedge clk); #1;
    rst_ni = 1'b1;
    repeat (2) @(posedge clk); #1;

    // -- T1-T3: send valid frame --
    $display("-- T1-T3: valid UDP frame --");
    for (int i = 0; i < FRAME_LEN; i++) send_byte(frame[i]);
    @(negedge clk); #1;
    rx_dv_i = 1'b0;

    // Wait for ST_RX_FINISH -> ST_IDLE (~3 extra cycles)
    repeat (4) @(posedge clk); #1;

    chk("T1 board_mac_o", {16'd0, board_mac_o}, {16'd0, 48'h000A3501FEC0});
    chk("T1 pc_mac_o",    {16'd0, pc_mac_o},    {16'd0, 48'hDEADBEEF1234});
    chk("T2 rx_total_length_o", {48'd0, rx_total_length_o}, {48'd0, 16'h0020});
    chk("T2 rx_data_length_o",  {48'd0, rx_data_length_o},  {48'd0, 16'h000C});
    chk("T3 data_receive_o",    {63'd0, data_receive_o},    64'd1);
    chk("T3 data_o (TEST)",     {32'd0, data_o},            {32'd0, 32'h54455354});

    // -- T4: wrong dst MAC is dropped (data_receive_o stays 1 from T3) --
    $display("-- T4: wrong dst MAC -- drop expected --");
    // Reset first to clear data_receive_o
    rst_ni = 1'b0;
    repeat (2) @(posedge clk); #1;
    rst_ni = 1'b1;
    repeat (2) @(posedge clk); #1;

    // Send frame with dst MAC = FF:FF:FF:FF:FF:FF (broadcast, filter will reject)
    send_byte(8'h55); send_byte(8'h55); send_byte(8'h55); send_byte(8'h55);
    send_byte(8'h55); send_byte(8'h55); send_byte(8'h55); send_byte(8'hD5);
    // Wrong dst MAC: FF:FF:FF:FF:FF:FF
    for (int i = 0; i < 6; i++) send_byte(8'hFF);
    // src MAC
    send_byte(8'hDE); send_byte(8'hAD); send_byte(8'hBE); send_byte(8'hEF);
    send_byte(8'h12); send_byte(8'h34);
    @(negedge clk); #1;
    rx_dv_i = 1'b0;

    repeat (4) @(posedge clk); #1;
    chk("T4 data_receive_o=0 (dropped)", {63'd0, data_receive_o}, 64'd0);

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
