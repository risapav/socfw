/**
 * @file crc32_eth.sv
 * @brief Ethernet CRC32 calculator (IEEE 802.3).
 * @details Implements LSB-first CRC32 calculation using polynomial 0xEDB88320.
 * FCS is generated as the bitwise NOT of the final CRC register.
 */

`ifndef CRC32_ETH_SV
`define CRC32_ETH_SV

`default_nettype none

module crc32_eth (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic        clear_i,
  input  wire logic        en_i,
  input  wire logic [7:0]  data_i,

  output      logic [31:0] crc_state_o,
  output      logic [31:0] crc_next_o,
  output      logic [31:0] fcs_o
);

  logic [31:0] crc_reg;

  /**
   * @brief LSB-first CRC32 calculation function.
   * @param crc_i Current CRC state
   * @param data_i Data byte to process
   * @return Updated CRC value
   */
  function automatic logic [31:0] next_crc32_lsb(logic [31:0] crc_i, logic [7:0] data_i);
    logic [31:0] c;
    logic        fb;
    c = crc_i;
    for (int i = 0; i < 8; i++) begin
      fb = c[0] ^ data_i[i];
      c  = c >> 1;
      if (fb)
        c ^= 32'hEDB8_8320;
    end
    return c;
  endfunction

  always_comb begin
    crc_next_o = clear_i ? 32'hFFFF_FFFF : next_crc32_lsb(crc_reg, data_i);
    fcs_o      = ~crc_reg;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      crc_reg <= 32'hFFFF_FFFF;
    end else if (clear_i) begin
      crc_reg <= 32'hFFFF_FFFF;
    end else if (en_i) begin
      crc_reg <= crc_next_o;
    end
  end

  assign crc_state_o = crc_reg;

endmodule

`endif // CRC32_ETH_SV
