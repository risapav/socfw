/**
 * @file        tmds_encoder_pipelined.sv
 * @brief       TMDS enkodér pre HDMI s 3-stupňovou pipeline a DC-balancom.
 * @details
 * Tento modul implementuje enkódovanie TMDS podľa špecifikácie DVI/HDMI.
 * Vstupom je 8-bitový pixelový dátový kanál a riadiace bity (HSYNC, VSYNC),
 * výstupom je 10-bitové TMDS kódové slovo. Modul udržuje bežiacu disparitu
 * (running disparity) pre zabezpečenie DC-balansu. Je rozdelený do troch
 * pipeline stupňov:
 *   - **S1**: Minimalizácia prechodov (8b -> 9b) + predvýpočet počtu jednotiek
 *   - **S2**: Registrovanie medzivýsledkov (ones_in_qm8 sa prenáša pipelineom)
 *   - **S3**: DC-balanovanie a výber výsledného 10b kódu
 *
 * Modul podporuje režimy:
 *   - VIDEO_PERIOD (štandardné TMDS enkódovanie pixelov)
 *   - CONTROL_PERIOD (špeciálne riadiace symboly C0, C1)
 *   - AUDIO_PERIOD a DATA_PERIOD (guard bands podľa HDMI špecifikácie)
 *
 * Latencia modulu je fixne 3 taktovacie cykly.
 *
 * @param[in]   clk_i        Taktovací signál (pixel clock)
 * @param[in]   rst_ni       Synchrónny reset, aktívny v nízkej úrovni
 * @param[in]   data_i       8-bitové video dáta (tmds_data_t)
 * @param[in]   data_type_i  Typ periódy (VIDEO, CONTROL, AUDIO, DATA)
 * @param[in]   c0_i         Control bit 0 (napr. HSYNC)
 * @param[in]   c1_i         Control bit 1 (napr. VSYNC)
 *
 * @param[out]  tmds_o       Výsledné 10-bitové TMDS kódové slovo
 *
 * @input       clk_i        Hlavný hodinový signál
 * @input       rst_ni       Reset vstup (aktívny v 0)
 * @input       data_i       Video dáta (RGB kanál)
 * @input       data_type_i  Určuje režim enkódovania
 * @input       c0_i, c1_i   HDMI control signály
 *
 * @output      tmds_o       Enkódovaný TMDS výstup
 *
 * @example
 * // Príklad inštancie enkodéra pre jeden TMDS kanál
 * tmds_encoder_pipelined encoder_inst (
 *    .clk_i       (clk_pixel),
 *    .rst_ni      (rst_n),
 *    .data_i      (pixel_r),
 *    .data_type_i (VIDEO_PERIOD),
 *    .c0_i        (hsync),
 *    .c1_i        (vsync),
 *    .tmds_o      (tmds_red)
 * );
 */


`ifndef TMDS_ENCODER_PIPELINED_V5
`define TMDS_ENCODER_PIPELINED_V5

`default_nettype none

import hdmi_pkg::*; // Centrálne definície typov, enumov a aliasov

module tmds_encoder_pipelined (
  // --- Vstupy ---
  input  logic         clk_i,         // Taktovací signál (pixel clock)
  input  logic         rst_ni,        // Synchrónny reset, aktívny v nízkej úrovni

  // Používame typy z balíčka hdmi_pkg
  input  tmds_data_t   data_i,        // 8-bitové vstupné dáta
  input  tmds_period_e data_type_i,   // Typ aktuálnej TMDS periódy

  input  logic         c0_i,          // Control bit 0 (napr. HSYNC)
  input  logic         c1_i,          // Control bit 1 (napr. VSYNC)

  // --- Výstup ---
  output tmds_word_t   tmds_o         // Výsledný 10-bitový TMDS kód
);

  // =================================================================
  // Konštanty a Funkcie
  // =================================================================

  // Riadiace symboly pre CONTROL_PERIOD
  localparam tmds_word_t TmdsCtrl_00 = 10'b1101010100;
  localparam tmds_word_t TmdsCtrl_01 = 10'b0010101011;
  localparam tmds_word_t TmdsCtrl_10 = 10'b0101010100;
  localparam tmds_word_t TmdsCtrl_11 = 10'b1010101011;

  // Guard band symboly pre HDMI (AUDIO/DATA period)
  localparam tmds_word_t TmdsGuard_Audio = 10'b1011001100; // Disparita = -2
  localparam tmds_word_t TmdsGuard_Data  = 10'b0100110011; // Disparita = +2

  // Syntetizovateľná funkcia pre sčítanie '1' v 8-bitovom slove
  function automatic logic [3:0] count_set_bits_8bit(input tmds_data_t data);
    logic [3:0] cnt = '0;
    for (int i = 0; i < 8; i = i + 1) begin
      cnt = cnt + data[i];
    end
    return cnt;
  endfunction

  // Syntetizovateľná funkcia pre sčítanie '1' v 10-bitovom slove
  function automatic logic [4:0] count_set_bits_10bit(input tmds_word_t data);
    logic [4:0] cnt = '0;
    for (int i = 0; i < 10; i = i + 1) begin
      cnt = cnt + data[i];
    end
    return cnt;
  endfunction

  // =================================================================
  // Pipeline registre a prechodné signály
  // =================================================================

  logic signed [4:0] running_disparity; // Bežiaca disparita

  // S1 → S2
  logic [8:0]      q_m_s1;              // 9-bitový prechodovo minimalizovaný kód
  logic [3:0]      ones_in_qm8_s1;      // Počet jednotiek v q_m[7:0]
  tmds_period_e    data_type_s1;        // Prenos typu periódy
  logic [1:0]      ctrl_s1;             // Prenos control bitov

  // S2 → S3
  logic [8:0]      q_m_s2;
  logic [3:0]      ones_in_qm8_s2;
  tmds_period_e    data_type_s2;
  logic [1:0]      ctrl_s2;

  // Výstupné hodnoty zo S3
  tmds_word_t      next_code;           // Ďalšie TMDS slovo
  logic signed [4:0] next_disparity;    // Nová hodnota disparity

  // =================================================================
  // STUPEŇ 1: Minimalizácia prechodov (8b -> 9b)
  // =================================================================
  // Tu sa rozhoduje, či sa použije XOR alebo XNOR kódovanie, aby sa
  // minimalizoval počet prechodov v signáli.
  // Navyše sa predpočíta počet jednotiek v q_m, ktorý sa prenáša pipelineom.
  always_comb begin
    tmds_data_t q_m_temp;
    logic use_xnor;
    logic [3:0] ones_in_data;

    ones_in_data = count_set_bits_8bit(data_i);

    // Pravidlo z DVI/HDMI špecifikácie pre výber XOR vs XNOR
    use_xnor = (ones_in_data > 4) || (ones_in_data == 4 && data_i[0] == 1'b0);

    // Vytvorenie q_m[7:0] sekvenčným XOR/XNOR
    q_m_temp[0] = data_i[0];
    for (int i = 1; i < 8; i++) begin
      q_m_temp[i] = use_xnor ? ~(q_m_temp[i-1] ^ data_i[i])
                             : ( q_m_temp[i-1] ^ data_i[i] );
    end

    q_m_s1 = {use_xnor, q_m_temp};        // q_m = {flag, 8b}
    ones_in_qm8_s1 = count_set_bits_8bit(q_m_s1[7:0]);
    data_type_s1   = data_type_i;
    ctrl_s1        = {c1_i, c0_i};
  end

  // Registrovanie výsledkov do S2
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      q_m_s2         <= '0;
      ones_in_qm8_s2 <= '0;
      data_type_s2   <= VIDEO_PERIOD;
      ctrl_s2        <= '0;
    end else begin
      q_m_s2         <= q_m_s1;
      ones_in_qm8_s2 <= ones_in_qm8_s1;
      data_type_s2   <= data_type_s1;
      ctrl_s2        <= ctrl_s1;
    end
  end

  // =================================================================
  // STUPEŇ 2: Pipeline registračný stupeň
  // =================================================================
  // Slúži len na vyrovnanie latencie medzi výpočtami.
  // Všetky kombin. výpočty boli optimalizáciou presunuté.


  // =================================================================
  // STUPEŇ 3: DC-balansovanie (9b -> 10b) + výber režimu
  // =================================================================
  // V tomto kroku sa rozhoduje:
  //  - Aký typ periódy enkódujeme (VIDEO, CONTROL, AUDIO, DATA).
  //  - Pri VIDEO_PERIOD sa zabezpečí DC-balans:
  //      → Ak má kód q_m viac jednotiek ako núl (alebo naopak),
  //        rozhoduje sa podľa running_disparity.
  //      → Výsledok môže byť q_m doplnené o MSB=0/1,
  //        alebo invertovaná verzia q_m.
  //  - running_disparity sa aktualizuje podľa výsledného 10b kódu.
  //
  // Poznámka: Rozdiel ones vs zeros v q_m určuje, aký posun disparity
  // by kód spôsobil, ak by sa priamo použil. Preto sa v niektorých
  // prípadoch použije invertovaná verzia, aby sa udržala vyváženosť.
  // =================================================================


  // --- Pomocné signály pre S3 pre lepšiu čitateľnosť a syntézu ---
  logic signed [4:0]   char_disparity_s2; // Disparita 8-bitového slova (-4 až +4)
  logic                qm_is_neutral_s2;
  logic                invert_decision;
  logic signed [4:0]   video_next_disparity;
  tmds_word_t          video_next_code;


  // Kombinačná logika pre výpočet vlastností video slova
  always_comb begin
    // OPTIMALIZÁCIA: `ones_in_qm8_s2` už prichádza z registra, nemusíme ju počítať.
    // Disparita slova = (počet 1) - (počet 0) = ones - (8 - ones) = 2*ones - 8
    char_disparity_s2 = $signed({1'b0, ones_in_qm8_s2}) * 5'd2 - 5'd8;
    qm_is_neutral_s2 = (char_disparity_s2 == 0);
  end


  // Kombinačná logika pre rozhodnutie o inverzii (podľa DVI 1.0 spec)
  always_comb begin
    invert_decision = 1'b0; // Predvolená hodnota

    if (qm_is_neutral_s2) begin
      // Ak je RD nulová a slovo je neutrálne, preferujeme pridať nuly.
      // Invertujeme, iba ak 9. bit (use_xnor) je 1.
      invert_decision = q_m_s2[8];
    end else if (running_disparity == 0) begin
      // Ak je RD nulová a slovo nie je neutrálne, invertujeme, ak má kladnú disparitu.
      invert_decision = (char_disparity_s2 > 0);
    end else if ((running_disparity > 0 && char_disparity_s2 > 0) ||
                 (running_disparity < 0 && char_disparity_s2 < 0)) begin
      // Ak majú RD a disparita slova rovnaké znamienko, musíme invertovať.
      invert_decision = 1'b1;
    end else begin
      // Ak majú RD a disparita slova opačné znamienko, neinvertujeme.
      invert_decision = 1'b0;
    end
  end


  // Kombinačná logika pre generovanie finálneho kódu a disparity pre VIDEO_PERIOD
  always_comb begin
    logic [8:0] qm_balanced;
    logic [4:0] ones_in_final_code;
    logic signed [4:0] disparity_change;

    if (invert_decision) begin
      // Invertujeme 8 LSB bitov, 9. bit zostáva, 10. bit je '1'
      qm_balanced = {q_m_s2[8], ~q_m_s2[7:0]};
      video_next_code = {1'b1, qm_balanced};
    end else begin
      // Ponecháme 9 bitov, 10. bit je '0'
      qm_balanced = q_m_s2;
      video_next_code = {1'b0, qm_balanced};
    end

    // OPRAVA: Použijeme správnu, syntetizovateľnú funkciu na sčítanie bitov.
    ones_in_final_code = count_set_bits_10bit(video_next_code);
    disparity_change = $signed(ones_in_final_code) * 5'd2 - 5'd10;
    video_next_disparity = running_disparity + disparity_change;
  end


  // Finálny multiplexor pre výber výstupu a novej disparity
  always_comb begin
    next_code      = '0;
    next_disparity = running_disparity;

    unique case (data_type_s2)

      // --------------------------------------------------------------
      // 1) VIDEO_PERIOD → normálne TMDS enkódovanie pixelov
      // --------------------------------------------------------------
      VIDEO_PERIOD: begin
        next_code      = video_next_code;
        next_disparity = video_next_disparity;
      end

      // --------------------------------------------------------------
      // 2) CONTROL_PERIOD → špeciálne riadiace symboly
      // --------------------------------------------------------------
      CONTROL_PERIOD: begin
        unique case (ctrl_s2)
          2'b00: next_code = TmdsCtrl_00;
          2'b01: next_code = TmdsCtrl_01;
          2'b10: next_code = TmdsCtrl_10;
          2'b11: next_code = TmdsCtrl_11;
        endcase
        next_disparity = 5'sd0; // reset RD
      end

      // --------------------------------------------------------------
      // 3) AUDIO_PERIOD → Guard band pre audio
      // --------------------------------------------------------------
      AUDIO_PERIOD: begin
        next_code      = TmdsGuard_Audio;
        next_disparity = running_disparity - 5'd2; // delta -2
      end

      // --------------------------------------------------------------
      // 4) DATA_PERIOD → Guard band pre dátové bloky
      // --------------------------------------------------------------
      DATA_PERIOD: begin
        next_code      = TmdsGuard_Data;
        next_disparity = running_disparity + 5'd2; // delta +2
      end

    endcase
  end

  // Sekvenčná logika S3 (finálne registre)
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tmds_o            <= '0;
      running_disparity <= 5'sd0;
    end else begin
      tmds_o            <= next_code;
      running_disparity <= next_disparity;
    end
  end

endmodule

`endif // TMDS_ENCODER_PIPELINED_V5