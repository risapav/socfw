`timescale 1ns/1ps
/**
 * @file tb_eth_pkg.sv
 * @brief Simulation package: CRC32 golden function and Ethernet frame helpers.
 * @details LSB-first CRC32 (polynomial 0xEDB88320 = bit-reversed 0x04c11db7).
 *   Matches eth_crc32_8 / taxi_lfsr with LFSR_GALOIS=1, REVERSE=1.
 *   Golden vector: crc32("123456789") == 32'hCBF43926.
 */
`ifndef TB_ETH_PKG_SV
`define TB_ETH_PKG_SV

package tb_eth_pkg;

  // CRC32 over n bytes, LSB-first.  Returns FCS = ~crc_state.
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
    output logic [7:0]  hdr [14]
  );
    hdr[ 0] = dst_mac[47:40]; hdr[ 1] = dst_mac[39:32];
    hdr[ 2] = dst_mac[31:24]; hdr[ 3] = dst_mac[23:16];
    hdr[ 4] = dst_mac[15:8];  hdr[ 5] = dst_mac[7:0];
    hdr[ 6] = src_mac[47:40]; hdr[ 7] = src_mac[39:32];
    hdr[ 8] = src_mac[31:24]; hdr[ 9] = src_mac[23:16];
    hdr[10] = src_mac[15:8];  hdr[11] = src_mac[7:0];
    hdr[12] = ethertype[15:8]; hdr[13] = ethertype[7:0];
  endfunction

  // Compute FCS for an Ethernet frame (header + payload + optional pad to 46 B).
  // Returns 32-bit FCS in the same bit-order as crc32().
  function automatic logic [31:0] frame_fcs(
    input logic [47:0] dst_mac,
    input logic [47:0] src_mac,
    input logic [15:0] ethertype,
    input logic [7:0]  payload [],
    input int          n_payload
  );
    logic [7:0] hdr [14];
    logic [7:0] d[];
    int         total, pad;
    build_eth_hdr(dst_mac, src_mac, ethertype, hdr);
    pad   = (n_payload < 46) ? (46 - n_payload) : 0;
    total = 14 + n_payload + pad;
    d     = new [total];
    for (int i = 0; i < 14;        i++) d[i]           = hdr[i];
    for (int i = 0; i < n_payload; i++) d[14 + i]      = payload[i];
    for (int i = 0; i < pad;       i++) d[14+n_payload+i] = 8'h00;
    return crc32(d, total);
  endfunction

endpackage

`endif // TB_ETH_PKG_SV
