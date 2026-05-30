/**
 * @file ipv4_checksum.sv
 * @brief IPv4 header checksum calculator (RFC 791).
 * @details Calculates the 16-bit one's complement sum of all 16-bit words
 * in the header. Implements double-stage carry folding for 20-byte headers.
 */

`ifndef IPV4_CHECKSUM_SV
`define IPV4_CHECKSUM_SV

`default_nettype none


module ipv4_checksum (
  input  wire logic [159:0] header_i, // 20 bytes of IPv4 header
  output      logic [15:0]  checksum_o
);

  logic [19:0] sum;
  logic [16:0] fold1;
  logic [15:0] fold2;

  always_comb begin
    // Súčet desiatich 16-bitových slov
    sum = header_i[159:144] + header_i[143:128] + header_i[127:112] +
          header_i[111:96]  + header_i[95:80]   + header_i[79:64]  +
          header_i[63:48]   + header_i[47:32]   + header_i[31:16]  +
          header_i[15:0];

    // Prvé foldovanie (carry z 20 bitov na 17 bitov)
    fold1 = sum[15:0] + sum[19:16];

    // Druhé foldovanie (pre prípad, že carry z prvej operácie vytvorilo nový prenos)
    fold2 = fold1[15:0] + fold1[16];

    // Negácia výsledku (one's complement)
    checksum_o = ~fold2;
  end

endmodule

`endif // IPV4_CHECKSUM_SV
