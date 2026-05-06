`ifndef GCP_PACKET_BUILDER_SV
`define GCP_PACKET_BUILDER_SV

`default_nettype none

// General Control Packet builder (HDMI 1.4a §8.2.2).
//
// For basic 8-bit (24-bit) RGB operation:
//   HB0 = 0x00  (packet type)
//   HB1 = 0x00  (reserved)
//   HB2 = 0x00  (reserved)
//   SB0[7] = Set_AVMUTE  = 0
//   SB0[6] = Clear_AVMUTE = 0
//   SB0[3:0] = CD = 4'b0000 (color depth not indicated)
//   All other bytes = 0
//
// If avmute_i is asserted the GCP signals AVMUTE to the sink (e.g. during
// PLL relock).  clear_avmute_i clears it.
module gcp_packet_builder (
  input  logic avmute_i,        // assert to mute audio/video
  input  logic clear_avmute_i,  // assert to clear mute (takes precedence)

  output logic [7:0] hb_o [0:2],
  output logic [7:0] pb_o [0:27]
);

  always_comb begin
    hb_o = '{default: 8'h00};  // packet type 0x00 + 2 reserved bytes
    pb_o = '{default: 8'h00};

    // SB0 byte (PB0 in our formatter's convention = first byte of subpacket 0)
    // Bit 7: Set_AVMUTE, Bit 6: Clear_AVMUTE, bits [3:0]: CD (color depth)
    pb_o[0] = {avmute_i, clear_avmute_i, 2'b00, 4'b0000};
  end

endmodule

`endif
