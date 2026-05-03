/**
 * @file        packet_streamer.sv
 * @author      Gemini AI (Review & Refactoring)
 * @version     3.0
 * @date        17. august 2025
 *
 * @brief       Sekvenčný modul (FSM) pre serializáciu a multiplexovanie viacerých HDMI paketov.
 * @details     Tento modul slúži ako centrálny radič pre odosielanie metadátových paketov
 * počas vertikálnej zatemňovacej periódy (V-Blank). Je implementovaný ako
 * stavový automat (FSM), ktorý sa spúšťa signálom `eof_i` (End of Frame).
 *
 * Po spustení modul postupne odošle preddefinovanú sekvenciu paketov:
 * 1. General Control Packet (GCP)
 * 2. AVI InfoFrame
 * 3. SPD InfoFrame
 * 4. Audio InfoFrame
 *
 * Na vstupe očakáva vopred pripravené štruktúry paketov (hlavičky a telá)
 * z modulov ako `infoframe_builder`. Na výstupe produkuje jednoduchý dátový
 * prúd (`packet_o`) so signálmi platnosti (`packet_valid_o`) a konca
 * prenosu (`packet_last_o`).
 *
 * @param[in]   MAX_PAYLOAD     Maximálna veľkosť poľa pre payload (telo) paketu.
 *
 * @input       clk_i           Taktovací signál (pixel clock).
 * @input       rst_ni          Synchrónny reset, aktívny v nízkej úrovni.
 * @input       eof_i           Spúšťač prenosu sekvencie (End of Frame).
 * @input       header_...      Vstupné polia s hlavičkami InfoFrame paketov.
 * @input       payload_...     Vstupné polia s telami InfoFrame paketov.
 * @input       len_...         Dĺžky tiel jednotlivých InfoFrame paketov.
 *
 * @output      packet_o        Výstupný 8-bitový bajt dát.
 * @output      packet_valid_o  Indikátor platnosti `packet_o`. Aktívny počas prenosu.
 * @output      packet_last_o   Indikátor posledného bajtu v celej sekvencii.
 *
 * @example
 * // Inštancia modulu v top-level súbore, kde sú pripojené výstupy z infoframe_builderov.
 * packet_streamer #(
 * .MAX_PAYLOAD(32)
 * ) u_packet_streamer (
 * .clk_i(pixel_clk),
 * .rst_ni(rstn_sync),
 * .eof_i(eof),
 * .header_avi(header_avi_from_builder),
 * .payload_avi(payload_avi_from_builder),
 * .len_avi(len_avi_from_builder),
 * // ... pripojenie pre SPD a Audio pakety ...
 * .packet_o(packet_data_for_hdmi_tx),
 * .packet_valid_o(packet_valid_for_hdmi_tx),
 * .packet_last_o(packet_last_signal)
 * );
 */

`ifndef HDMI_PACKET_STREAMER_V3
`define HDMI_PACKET_STREAMER_V3

`default_nettype none

import hdmi_pkg::*;

module packet_streamer #(
  parameter int MAX_PAYLOAD = 32
)(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        eof_i, // Spúšťač na konci snímky

  // Vstupy z InfoFrame builderov
  input  logic [7:0] header_avi [0:2],
  input  logic [7:0] payload_avi[0:MAX_PAYLOAD-1],
  input  int         len_avi,

  input  logic [7:0] header_spd [0:2],
  input  logic [7:0] payload_spd[0:MAX_PAYLOAD-1],
  input  int         len_spd,

  input  logic [7:0] header_audio[0:2],
  input  logic [7:0] payload_audio[0:MAX_PAYLOAD-1],
  input  int         len_audio,

  // Výstupy pre HDMI TX modul
  output logic [7:0] packet_o,
  output logic       packet_valid_o,
  output logic       packet_last_o // VYLEPŠENIE: Indikátor konca sekvencie
);

  // Stavy FSM
  typedef enum logic [2:0] {
    IDLE,
    SEND_GCP,
    SEND_AVI_HEADER, SEND_AVI_PAYLOAD,
    SEND_SPD_HEADER, SEND_SPD_PAYLOAD,
    SEND_AUDIO_HEADER, SEND_AUDIO_PAYLOAD
  } mux_state_e;

  mux_state_e state, next_state;
  logic [4:0] byte_idx; // Univerzálny čítač bajtov v rámci jedného paketu

  // --- Konštanty pre GCP (General Control Packet) ---
  localparam logic [7:0] GcpHeader = 8'h03;
  localparam logic [7:0] GcpByte_0 = 8'h00; // Default: AVMUTE=off, Color Depth=not indicated

  // Sekvenčná časť
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state    <= IDLE;
      byte_idx <= '0;
    end else begin
      state <= next_state;
      if (next_state != state)
        byte_idx <= '0;
      else if (packet_valid_o)
        byte_idx <= byte_idx + 5'd1;
    end
  end

  // Kombinačná časť
  always_comb begin
    // Predvolené hodnoty pre výstupy
    next_state      = state;
    packet_valid_o  = 1'b0;
    packet_last_o   = 1'b0;
    packet_o        = '0;

    unique case (state)
      IDLE: begin
        // Čakáme na signál konca snímky (eof), aby sme začali posielať pakety vo V-Blank perióde
        if (eof_i) begin
          next_state = SEND_GCP;
        end
      end

      SEND_GCP: begin
        packet_valid_o = 1'b1;
        // Jednoduchý multiplexer pre 2 bajty GCP paketu
        packet_o = (byte_idx == 0) ? GcpHeader : GcpByte_0;
        // Po odoslaní druhého bajtu (index 1) prejdeme na ďalší paket
        if (byte_idx == 1) next_state = SEND_AVI_HEADER;
      end

      SEND_AVI_HEADER: begin
        packet_valid_o = 1'b1;
        packet_o       = header_avi[byte_idx];
        // Hlavička má 3 bajty (indexy 0, 1, 2). Po bajte s indexom 2 pokračujeme na telo.
        if (byte_idx == 2) next_state = SEND_AVI_PAYLOAD;
      end

      SEND_AVI_PAYLOAD: begin
        packet_valid_o = 1'b1;
        // Telo paketu indexujeme od 0, preto čítač `byte_idx` sedí priamo
        packet_o       = payload_avi[byte_idx];
        // Dĺžka tela je napr. 13 bajtov (indexy 0..12). Po bajte 12 prejdeme ďalej.
        if (byte_idx == len_avi - 1) next_state = SEND_SPD_HEADER;
      end

      SEND_SPD_HEADER: begin
        packet_valid_o = 1'b1;
        packet_o       = header_spd[byte_idx];
        if (byte_idx == 2) next_state = SEND_SPD_PAYLOAD;
      end

      SEND_SPD_PAYLOAD: begin
        packet_valid_o = 1'b1;
        packet_o       = payload_spd[byte_idx];
        if (byte_idx == len_spd - 1) next_state = SEND_AUDIO_HEADER;
      end

      SEND_AUDIO_HEADER: begin
        packet_valid_o = 1'b1;
        packet_o       = header_audio[byte_idx];
        if (byte_idx == 2) next_state = SEND_AUDIO_PAYLOAD;
      end

      SEND_AUDIO_PAYLOAD: begin
        packet_valid_o = 1'b1;
        packet_o       = payload_audio[byte_idx];
        // Toto je posledný paket v sekvencii
        if (byte_idx == len_audio - 1) begin
          packet_last_o = 1'b1; // Signalizujeme posledný bajt celej sekvencie
          next_state    = IDLE;   // Vrátime sa do čakania na ďalší snímok
        end
      end

      default: next_state = IDLE;

    endcase
  end

endmodule


`endif // HDMI_PACKET_MUX_V3
