`default_nettype none

// HDMI BCH error-correction code generator.
//
// Polynomial: x^8 + x^4 + x^3 + x^2 + 1 → XOR mask 0x1D (bits 4,3,2,0)
// Initial LFSR state: 8'hFF
// Bits processed LSB-first per byte, in byte order HB0..HBn / PB0..PBn.
//
// Two standard configurations (DATA_BITS parameter):
//   DATA_BITS=24 : packet header ECC — 3 header bytes → 8-bit BCH parity
//   DATA_BITS=56 : subpacket ECC    — 7 subpacket bytes → 8-bit BCH parity
//
// Purely combinational: no registers.
module hdmi_bch_ecc #(
  parameter int DATA_BITS = 24
)(
  input  logic [DATA_BITS-1:0] data_i,
  output logic [7:0]           ecc_o
);

  // LFSR driven combinationally — for loop unrolls to a gate chain in synthesis.
  // Module-level variable avoids tool issues with always_comb-local declarations.
  logic [7:0] lfsr;

  always_comb begin
    lfsr = 8'hFF;
    for (int i = 0; i < DATA_BITS; i++) begin
      if (data_i[i] ^ lfsr[7])
        lfsr = {lfsr[6:0], 1'b0} ^ 8'h1D;
      else
        lfsr = {lfsr[6:0], 1'b0};
    end
  end

  assign ecc_o = lfsr;

endmodule
