/**
 * @file acr_packet_builder.sv
 * @brief HDMI Audio Clock Regeneration (ACR) Packet Builder
 * @param enable_i Global enable for ACR packet generation
 * @param n_i 20-bit N value for audio clock regeneration
 * @param cts_i 20-bit Cycle Time Stamp (CTS) value
 * @param cts_valid_i Indicates if the current CTS value is valid
 * @param hb_o 3-byte packet header output
 * @param pb_o 28-byte packet payload output
 * @param valid_o Indicates a valid packet is ready for the arbiter
 * @details
 * Builds an HDMI ACR packet (Packet Type 0x01).
 *
 * Payload layout (4 identical subpackets, 7 bytes each) per HDMI 1.3 Table 7-3:
 * PB0 = {4'h0, CTS[19:16]}   MSB nibble of CTS
 * PB1 = CTS[15:8]
 * PB2 = CTS[7:0]              LSB of CTS
 * PB3 = {4'h0, N[19:16]}     MSB nibble of N
 * PB4 = N[15:8]
 * PB5 = N[7:0]                LSB of N
 * PB6 = 8'h00                 Reserved (per HDMI spec, last byte)
 *
 * BCH/ECC is not generated here. It is computed combinatorially
 * over PB0..PB6 by the data_island_formatter.
 */
`default_nettype none

`ifndef ACR_PACKET_BUILDER_SV
`define ACR_PACKET_BUILDER_SV

module acr_packet_builder (
  input  logic        enable_i,

  input  logic [19:0] n_i,
  input  logic [19:0] cts_i,
  input  logic        cts_valid_i,

  output logic [7:0]  hb_o [0:2],
  output logic [7:0]  pb_o [0:27],
  output logic        valid_o
);

  always_comb begin
    // Header Bytes: Type 0x01, remaining are reserved (0)
    hb_o[0] = 8'h01;
    hb_o[1] = 8'h00;
    hb_o[2] = 8'h00;

    // Default all payload bytes to 0
    pb_o = '{default: 8'h00};

    // 4 identical subpackets — HDMI 1.3 Table 7-3 (MSB-first byte order)
    for (int sp = 0; sp < 4; sp++) begin
      pb_o[sp*7 + 0] = {4'h0, cts_i[19:16]};
      pb_o[sp*7 + 1] = cts_i[15:8];
      pb_o[sp*7 + 2] = cts_i[7:0];
      pb_o[sp*7 + 3] = {4'h0, n_i[19:16]};
      pb_o[sp*7 + 4] = n_i[15:8];
      pb_o[sp*7 + 5] = n_i[7:0];
      pb_o[sp*7 + 6] = 8'h00;  // reserved (last byte per spec)
    end

    // Packet is valid only if enabled globally and CTS is ready
    valid_o = enable_i && cts_valid_i;
  end

endmodule

`endif // ACR_PACKET_BUILDER_SV
