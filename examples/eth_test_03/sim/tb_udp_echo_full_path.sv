/**
 * @file tb_udp_echo_full_path.sv
 * @brief Full-path simulation: ARP/UDP Echo loopback test.
 */

`timescale 1ns / 1ps

module tb_udp_echo_full_path;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  // Signály pre DUT (Top)
  logic [7:0] rxd;
  logic       rxdv;
  logic       rxer;
  logic [7:0] txd;
  logic       txen;
  logic       txer;

  // Clock generátor
  always #4 clk = ~clk; // 125 MHz (8ns per cycle)

  // Inštancia DUT
  ethernet_test_03_top #(
    .LOCAL_MAC(48'h000A3501FEC0),
    .LOCAL_IP(32'hC0A81432)
  ) dut (
    .sys_clk_i(clk),
    .eth_rx_clk_i(clk),
    .eth_tx_clk_i(clk),
    .rst_ni(rst_n),
    .eth_rxd_i(rxd),
    .eth_rxdv_i(rxdv),
    .eth_rxer_i(rxer),
    .eth_txd_o(txd),
    .eth_txen_o(txen),
    .eth_txer_o(txer),
    .led_o()
  );

  initial begin
    // Reset sekvencia
    rst_n = 1'b0;
    #100 rst_n = 1'b1;

    // Tu by nasledovala úloha (Task) na vysielanie paketu
    // 1. Preamble & SFD
    // 2. Ethernet Header
    // 3. IPv4 Header
    // 4. UDP Header
    // 5. Payload
    // 6. FCS

    $display("Test začal...");
    #10000;
    $finish;
  end

endmodule
