/**
 * @file        udp.sv
 * @brief       Top modul pre UDP datovu komunikaciu.
 * @details     Zastrasuje moduly pre prijem, vysielanie a vypocet CRC.
 */

`ifndef UDP_SV
`define UDP_SV

`default_nettype none

module udp (
  input  wire         rst_ni,
  input  wire         clk_i,    // eth_rx_clk — RX path clock (PHY recovered)
  input  wire         tx_clk_i, // eth_tx_clk — TX path clock (PLL 125 MHz)
  input  wire  [7:0]  rx_data_i,
  input  wire         rx_dv_i,
  output logic        tx_en_o,
  output logic [7:0]  tx_data_o,
  output logic        tx_er_o,

  output logic        data_o_valid_o,
  output logic [31:0] ram_wr_data_o,
  output logic [15:0] rx_total_length_o,
  output logic [3:0]  rx_state_o,
  output logic [15:0] rx_data_length_o,
  output logic [8:0]  ram_wr_addr_o,

  input  wire  [31:0] ram_rd_data_i,
  output logic [3:0]  tx_state_o,
  input  wire  [15:0] tx_data_length_i,
  input  wire  [15:0] tx_total_length_i,
  output logic [8:0]  ram_rd_addr_o,
  output logic        data_receive_o
);

  logic [31:0] crc_next_w;
  logic [31:0] crc_w;
  logic        crc_rst_nw;
  logic        crc_en_w;

  ipsend u_ip_send (
    .clk_i             (tx_clk_i),
    .rst_ni            (rst_ni),
    .tx_en_o           (tx_en_o),
    .tx_er_o           (tx_er_o),
    .tx_data_o         (tx_data_o),
    .crc_i             (crc_next_w),
    .ram_rd_data_i     (ram_rd_data_i),
    .crc_en_o          (crc_en_w),
    .crc_rst_no        (crc_rst_nw),
    .tx_state_o        (tx_state_o),
    .tx_data_length_i  (tx_data_length_i),
    .tx_total_length_i (tx_total_length_i),
    .ram_rd_addr_o     (ram_rd_addr_o)
  );

  crc u_crc (
    .clk_i             (tx_clk_i),
    .rst_ni            (crc_rst_nw),
    .data_i            (tx_data_o),
    .en_i              (crc_en_w),
    .crc_o             (crc_w),
    .crc_next_o        (crc_next_w)
  );

  ipreceive u_ip_receive (
    .clk_i             (clk_i),
    .rst_ni             (rst_ni),
    .rx_data_i         (rx_data_i),
    .rx_dv_i           (rx_dv_i),
    .board_mac_o       (),
    .pc_mac_o          (),
    .ip_protocol_o     (),
    .valid_ip_p_o      (),
    .ip_layer_o        (),
    .pc_ip_o           (),
    .board_ip_o        (),
    .udp_layer_o       (),
    .data_o            (ram_wr_data_o),
    .rx_total_length_o (rx_total_length_o),
    .data_o_valid_o    (data_o_valid_o),
    .rx_state_o        (rx_state_o),
    .rx_data_length_o  (rx_data_length_o),
    .ram_wr_addr_o     (ram_wr_addr_o),
    .data_receive_o    (data_receive_o)
  );

endmodule

`endif // UDP_SV
