`ifndef INFOFRAME_BUILDER_SV
`define INFOFRAME_BUILDER_SV

`default_nettype none

import hdmi_pkg::*;

// Combinational InfoFrame packet builder.
//
// Layout convention (matches CEA-861 / HDMI spec):
//   payload_o[0]         = PB0 = checksum
//   payload_o[1..N]      = PB1..PBN (actual InfoFrame data bytes)
//   payload_len_o        = N + 1   (checksum slot + N data bytes)
//
// This ensures calc_checksum(header, payload, payload_len) sums
// header[0..2] + payload[1..payload_len-1] = all data bytes.
module infoframe_builder #(
  parameter hdmi_pkg::infoframe_type_e IF_TYPE = INFO_AVI
)(
  // AVI InfoFrame inputs
  input  color_format_e color_format_i,
  input  aspect_ratio_e aspect_ratio_i,
  input  quant_range_e  quant_range_i,
  input  logic [7:0]    vic_code_i,

  // SPD InfoFrame inputs
  input  logic [63:0]  vendor_name_i,
  input  logic [127:0] product_desc_i,
  input  logic [7:0]   source_device_i,

  // Audio InfoFrame inputs
  input  logic [2:0]   audio_channels_i,  // CC[2:0]: channel count - 1

  // Outputs
  output logic [7:0]   header_o[3],
  output logic [7:0]   payload_o[32],  // [0]=checksum, [1..N]=PB1..PBN
  output int           payload_len_o   // = N + 1
);

  // Header LENGTH field = number of PB bytes (not counting PB0/checksum)
  localparam logic [7:0] AVI_VERSION   = 8'd2;
  localparam logic [7:0] AVI_LENGTH    = 8'd13;  // PB1..PB13
  localparam logic [7:0] SPD_VERSION   = 8'd1;
  localparam logic [7:0] SPD_LENGTH    = 8'd25;  // PB1..PB25
  localparam logic [7:0] AUDIO_VERSION = 8'd1;
  localparam logic [7:0] AUDIO_LENGTH  = 8'd10;  // PB1..PB10

  always_comb begin
    header_o      = '{default: '0};
    payload_o     = '{default: '0};
    payload_len_o = 0;

    unique case (IF_TYPE)

      INFO_AVI: begin
        header_o[0]   = INFO_AVI;
        header_o[1]   = AVI_VERSION;
        header_o[2]   = AVI_LENGTH;
        // payload_len = LENGTH + 1 (PB0 slot + PB1..PB13)
        payload_len_o = int'(AVI_LENGTH) + 1;

        // PB1
        payload_o[1][7]   = 1'b0;
        payload_o[1][6:5] = color_format_i;
        payload_o[1][4]   = 1'b1;   // Active Format Info Present
        payload_o[1][3:2] = 2'b00;  // No Bar Info
        payload_o[1][1:0] = 2'b00;  // No Scan Info

        // PB2
        payload_o[2][7:6] = 2'b00;          // No colorimetry
        payload_o[2][5:4] = aspect_ratio_i;  // M1:M0
        payload_o[2][3:0] = 4'b1000;         // R: same as picture AR

        // PB3
        payload_o[3][6:4] = 3'b000;          // EC: not specified
        payload_o[3][3:2] = quant_range_i;   // Q: quant range
        payload_o[3][1:0] = 2'b00;           // SC: no scaling

        // PB4: VIC
        payload_o[4] = vic_code_i;
        // PB5..PB13 remain 0
      end

      INFO_SPD: begin
        header_o[0]   = INFO_SPD;
        header_o[1]   = SPD_VERSION;
        header_o[2]   = SPD_LENGTH;
        payload_len_o = int'(SPD_LENGTH) + 1;

        for (int i = 0; i < 8; i++)
          payload_o[i + 1] = vendor_name_i[(i * 8) +: 8];
        for (int i = 0; i < 16; i++)
          payload_o[i + 9] = product_desc_i[(i * 8) +: 8];
        payload_o[25] = source_device_i;
      end

      INFO_AUDIO: begin
        header_o[0]   = INFO_AUDIO;
        header_o[1]   = AUDIO_VERSION;
        header_o[2]   = AUDIO_LENGTH;
        payload_len_o = int'(AUDIO_LENGTH) + 1;

        payload_o[1][2:0] = audio_channels_i;
        // Other bytes remain 0
      end

    endcase

    // Compute and insert checksum into PB0
    if (payload_len_o > 0)
      payload_o[0] = calc_checksum(header_o, payload_o, payload_len_o);
  end

endmodule

`endif
