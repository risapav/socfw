

/**
 * @file eth_header_builder.sv
 * @brief Serializer for 14-byte Ethernet frame header.
 * * @details This module maps 48-bit MAC addresses and 16-bit EtherType
 * into a sequential 8-bit byte stream, suitable for GMII/AXI-Stream interfaces.
 * Byte order follows the standard network byte order (Big-Endian).
 * * @param dst_mac_i   Destination MAC address [47:0]
 * @param src_mac_i   Source MAC address [47:0]
 * @param ethertype_i EtherType field [15:0]
 * @param byte_idx_i  Current byte index (0-13)
 * @param byte_o      Output byte for the current index
 */

`ifndef ETH_HEADER_BUILDER_SV
`define ETH_HEADER_BUILDER_SV

`default_nettype none

module eth_header_builder (
  input  wire logic [47:0] dst_mac_i,
  input  wire logic [47:0] src_mac_i,
  input  wire logic [15:0] ethertype_i,

  input  wire logic [3:0]  byte_idx_i,
  output      logic [7:0]  byte_o
);

  // Kombinačná logika pre mapovanie vstupných polí na výstupný bajt.
  // Použitie 'unique case' zabezpečuje, že návrh je bezpečný a predvídateľný.
  always_comb begin
    unique case (byte_idx_i)
      // Destination MAC (6 bytes)
      4'd0:  byte_o = dst_mac_i[47:40];
      4'd1:  byte_o = dst_mac_i[39:32];
      4'd2:  byte_o = dst_mac_i[31:24];
      4'd3:  byte_o = dst_mac_i[23:16];
      4'd4:  byte_o = dst_mac_i[15:8];
      4'd5:  byte_o = dst_mac_i[7:0];

      // Source MAC (6 bytes)
      4'd6:  byte_o = src_mac_i[47:40];
      4'd7:  byte_o = src_mac_i[39:32];
      4'd8:  byte_o = src_mac_i[31:24];
      4'd9:  byte_o = src_mac_i[23:16];
      4'd10: byte_o = src_mac_i[15:8];
      4'd11: byte_o = src_mac_i[7:0];

      // EtherType (2 bytes)
      4'd12: byte_o = ethertype_i[15:8];
      4'd13: byte_o = ethertype_i[7:0];

      // Bezpečnostná poistka pre neplatný index
      default: byte_o = 8'h00;
    endcase
  end

endmodule

`endif // ETH_HEADER_BUILDER_SV
