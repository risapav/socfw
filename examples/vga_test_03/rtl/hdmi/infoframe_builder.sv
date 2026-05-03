/**
 * @brief       Kombinačný modul na stavbu štruktúry HDMI InfoFrame paketov.
 * @details     Tento modul generuje kompletnú štruktúru InfoFrame paketu (hlavičku a telo)
 * na základe parametra IF_TYPE a príslušných vstupov. Podporuje typy
 * AVI, SPD a Audio. Výstupom sú polia bajtov pre hlavičku a telo,
 * dĺžka tela a vypočítaný kontrolný súčet (checksum) na pozícii payload_o[0].
 * Modul je čisto kombinačný a pripravený na pripojenie k serializačnej jednotke.
 *
 * @param[in]   IF_TYPE         Typ InfoFrame-u na vygenerovanie (z hdmi_pkg::infoframe_type_e).
 * @param[in]   HEADER_MAX      Veľkosť poľa pre hlavičku (štandardne 3).
 * @param[in]   PAYLOAD_MAX     Maximálna veľkosť poľa pre telo paketu (štandardne 32).
 *
 * @input       color_format_i  Farebný formát pre AVI (RGB/YUV).
 * @input       aspect_ratio_i  Pomer strán pre AVI (4:3 / 16:9).
 * @input       quant_range_i   Dynamický rozsah pre AVI (Full/Limited).
 * @input       vic_code_i      Video Identification Code pre AVI.
 * @input       vendor_name_i   Meno výrobcu pre SPD (8 znakov ASCII).
 * @input       product_desc_i  Popis produktu pre SPD (16 znakov ASCII).
 * @input       source_device_i Typ zdrojového zariadenia pre SPD.
 * @input       audio_channels_i Počet audio kanálov - 1 (napr. 1 pre 2 kanály).
 *
 * @output      header_o        Pole 3 bajtov hlavičky (Typ, Verzia, Dĺžka).
 * @output      payload_o       Pole bajtov tela paketu (payload_o[0] je checksum).
 * @output      payload_len_o   Skutočná dĺžka tela paketu v bajtoch.
 *
 * @example
 * // Inštancia pre generovanie AVI InfoFrame pre 800x600@60Hz, 4:3, RGB Full Range
 * infoframe_builder #(
 * .IF_TYPE(hdmi_pkg::INFO_AVI)
 * ) avi_builder_inst (
 * .color_format_i(hdmi_pkg::COLOR_FORMAT_RGB),
 * .aspect_ratio_i(hdmi_pkg::ASPECT_RATIO_4_3),
 * .quant_range_i(hdmi_pkg::QUANT_RANGE_FULL),
 * .vic_code_i(8'd25),
 * // Ostatné vstupy môžu byť nepripojené (pre syntézu sa optimalizujú preč)
 * .header_o(avi_header),
 * .payload_o(avi_payload),
 * .payload_len_o(avi_payload_len)
 * );
 */

`ifndef INFOFRAME_BUILDER
`define INFOFRAME_BUILDER

`default_nettype none
import hdmi_pkg::*;

module infoframe_builder #(
  parameter hdmi_pkg::infoframe_type_e IF_TYPE = INFO_AVI,
  parameter int HEADER_MAX = 3,
  parameter int PAYLOAD_MAX = 32  // maximálna veľkosť payloadu
)(
   // --- Vstupy pre AVI InfoFrame ---
    input  color_format_e color_format_i,
    input  aspect_ratio_e aspect_ratio_i,
    input  quant_range_e  quant_range_i,
    input  logic [7:0]    vic_code_i,

    // --- Vstupy pre SPD InfoFrame ---
    input  logic [63:0]   vendor_name_i,
    input  logic [127:0]  product_desc_i,
    input  logic [7:0]    source_device_i,

    // --- Vstupy pre Audio InfoFrame ---
    input  logic [2:0]    audio_channels_i, // Počet kanálov - 1 (0=2ch, 7=8ch)

    // --- Výstupy ---
    output logic [7:0]    header_o[HEADER_MAX],
    output logic [7:0]    payload_o[PAYLOAD_MAX], // Max. veľkosť payloadu je 31, 0 je pre checksum
    output int            payload_len_o
);

  // --- Konštanty pre lepšiu čitateľnosť ---
  localparam logic [7:0] AviVERSION   = 8'd2;
  localparam logic [7:0] AviLENGTH    = 8'd13;
  localparam logic [7:0] SpdVERSION   = 8'd1;
  localparam logic [7:0] SpdLENGTH    = 8'd25;
  localparam logic [7:0] AudioVERSION = 8'd1;
  localparam logic [7:0] AudioLENGTH  = 8'd10;

  // --- Kombinačná logika pre stavbu paketu ---
  always_comb begin
    // --- Predvolené hodnoty ---
    header_o      = '{default:'0};
    payload_o     = '{default:'0};
    payload_len_o = 0;

    // --- Stavba paketu podľa typu ---
    unique case (IF_TYPE)
      INFO_AVI: begin
        header_o[0]   = INFO_AVI;   // Typ z pkg
        header_o[1]   = AviVERSION; // Verzia 2
        header_o[2]   = AviLENGTH;  // Dĺžka 13 bajtov
        payload_len_o = AviLENGTH;

        // --- Telo paketu (payload) - konštrukcia po bitoch pre maximálnu čitateľnosť ---
        // PB1: Y1,Y0 (Color format) | A0 (Active Format) | B1,B0 (Bar Info) | S1,S0 (Scan Info)
        payload_o[1][7]   = 1'b0;                // Reserved
        payload_o[1][6:5] = color_format_i;      // Y1,Y0: Color format (RGB/YUV)
        payload_o[1][4]   = 1'b1;                // A0: Active Format Info Present
        payload_o[1][3:2] = 2'b00;               // B1,B0: No Bar Info
        payload_o[1][1:0] = 2'b00;               // S1,S0: No Scan Info

        // PB2: C1,C0 (Colorimetry) | M1,M0 (Aspect Ratio) | R3..R0 (Active Format AR)
        payload_o[2][7:6] = 2'b00;               // C1,C0: No colorimetry data
        payload_o[2][5:4] = aspect_ratio_i;      // M1,M0: Picture Aspect Ratio (4:3/16:9)
        payload_o[2][3:0] = 4'b1000;             // R: Same as Picture AR

        // PB3: EC (Extended Colorimetry) | Q (Quantization Range) | SC (Scaling)
        payload_o[3][6:4] = 3'b000;              // EC: Not specified
        payload_o[3][3:2] = quant_range_i;       // Q: Quantization Range (Full/Limited)
        payload_o[3][1:0] = 2'b00;               // SC: No scaling

        // PB4: Video Identification Code
        payload_o[4] = vic_code_i;
        // Ostatné bajty PB5-PB13 sú už vynulované predvolenou hodnotou.
      end

      INFO_SPD: begin
        header_o[0]   = INFO_SPD;   // Typ z pkg
        header_o[1]   = SpdVERSION; // Verzia 1
        header_o[2]   = SpdLENGTH;  // Dĺžka 25 bajtov
        payload_len_o = SpdLENGTH;

        // Meno výrobcu (8 bajtov)
        for (int i = 0; i < 8; i++)
          payload_o[i+1] = vendor_name_i[ (i*8) +: 8 ];

        // Popis produktu (16 bajtov)
        for (int i = 0; i < 16; i++)
          payload_o[i+9] = product_desc_i[ (i*8) +: 8 ];

        payload_o[25] = source_device_i;
      end

      INFO_AUDIO: begin
        header_o[0] = INFO_AUDIO;
        header_o[1] = AudioVERSION;
        header_o[2] = AudioLENGTH; // payload 10 bajtov (len príklad)
        payload_len_o = AudioLENGTH;

        // PB1: CC (Channel Count)
        payload_o[1][2:0] = audio_channels_i;
        // Ostatné bajty sú už vynulované.
      end

      // `default` vetva nie je potrebná vďaka inicializácii na začiatku.

    endcase

    // --- Finálny výpočet checksumu ---
    // Vkladá sa do payload_o[0] až na záver, po naplnení celého tela.
    if (payload_len_o > 0) begin
        payload_o[0] = calc_checksum(header_o, payload_o, payload_len_o);
    end
  end

endmodule

`endif

