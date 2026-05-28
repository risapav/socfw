`timescale 1ns/1ps

// Unit test: ipreceive.data_receive_o je presne 1-cyklovy pulz
//
// T1: data_receive_o assertnuta presne na 1 cyklus po validnom GMII ramci
// T2: data_receive_o = 0 v nasledujucom cykle (nie stuck-high)
// T3: druhy GMII ramec znovu assertne data_receive_o (nie dead-after-first)
// T4: po druhom ramci je data_receive_o = 0

module tb_ipreceive_data_receive_pulse;

  int fail_count = 0;

  logic       clk = 0;
  logic       rst_ni;
  logic [7:0] rx_data = 8'h00;
  logic       rx_dv   = 1'b0;

  always #4 clk = ~clk;  // 125 MHz

  logic [47:0]  board_mac_w;
  logic [47:0]  pc_mac_w;
  logic [15:0]  ip_protocol_w;
  logic         valid_ip_p_w;
  logic [159:0] ip_layer_w;
  logic [31:0]  pc_ip_w;
  logic [31:0]  board_ip_w;
  logic [63:0]  udp_layer_w;
  logic [31:0]  data_out_w;
  logic [15:0]  rx_total_len_w;
  logic         data_o_valid_w;
  logic [3:0]   rx_state_w;
  logic [15:0]  rx_data_len_w;
  logic [8:0]   ram_wr_addr_w;
  logic         data_receive_w;

  ipreceive dut (
    .clk_i             (clk),
    .rst_ni            (rst_ni),
    .rx_data_i         (rx_data),
    .rx_dv_i           (rx_dv),
    .rx_er_i           (1'b0),
    .board_mac_o       (board_mac_w),
    .pc_mac_o          (pc_mac_w),
    .ip_protocol_o     (ip_protocol_w),
    .valid_ip_p_o      (valid_ip_p_w),
    .ip_layer_o        (ip_layer_w),
    .pc_ip_o           (pc_ip_w),
    .board_ip_o        (board_ip_w),
    .udp_layer_o       (udp_layer_w),
    .data_o            (data_out_w),
    .rx_total_length_o (rx_total_len_w),
    .data_o_valid_o    (data_o_valid_w),
    .rx_state_o        (rx_state_w),
    .rx_data_length_o  (rx_data_len_w),
    .ram_wr_addr_o     (ram_wr_addr_w),
    .data_receive_o    (data_receive_w)
  );

  // UDP GMII frame: dst MAC=00:0A:35:01:FE:C0, src IP=192.168.20.100,
  // dst IP=192.168.20.50, src port=4567, dst port=8080, payload "HELLO" (5 B)
  task automatic send_udp_frame();
    automatic byte f [] = '{
      8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'hD5,  // preamble+SFD
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
      @(posedge clk); #1;
      rx_dv   = 1'b1;
      rx_data = f[i];
    end
    @(posedge clk); #1;
    rx_dv   = 1'b0;
    rx_data = 8'h00;
  endtask

  // Verify: exactly 1 high cycle in the 5-cycle window after send, then 0
  task automatic check_pulse(input string thi, input string tlo);
    automatic int pulse_count = 0;
    for (int i = 0; i < 5; i++) begin
      @(posedge clk); #1;
      if (data_receive_w) pulse_count++;
    end
    if (pulse_count == 0) begin
      $display("FAIL %s: data_receive_o nikdy nebol asserted", thi);
      fail_count++;
    end else if (pulse_count > 1) begin
      $display("FAIL %s: data_receive_o trvalo %0d cyklov (ocakavany 1)", thi, pulse_count);
      fail_count++;
    end else begin
      $display("PASS %s: data_receive_o = 1 presne 1 cyklus", thi);
    end
    @(posedge clk); #1;
    if (data_receive_w !== 1'b0) begin
      $display("FAIL %s: data_receive_o nie je 0 po pulse", tlo);
      fail_count++;
    end else begin
      $display("PASS %s: data_receive_o = 0 po pulse", tlo);
    end
  endtask

  initial begin
    rst_ni = 0;
    repeat (4) @(posedge clk); #1;
    rst_ni = 1;
    repeat (2) @(posedge clk); #1;

    $display("-- Paket 1 --");
    send_udp_frame();
    check_pulse("T1 data_receive=1", "T2 data_receive=0");

    repeat (4) @(posedge clk);

    $display("-- Paket 2 --");
    send_udp_frame();
    check_pulse("T3 data_receive=1", "T4 data_receive=0");

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

  initial begin
    #100000;
    $display("FAIL: TIMEOUT");
    $finish;
  end

endmodule
