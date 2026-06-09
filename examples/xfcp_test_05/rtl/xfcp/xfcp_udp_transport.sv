/**
 * @file        xfcp_udp_transport.sv
 * @brief       Top-level modul spájajúci RX a TX UDP adaptéry.
 * @details     Poskytuje jednotné rozhranie medzi UDP stackom a XFCP parserom.
 * Udržiava kontext (IP, port) pre asynchrónne request/response operácie.
 * @param       XFCP_PORT Zdrojový UDP port pre odosielané pakety (default: 50000).
 */

`ifndef XFCP_UDP_TRANSPORT_SV
`define XFCP_UDP_TRANSPORT_SV

`default_nettype none

module xfcp_udp_transport #(
  parameter logic [15:0] XFCP_PORT = 16'd50000
)(
  input  logic        clk_i,
  input  logic        rst_ni,

  // UDP RX Interface
  input  logic        udp_rx_valid_i,
  output logic        udp_rx_ready_o,
  input  logic [7:0]  udp_rx_data_i,
  input  logic        udp_rx_last_i,
  input  logic [31:0] udp_rx_src_ip_i,
  input  logic [15:0] udp_rx_src_port_i,
  input  logic [15:0] udp_rx_dst_port_i,

  // UDP TX Interface
  output logic        udp_tx_valid_o,
  input  logic        udp_tx_ready_i,
  output logic [7:0]  udp_tx_data_o,
  output logic        udp_tx_last_o,
  output logic        udp_tx_meta_valid_o,
  input  logic        udp_tx_meta_ready_i,
  output logic [31:0] udp_tx_dst_ip_o,
  output logic [15:0] udp_tx_dst_port_o,
  output logic [15:0] udp_tx_src_port_o,

  // XFCP Fabric Interface
  output logic        xfcp_rx_valid_o,
  input  logic        xfcp_rx_ready_i,
  output logic [7:0]  xfcp_rx_data_o,
  output logic        xfcp_rx_last_o,

  input  logic        xfcp_tx_valid_i,
  output logic        xfcp_tx_ready_o,
  input  logic [7:0]  xfcp_tx_data_i,
  input  logic        xfcp_tx_last_i
);

  logic [31:0] shared_ip_w;
  logic [15:0] shared_port_w;

  xfcp_udp_rx_adapter #(
    .XFCP_PORT (XFCP_PORT)
  ) u_rx_adapter (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),

    .udp_rx_valid_i    (udp_rx_valid_i),
    .udp_rx_ready_o    (udp_rx_ready_o),
    .udp_rx_data_i     (udp_rx_data_i),
    .udp_rx_last_i     (udp_rx_last_i),
    .udp_rx_src_ip_i   (udp_rx_src_ip_i),
    .udp_rx_src_port_i (udp_rx_src_port_i),
    .udp_rx_dst_port_i (udp_rx_dst_port_i),

    .xfcp_rx_valid_o   (xfcp_rx_valid_o),
    .xfcp_rx_ready_i   (xfcp_rx_ready_i),
    .xfcp_rx_data_o    (xfcp_rx_data_o),
    .xfcp_rx_last_o    (xfcp_rx_last_o),

    .saved_src_ip_o    (shared_ip_w),
    .saved_src_port_o  (shared_port_w)
  );

  xfcp_udp_tx_adapter #(
    .XFCP_PORT (XFCP_PORT)
  ) u_tx_adapter (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),

    .saved_dst_ip_i      (shared_ip_w),
    .saved_dst_port_i    (shared_port_w),

    .xfcp_tx_valid_i     (xfcp_tx_valid_i),
    .xfcp_tx_ready_o     (xfcp_tx_ready_o),
    .xfcp_tx_data_i      (xfcp_tx_data_i),
    .xfcp_tx_last_i      (xfcp_tx_last_i),

    .udp_tx_meta_valid_o (udp_tx_meta_valid_o),
    .udp_tx_meta_ready_i (udp_tx_meta_ready_i),
    .udp_tx_dst_ip_o     (udp_tx_dst_ip_o),
    .udp_tx_dst_port_o   (udp_tx_dst_port_o),
    .udp_tx_src_port_o   (udp_tx_src_port_o),

    .udp_tx_valid_o      (udp_tx_valid_o),
    .udp_tx_ready_i      (udp_tx_ready_i),
    .udp_tx_data_o       (udp_tx_data_o),
    .udp_tx_last_o       (udp_tx_last_o)
  );

endmodule

`default_nettype wire

`endif // XFCP_UDP_TRANSPORT_SV
