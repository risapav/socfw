/**
 * @file eth_crc32_8.sv
 * @brief Combinatorial Ethernet CRC32 (IEEE 802.3) byte-wide wrapper.
 * @details
 * Wraps taxi_lfsr with fixed Ethernet FCS parameters:
 *
 *   - CRC polynomial: 0x04C11DB7
 *   - Galois configuration
 *   - bit-reversed / LSB-first processing
 *   - byte-wide input
 *   - initial state: 32'hFFFFFFFF
 *   - final FCS: bitwise inverted CRC state
 *
 * Feed bytes in Ethernet wire order starting at destination MAC:
 *
 *   DST_MAC, SRC_MAC, EtherType/Length, payload, padding
 *
 * Do not feed:
 *
 *   preamble, SFD, FCS, IFG
 *
 * This module is purely combinatorial. Register crc_o in the caller when
 * crc_en is asserted.
 *
 * Typical TX/RX use:
 *
 *   crc_next = eth_crc32_8(data_byte, crc_state)
 *   crc_state <= crc_next when crc_en
 *   final_fcs = ~crc_state_after_last_included_byte
 *
 * If data_i is the last included byte in the current cycle and crc_o is
 * accepted into the CRC state, then the final FCS for that frame is ~crc_o.
 */

`ifndef ETH_CRC32_8_SV
`define ETH_CRC32_8_SV

`default_nettype none

module eth_crc32_8 (
  input  logic [7:0]  data_i,
  input  logic [31:0] crc_i,
  output logic [31:0] crc_o
);

  taxi_lfsr #(
    .LFSR_W            (32),
    .LFSR_POLY         (32'h04c11db7),
    .LFSR_GALOIS       (1'b1),
    .LFSR_FEED_FORWARD (1'b0),
    .REVERSE           (1'b1),
    .DATA_W            (8),
    .DATA_IN_EN        (1'b1),
    .DATA_OUT_EN       (1'b0),
    .STATE_SHIFT_PRE   (0),
    .STATE_SHIFT_POST  (0)
  ) u_lfsr (
    .data_in   (data_i),
    .state_in  (crc_i),
    .data_out  (),
    .state_out (crc_o)
  );

endmodule

`resetall

`endif  // ETH_CRC32_8_SV
