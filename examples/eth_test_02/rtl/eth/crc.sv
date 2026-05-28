/**
 * @file        crc.sv
 * @brief       CRC32 datovy overovaci modul.
 * @details     Modul pocita 32-bitove CRC pre ethernetove ramce.
 * @param       Ziadne parametre (odstranene pre cistu syntezu).
 */

`ifndef CRC_SV
`define CRC_SV

`default_nettype none

module crc (
  input  wire         clk_i,
  input  wire         rst_ni,
  input  wire  [7:0]  data_i,
  input  wire         en_i,
  output logic [31:0] crc_o,
  output logic [31:0] crc_next_o
);

  // CRC-32/ISO-HDLC (Ethernet IEEE 802.3): reflected polynomial 0xEDB88320,
  // init 0xFFFFFFFF, RefIn=True, RefOut=True, XorOut=0xFFFFFFFF.
  // Equations derived from 8-bit parallel right-shift LFSR expansion.
  always_comb begin
    crc_next_o[0]  = crc_o[2]  ^ crc_o[8]  ^ data_i[2];
    crc_next_o[1]  = crc_o[0]  ^ crc_o[3]  ^ crc_o[9]  ^ data_i[0] ^ data_i[3];
    crc_next_o[2]  = crc_o[0]  ^ crc_o[1]  ^ crc_o[4]  ^ crc_o[10] ^ data_i[0] ^ data_i[1] ^ data_i[4];
    crc_next_o[3]  = crc_o[1]  ^ crc_o[2]  ^ crc_o[5]  ^ crc_o[11] ^ data_i[1] ^ data_i[2] ^ data_i[5];
    crc_next_o[4]  = crc_o[0]  ^ crc_o[2]  ^ crc_o[3]  ^ crc_o[6]  ^ crc_o[12] ^ data_i[0] ^ data_i[2] ^ data_i[3] ^ data_i[6];
    crc_next_o[5]  = crc_o[1]  ^ crc_o[3]  ^ crc_o[4]  ^ crc_o[7]  ^ crc_o[13] ^ data_i[1] ^ data_i[3] ^ data_i[4] ^ data_i[7];
    crc_next_o[6]  = crc_o[4]  ^ crc_o[5]  ^ crc_o[14] ^ data_i[4] ^ data_i[5];
    crc_next_o[7]  = crc_o[0]  ^ crc_o[5]  ^ crc_o[6]  ^ crc_o[15] ^ data_i[0] ^ data_i[5] ^ data_i[6];
    crc_next_o[8]  = crc_o[1]  ^ crc_o[6]  ^ crc_o[7]  ^ crc_o[16] ^ data_i[1] ^ data_i[6] ^ data_i[7];
    crc_next_o[9]  = crc_o[7]  ^ crc_o[17] ^ data_i[7];
    crc_next_o[10] = crc_o[2]  ^ crc_o[18] ^ data_i[2];
    crc_next_o[11] = crc_o[3]  ^ crc_o[19] ^ data_i[3];
    crc_next_o[12] = crc_o[0]  ^ crc_o[4]  ^ crc_o[20] ^ data_i[0] ^ data_i[4];
    crc_next_o[13] = crc_o[0]  ^ crc_o[1]  ^ crc_o[5]  ^ crc_o[21] ^ data_i[0] ^ data_i[1] ^ data_i[5];
    crc_next_o[14] = crc_o[1]  ^ crc_o[2]  ^ crc_o[6]  ^ crc_o[22] ^ data_i[1] ^ data_i[2] ^ data_i[6];
    crc_next_o[15] = crc_o[2]  ^ crc_o[3]  ^ crc_o[7]  ^ crc_o[23] ^ data_i[2] ^ data_i[3] ^ data_i[7];
    crc_next_o[16] = crc_o[0]  ^ crc_o[2]  ^ crc_o[3]  ^ crc_o[4]  ^ crc_o[24] ^ data_i[0] ^ data_i[2] ^ data_i[3] ^ data_i[4];
    crc_next_o[17] = crc_o[0]  ^ crc_o[1]  ^ crc_o[3]  ^ crc_o[4]  ^ crc_o[5]  ^ crc_o[25] ^ data_i[0] ^ data_i[1] ^ data_i[3] ^ data_i[4] ^ data_i[5];
    crc_next_o[18] = crc_o[0]  ^ crc_o[1]  ^ crc_o[2]  ^ crc_o[4]  ^ crc_o[5]  ^ crc_o[6]  ^ crc_o[26] ^ data_i[0] ^ data_i[1] ^ data_i[2] ^ data_i[4] ^ data_i[5] ^ data_i[6];
    crc_next_o[19] = crc_o[1]  ^ crc_o[2]  ^ crc_o[3]  ^ crc_o[5]  ^ crc_o[6]  ^ crc_o[7]  ^ crc_o[27] ^ data_i[1] ^ data_i[2] ^ data_i[3] ^ data_i[5] ^ data_i[6] ^ data_i[7];
    crc_next_o[20] = crc_o[3]  ^ crc_o[4]  ^ crc_o[6]  ^ crc_o[7]  ^ crc_o[28] ^ data_i[3] ^ data_i[4] ^ data_i[6] ^ data_i[7];
    crc_next_o[21] = crc_o[2]  ^ crc_o[4]  ^ crc_o[5]  ^ crc_o[7]  ^ crc_o[29] ^ data_i[2] ^ data_i[4] ^ data_i[5] ^ data_i[7];
    crc_next_o[22] = crc_o[2]  ^ crc_o[3]  ^ crc_o[5]  ^ crc_o[6]  ^ crc_o[30] ^ data_i[2] ^ data_i[3] ^ data_i[5] ^ data_i[6];
    crc_next_o[23] = crc_o[3]  ^ crc_o[4]  ^ crc_o[6]  ^ crc_o[7]  ^ crc_o[31] ^ data_i[3] ^ data_i[4] ^ data_i[6] ^ data_i[7];
    crc_next_o[24] = crc_o[0]  ^ crc_o[2]  ^ crc_o[4]  ^ crc_o[5]  ^ crc_o[7]  ^ data_i[0] ^ data_i[2] ^ data_i[4] ^ data_i[5] ^ data_i[7];
    crc_next_o[25] = crc_o[0]  ^ crc_o[1]  ^ crc_o[2]  ^ crc_o[3]  ^ crc_o[5]  ^ crc_o[6]  ^ data_i[0] ^ data_i[1] ^ data_i[2] ^ data_i[3] ^ data_i[5] ^ data_i[6];
    crc_next_o[26] = crc_o[0]  ^ crc_o[1]  ^ crc_o[2]  ^ crc_o[3]  ^ crc_o[4]  ^ crc_o[6]  ^ crc_o[7]  ^ data_i[0] ^ data_i[1] ^ data_i[2] ^ data_i[3] ^ data_i[4] ^ data_i[6] ^ data_i[7];
    crc_next_o[27] = crc_o[1]  ^ crc_o[3]  ^ crc_o[4]  ^ crc_o[5]  ^ crc_o[7]  ^ data_i[1] ^ data_i[3] ^ data_i[4] ^ data_i[5] ^ data_i[7];
    crc_next_o[28] = crc_o[0]  ^ crc_o[4]  ^ crc_o[5]  ^ crc_o[6]  ^ data_i[0] ^ data_i[4] ^ data_i[5] ^ data_i[6];
    crc_next_o[29] = crc_o[0]  ^ crc_o[1]  ^ crc_o[5]  ^ crc_o[6]  ^ crc_o[7]  ^ data_i[0] ^ data_i[1] ^ data_i[5] ^ data_i[6] ^ data_i[7];
    crc_next_o[30] = crc_o[0]  ^ crc_o[1]  ^ crc_o[6]  ^ crc_o[7]  ^ data_i[0] ^ data_i[1] ^ data_i[6] ^ data_i[7];
    crc_next_o[31] = crc_o[1]  ^ crc_o[7]  ^ data_i[1] ^ data_i[7];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      crc_o <= '1;
    end else if (en_i) begin
      crc_o <= crc_next_o;
    end
  end

endmodule

`endif // CRC_SV
