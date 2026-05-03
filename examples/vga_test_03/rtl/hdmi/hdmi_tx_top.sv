/**
 * @file        hdmi_tx_top.sv
 * @brief       Hlavný modul digitálneho HDMI vysielača.
 * @details     Tento modul predstavuje kompletný digitálny frontend pre HDMI vysielač.
 * Jeho úlohou je zobrať paralelné video, audio a paketové dáta a pretransformovať
 * ich na 4-bitový sériový TMDS stream pripravený na odoslanie na fyzické piny FPGA.
 *
 * Funkčný tok:
 * 1. Interný stavový automat (FSM) neustále monitoruje vstupné signály platnosti
 * (`video_valid_i`, `audio_valid_i`, `packet_valid_i`) a určuje aktuálnu
 * TMDS periódu (Video, Control, Audio alebo Data).
 * 2. Na základe stavu FSM smeruje príslušné dáta (RGB pixely, audio/packet bajty
 * alebo riadiace signály HSYNC/VSYNC) do troch paralelných TMDS enkodérov.
 * 3. Každý enkodér konvertuje 8-bitové dáta na 10-bitové DC-balansované TMDS slovo.
 * 4. Štvrtý kanál pre TMDS hodiny je generovaný ako statický 10-bitový vzor.
 * 5. Všetky štyri 10-bitové kanály sú poslané do `generic_serializer`-a, ktorý ich
 * prevedie na výsledný 4-bitový vysokorýchlostný sériový výstup.
 *
 * @param[in]   DDRIO           Prepínač režimu serializéra. 1 = DDR (vyžaduje 5x clk), 0 = SDR (vyžaduje 10x clk).
 *
 * @input  clk_i            Pomalý takt (paralelná doména, napr. pixel clock).
 * @input  clk_x_i          Rýchly takt (serializačná doména, 5× alebo 10× clk_i).
 * @input  rst_ni           Synchrónny reset, aktívny v nízkej úrovni.
 * @input  hsync_i, vsync_i Synchronizačné signály z video generátora.
 * @input  video_i          24-bitové video dáta (RGB888).
 * @input  video_valid_i    Signál platnosti video dát (Data Enable).
 * @input  audio_i          8-bitové audio dáta (pre Audio Data Islands).
 * @input  audio_valid_i    Signál platnosti audio dát.
 * @input  packet_i         8-bitové paketové dáta (pre InfoFrames).
 * @input  packet_valid_i   Signál platnosti paketových dát.
 *
 * @output      hdmi_p_o        Výsledný 4-bitový sériový stream (kladná časť diff. párov).
 * - hdmi_p_o[0]: Modrý kanál (TMDS Channel 2)
 * - hdmi_p_o[1]: Zelený kanál (TMDS Channel 1)
 * - hdmi_p_o[2]: Červený kanál (TMDS Channel 0)
 * - hdmi_p_o[3]: Hodinový kanál (TMDS Clock)
 *
 * @example
 * hdmi_tx_top #(
 * .DDRIO(1)
 * ) u_hdmi_tx (
 * .clk_i(pixel_clock),
 * .clk_x_i(pixel_clock_5x),
 * .rst_ni(reset_n),
 * // ... pripojenie ostatných signálov ...
 * .hdmi_p_o(hdmi_pins_p)
 * );
 */

`ifndef HDMI_TX_TOP
`define HDMI_TX_TOP

`default_nettype none
import hdmi_pkg::*;

module hdmi_tx_top #(
    parameter bit DDRIO = 1
  )(
  // --- Vstupy ---
  input  logic      clk_i,
  input  logic      clk_x_i,
  input  logic      rst_ni,
  input  logic      hsync_i,
  input  logic      vsync_i,
  input  rgb888_t   video_i,
  input  logic      video_valid_i,
  input  tmds_data_t audio_i,
  input  logic      audio_valid_i,
  input  tmds_data_t packet_i,
  input  logic      packet_valid_i,

  // --- Výstup ---
  output logic [3:0] hdmi_p_o
);

  localparam unsigned TmdsClkPattern = 10'b1111100000;

  // Interné signály
  tmds_period_e period_type, period_type_next;
  tmds_data_t   encoder_data_red, encoder_data_grn, encoder_data_blu;
  tmds_word_t   tmds_word_blu, tmds_word_grn, tmds_word_red;

  // Adaptérové polia pre korektné prepojenie so serializérom
  tmds_word_t serializer_words  [4]; // Nepakované pole pre vstup
  logic       serializer_phys   [4]; // Nepakované pole pre výstup

   // =================================================================
  // 2. FSM A LOGIKA PRE RIADENIE PERIÓD Moore
  // =================================================================
  // Stavový register
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      period_type <= CONTROL_PERIOD;
    end else begin
      period_type <= period_type_next;
    end
  end

  // Kombinačná logika FSM: určuje ďalší stav na základe vstupov
  always_comb begin
    period_type_next = period_type; // Predvolene zostávame v aktuálnom stave

    unique case (period_type)
      CONTROL_PERIOD: begin
        // Ak sme v Control perióde (H-blank/V-blank), priorita je začať posielať dáta
        if      (video_valid_i)  period_type_next = VIDEO_PERIOD;
        else if (audio_valid_i)  period_type_next = AUDIO_PERIOD;
        else if (packet_valid_i) period_type_next = DATA_PERIOD;
      end

      VIDEO_PERIOD: begin
        // Ak skončia platné video dáta, vrátime sa do Control periódy
        if (!video_valid_i) begin
          period_type_next = CONTROL_PERIOD;
        end
      end

      AUDIO_PERIOD: begin
        // Ak skončia platné audio dáta, vrátime sa do Control periódy
        if (!audio_valid_i) begin
          period_type_next = CONTROL_PERIOD;
        end
      end

      DATA_PERIOD: begin
        // Ak skončia platné paketové dáta, vrátime sa do Control periódy
        if (!packet_valid_i) begin
          period_type_next = CONTROL_PERIOD;
        end
      end
    endcase
  end

  // Výstupná logika FSM: smeruje správne dáta do enkodérov na základe stavu
  always_comb begin
    // Predvolené hodnoty
    encoder_data_blu = '0;
    encoder_data_grn = '0;
    encoder_data_red = '0;

    unique case (period_type)
      VIDEO_PERIOD: begin
        // Počas Video periódy posielame RGB dáta do príslušných enkodérov
        encoder_data_blu = video_i.blu;
        encoder_data_grn = video_i.grn;
        encoder_data_red = video_i.red;
      end

      AUDIO_PERIOD: begin
        // Audio dáta sa podľa špecifikácie posielajú cez modrý kanál (Channel 2)
        encoder_data_blu = audio_i;
      end

      DATA_PERIOD: begin
        // Paketové dáta (InfoFrames) sa tiež posielajú cez modrý kanál
        encoder_data_blu = packet_i;
      end

      // V CONTROL_PERIOD zostávajú dáta nulové, enkodér použije HSYNC/VSYNC
      default: ;
    endcase
  end

  // =================================================================
  // 2. INŠTANCIE DÁTOVÝCH KANÁLOV (Blue, Green, Red)
  // =================================================================

  // --- KANÁL 0: MODRÁ (Blue) ---
  tmds_encoder_pipelined blue_encoder (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .data_i(encoder_data_blu),
    .data_type_i(period_type),
    .c0_i(hsync_i),
    .c1_i(vsync_i),
    .tmds_o(tmds_word_blu)
    );
  // --- KANÁL 1: ZELENÁ (Green) ---
  tmds_encoder_pipelined green_encoder (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .data_i(encoder_data_grn),
    .data_type_i(period_type),
    .c0_i(1'b0),
    .c1_i(1'b0),
    .tmds_o(tmds_word_grn)
    );
  // --- KANÁL 2: ČERVENÁ (Red) ---
  tmds_encoder_pipelined red_encoder (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .data_i(encoder_data_red),
    .data_type_i(period_type),
    .c0_i(1'b0),
    .c1_i(1'b0),
    .tmds_o(tmds_word_red)
    );

  // =================================================================
  // Príprava dát pre serializér a jeho inštancia
  // =================================================================

  // Priradenie výstupov z enkodérov a hodinového vzoru do poľa pre serializér
  assign serializer_words[0] = tmds_word_blu;  // Pripája sa na finálny výstup hdmi_p_o[0]
  assign serializer_words[1] = tmds_word_grn;  // Pripája sa na finálny výstup hdmi_p_o[1]
  assign serializer_words[2] = tmds_word_red;  // Pripája sa na finálny výstup hdmi_p_o[2]
  assign serializer_words[3] = TmdsClkPattern; // Pripája sa na finálny výstup hdmi_p_o[3]

  // --- Spoločný serializér pre všetky 4 kanály ---
  generic_serializer #(
    .DDRIO(DDRIO),
    .NUM_PHY_CHANNELS(4),
    .WORD_WIDTH(10),
    .LSB_FIRST(1),
    .IDLE_WORD('0)
  ) u_tmds_serializer (
    .rst_ni         (rst_ni),
    .enable_i       (1'b1),
    .clk_i          (clk_i),
    .clk_x_i        (clk_x_i),
    .word_i         (serializer_words), // Použijeme vstupný adaptér
    .data_request_o (),
    .phys_o         (serializer_phys)   // Použijeme výstupný adaptér
  );

  // ZMENA 3: Prepojenie VÝSTUPNÉHO nepakovaného poľa na finálny pakovaný port
  assign hdmi_p_o[0] = serializer_phys [0];
  assign hdmi_p_o[1] = serializer_phys [1];
  assign hdmi_p_o[2] = serializer_phys [2];
  assign hdmi_p_o[3] = serializer_phys [3];

endmodule

`endif // HDMI_TX_TOP
