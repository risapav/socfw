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
// Purely combinational: no pipeline, no registers.
module hdmi_bch_ecc #(
  parameter int DATA_BITS = 24   // 24 for header ECC, 56 for subpacket ECC
)(
  input  logic [DATA_BITS-1:0] data_i,  // data bits, LSB-first byte order
  output logic [7:0]           ecc_o
);

  // BCH LFSR: shift left, XOR with 0x1D on feedback.
  // After shift: lfsr = {lfsr[6:0], 1'b0}; if feedback: lfsr ^= 8'h1D
  always_comb begin : bch_compute
    logic [7:0] lfsr;
    logic       fb;

    lfsr = 8'hFF;

    for (int i = 0; i < DATA_BITS; i++) begin
      fb   = data_i[i] ^ lfsr[7];
      lfsr = {lfsr[6:0], 1'b0};
      if (fb)
        lfsr ^= 8'h1D;
    end

    ecc_o = lfsr;
  end

endmodule
