`ifndef AUDIO_SAMPLE_PACKET_BUILDER_SV
`define AUDIO_SAMPLE_PACKET_BUILDER_SV

`default_nettype none

// HDMI Audio Sample Packet builder — combinational.
//
// Builds packet type 0x02 for 2-channel LPCM, 4 sample pairs per packet.
//
// Audio word layout (left-justified 16-bit in 24-bit AW):
//   AW[23:8] = sample[15:0], AW[7:0] = 8'h00
//   PB1 = AW[7:0]  = 8'h00
//   PB2 = AW[15:8] = sample[7:0]
//   PB3 = AW[23:16]= sample[15:8]
//
// Parity P = ^AW[23:0] with V=U=C=0 → P = ^sample[15:0].
// PB0 = {V1,U1,C1,P1, V0,U0,C0,P0} = {3'b000, ^R, 3'b000, ^L}.
module audio_sample_packet_builder (
  input  logic [15:0] l0_i, r0_i,   // sample pair 0
  input  logic [15:0] l1_i, r1_i,   // sample pair 1
  input  logic [15:0] l2_i, r2_i,   // sample pair 2
  input  logic [15:0] l3_i, r3_i,   // sample pair 3

  output logic [7:0]  hb_o [0:2],
  output logic [7:0]  pb_o [0:27]
);

  always_comb begin
    hb_o[0] = 8'h02;   // Audio Sample Packet type
    hb_o[1] = 8'h0F;   // B=0; SP3..SP0 all present (4'b1111)
    hb_o[2] = 8'h00;   // LAYOUT=0 (2-channel); flat bits = 0

    pb_o = '{default: 8'h00};

    // SP0
    pb_o[0]  = {3'b000, ^r0_i, 3'b000, ^l0_i};
    pb_o[1]  = 8'h00;       pb_o[2]  = l0_i[7:0];  pb_o[3]  = l0_i[15:8];
    pb_o[4]  = 8'h00;       pb_o[5]  = r0_i[7:0];  pb_o[6]  = r0_i[15:8];

    // SP1
    pb_o[7]  = {3'b000, ^r1_i, 3'b000, ^l1_i};
    pb_o[8]  = 8'h00;       pb_o[9]  = l1_i[7:0];  pb_o[10] = l1_i[15:8];
    pb_o[11] = 8'h00;       pb_o[12] = r1_i[7:0];  pb_o[13] = r1_i[15:8];

    // SP2
    pb_o[14] = {3'b000, ^r2_i, 3'b000, ^l2_i};
    pb_o[15] = 8'h00;       pb_o[16] = l2_i[7:0];  pb_o[17] = l2_i[15:8];
    pb_o[18] = 8'h00;       pb_o[19] = r2_i[7:0];  pb_o[20] = r2_i[15:8];

    // SP3
    pb_o[21] = {3'b000, ^r3_i, 3'b000, ^l3_i};
    pb_o[22] = 8'h00;       pb_o[23] = l3_i[7:0];  pb_o[24] = l3_i[15:8];
    pb_o[25] = 8'h00;       pb_o[26] = r3_i[7:0];  pb_o[27] = r3_i[15:8];
  end

endmodule
`endif // AUDIO_SAMPLE_PACKET_BUILDER_SV
