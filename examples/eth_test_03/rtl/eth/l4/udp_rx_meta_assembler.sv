/**
 * @file udp_rx_meta_assembler.sv
 * @brief Collects per-layer RX metadata and presents udp_packet_meta_t to the application.
 * @details Latches src/dst MAC (from eth_header_parser), src/dst IP (from
 *   ipv4_header_parser), and src/dst port + payload_len from udp_header_parser's
 *   _pre outputs on the cycle when udp_hdr_pre_valid_i=1 (last UDP header byte,
 *   1 cycle before hdr_valid_o rises).
 *
 *   Using hdr_pre_valid_i with _pre port values eliminates the 1-cycle
 *   edge-detection delay of the old design, letting udp_echo_app enter ST_RX
 *   one cycle earlier so it captures the very first payload byte.
 *
 * Ports:
 *   clk_i, rst_ni              — clock / active-low async reset
 *   eth_src_mac_i[47:0]        — from eth_header_parser.rx_src_mac_o
 *   eth_dst_mac_i[47:0]        — from eth_header_parser.rx_dst_mac_o
 *   ip_src_i[31:0]             — from ipv4_header_parser.src_ip_o
 *   ip_dst_i[31:0]             — from ipv4_header_parser.dst_ip_o
 *   udp_src_port_i[15:0]       — from udp_header_parser.src_port_pre_o
 *   udp_dst_port_i[15:0]       — from udp_header_parser.dst_port_pre_o
 *   udp_payload_len_i[15:0]    — from udp_header_parser.payload_len_pre_o
 *   udp_hdr_pre_valid_i        — from udp_header_parser.hdr_pre_valid_o
 *   rx_meta_valid_o            — asserted the cycle after udp_hdr_pre_valid_i
 *   rx_meta_ready_i            — from udp_echo_app.rx_meta_ready_o
 *   rx_meta_o                  — assembled udp_packet_meta_t
 */

`ifndef UDP_RX_META_ASSEMBLER_SV
`define UDP_RX_META_ASSEMBLER_SV

`default_nettype none

module udp_rx_meta_assembler (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic [47:0] eth_src_mac_i,
  input  wire logic [47:0] eth_dst_mac_i,
  input  wire logic [31:0] ip_src_i,
  input  wire logic [31:0] ip_dst_i,
  input  wire logic [15:0] udp_src_port_i,
  input  wire logic [15:0] udp_dst_port_i,
  input  wire logic [15:0] udp_payload_len_i,
  input  wire logic        udp_hdr_pre_valid_i,

  output      logic        rx_meta_valid_o,
  input  wire logic        rx_meta_ready_i,
  output      eth_pkg::udp_packet_meta_t rx_meta_o
);

  logic valid_q;
  eth_pkg::udp_packet_meta_t meta_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0;
      meta_q  <= '0;
    end else begin
      if (udp_hdr_pre_valid_i) begin
        // Last UDP header byte: latch all metadata from _pre ports (based on
        // header_next_w in udp_header_parser, which has all 8 header bytes valid).
        valid_q <= 1'b1;
        meta_q  <= '{
          src_mac:     eth_src_mac_i,
          dst_mac:     eth_dst_mac_i,
          src_ip:      ip_src_i,
          dst_ip:      ip_dst_i,
          src_port:    udp_src_port_i,
          dst_port:    udp_dst_port_i,
          payload_len: udp_payload_len_i
        };
      end else if (valid_q && rx_meta_ready_i) begin
        valid_q <= 1'b0;
      end
    end
  end

  assign rx_meta_valid_o = valid_q;
  assign rx_meta_o       = meta_q;

endmodule

`endif // UDP_RX_META_ASSEMBLER_SV
