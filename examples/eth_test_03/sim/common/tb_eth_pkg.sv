/**
 * @file tb_eth_pkg.sv
 * @brief Simulation-only package: golden CRC32 and Ethernet frame helpers.
 * @details Functions mirror IEEE 802.3 LSB-first CRC32 (polynomial 0xEDB88320).
 * Golden test vector: CRC32("123456789") == 32'hCBF43926.
 */

`ifndef TB_ETH_PKG_SV
`define TB_ETH_PKG_SV

package tb_eth_pkg;

  // Golden LSB-first CRC32 (IEEE 802.3).
  // Returns FCS = ~crc_reg after processing n bytes.
  function automatic logic [31:0] crc32(input logic [7:0] data[], input int n);
    logic [31:0] crc;
    logic        fb;
    crc = 32'hFFFF_FFFF;
    for (int b = 0; b < n; b++) begin
      for (int i = 0; i < 8; i++) begin
        fb  = crc[0] ^ data[b][i];
        crc = crc >> 1;
        if (fb) crc ^= 32'hEDB8_8320;
      end
    end
    return ~crc;
  endfunction

  // Build 14-byte Ethernet header into a flat array.
  function automatic void build_eth_hdr(
    input  logic [47:0] dst_mac,
    input  logic [47:0] src_mac,
    input  logic [15:0] ethertype,
    output logic [7:0]  hdr[14]
  );
    hdr[ 0] = dst_mac[47:40]; hdr[ 1] = dst_mac[39:32];
    hdr[ 2] = dst_mac[31:24]; hdr[ 3] = dst_mac[23:16];
    hdr[ 4] = dst_mac[15:8];  hdr[ 5] = dst_mac[7:0];
    hdr[ 6] = src_mac[47:40]; hdr[ 7] = src_mac[39:32];
    hdr[ 8] = src_mac[31:24]; hdr[ 9] = src_mac[23:16];
    hdr[10] = src_mac[15:8];  hdr[11] = src_mac[7:0];
    hdr[12] = ethertype[15:8]; hdr[13] = ethertype[7:0];
  endfunction

endpackage

`endif // TB_ETH_PKG_SV
