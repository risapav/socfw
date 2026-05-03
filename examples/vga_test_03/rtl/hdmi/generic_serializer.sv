/**
 * @brief Generický, parametrizovateľný N-kanálový serializátor so synchronizovaným CDC a voliteľným DDR/SDR režimom.
 * @details Tento modul prevádza N paralelných slov pevnej šírky na N sériových výstupov.
 * Implementuje dvojstupňový CDC mechanizmus (`shadow_reg` + `load_toggle`) pre robustný prenos dát
 * z pomalej hodinovej domény (clk_i) do rýchlej domény (clk_x_i).
 *
 * Podporuje:
 * - DDR režim (2 bity za cyklus, vyžaduje 5× clk_i).
 * - SDR režim (1 bit za cyklus, vyžaduje 10× clk_i).
 * - Obojstrannú serializáciu (LSB-first / MSB-first).
 * - Držanie posledného stavu pri `enable_i=0`.
 *
 * @param[in] DDRIO Prepínač režimu. 1 = DDR (2 bity/clk_x_i), 0 = SDR (1 bit/clk_x_i).
 * @param[in] NUM_PHY_CHANNELS Počet fyzických kanálov na serializáciu (napr. 4 pre HDMI).
 * @param[in] WORD_WIDTH Šírka serializovaného slova (napr. 10 pre TMDS).
 * @param[in] LSB_FIRST Poradie serializácie. 1 = LSB prvý, 0 = MSB prvý.
 * @param[in] IDLE_WORD Vzor, ktorý sa uloží po resete a drží sa pri neaktívnom `enable_i`.
 *
 * @input  rst_ni Asynchrónny, aktívne nízky reset.
 * @input  enable_i Povolenie činnosti. Pri 0 sa posúvanie zastaví a výstupy držia poslednú hodnotu.
 * @input  clk_i Pomalý takt (paralelná doména, napr. pixel clock).
 * @input  clk_x_i Rýchly takt (serializačná doména, 5× alebo 10× clk_i).
 * @input  word_i Pole paralelných vstupných slov (šírky WORD_WIDTH).
 * @output data_request_o Impulz v clk_i doméne, keď modul očakáva nové dáta.
 * @output phys_o Pole sériových výstupov (mapovaných na fyzické piny).
 *
 * @example
 * // Ukážka použitia v HDMI vysielači
 * generic_serializer #(
 *   .DDRIO(1),
 *   .NUM_PHY_CHANNELS(4),
 *   .WORD_WIDTH(10),
 *   .LSB_FIRST(1),
 *   .IDLE_WORD('0)
 * ) u_tmds_serializer (
 *   .rst_ni(rst_n),
 *   .enable_i(hdmi_enable),
 *   .clk_i(pixel_clk),
 *   .clk_x_i(pixel_clk_5x),
 *   .word_i(serializer_words),
 *   .data_request_o(serializer_data_request),
 *   .phys_o(hdmi_tmds_p)
 * );
 */

`ifndef GENERIC_SERIALIZER
`define GENERIC_SERIALIZER

`default_nettype none

module generic_serializer #(
    parameter bit DDRIO = 1,
    parameter int NUM_PHY_CHANNELS = 4,
    parameter int WORD_WIDTH = 10,
    parameter bit LSB_FIRST = 1,
    parameter logic [WORD_WIDTH-1:0] IDLE_WORD = '0
)(
    input  logic         rst_ni,
    input  logic         enable_i,
    input  logic         clk_i,
    input  logic         clk_x_i,
    input  logic [WORD_WIDTH-1:0] word_i [NUM_PHY_CHANNELS],
    output logic         data_request_o,
    output logic         phys_o [NUM_PHY_CHANNELS]
);

  // --- Logika v pomalej doméne (clk_i) ---
  // Uchováva shadow registre, aby boli dáta stabilné počas CDC
  // load_toggle sa preklopí vždy, keď sú dáta pripravené (data_request_o=1).
  logic [WORD_WIDTH-1:0] shadow_reg [NUM_PHY_CHANNELS];
  wire load_toggle;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      load_toggle    <= 1'b0;
      data_request_o <= 1'b0;
      for (int ch = 0; ch < NUM_PHY_CHANNELS; ch++)
        shadow_reg[ch] <= IDLE_WORD;
    end else begin
      // Defaultne je požiadavka neaktívna
      data_request_o <= 1'b0;
      if (enable_i) begin
        // 1. Vystavíme požiadavku na nové dáta.
        data_request_o <= 1'b1;
        // 2. Uložíme vstupné dáta do shadow registrov.
        for (int ch = 0; ch < NUM_PHY_CHANNELS; ch++)
          shadow_reg[ch] <= word_i[ch];
        // 3. Až keď sú dáta bezpečne uložené, preklopíme CDC signál.
        load_toggle <= ~load_toggle;
      end
    end
  end

  // --- Prekročenie hodinovej domény (CDC) ---
  // Dvojstupňový synchronizátor → eliminuje metastabilitu.
  // XOR detektor hrany (load_pulse) vytvorí 1-taktový impulz v rýchlej doméne.
  logic [1:0] load_sync;
  always_ff @(posedge clk_x_i) begin
    if (!rst_ni)
      load_sync <= 2'b00;
    else
      load_sync <= {load_sync[0], load_toggle};
  end
  wire load_pulse = load_sync[1] ^ load_sync[0];

  // --- Logika v rýchlej doméne (clk_x_i) ---
  // Priorita kombinačnej logiky:
  // 1. load_pulse → načítaj nové dáta
  // 2. enable_i → posúvaj posuvný register
  // 3. inak → drž posledný stav
  localparam int ShiftAmount = DDRIO ? 2 : 1;
  logic [WORD_WIDTH-1:0] shift_reg [NUM_PHY_CHANNELS];
  logic [WORD_WIDTH-1:0] shift_reg_next [NUM_PHY_CHANNELS];

  // Kombinačná logika pre výpočet ďalšieho stavu posuvných registrov
  always_comb begin
    for (int ch = 0; ch < NUM_PHY_CHANNELS; ch++) begin
      if (load_pulse) begin
        // Priorita č.1: Načítaj nové dáta zo shadow registrov
        shift_reg_next[ch] = shadow_reg[ch];
      end else if (enable_i) begin
        // Priorita č.2: Ak je modul povolený, posúvaj dáta
        if (LSB_FIRST)
            shift_reg_next[ch] = shift_reg[ch] >> ShiftAmount;
        else
            shift_reg_next[ch] = shift_reg[ch] << ShiftAmount;
      end else begin
        // Priorita č.3: Ak je modul zakázaný, drž poslednú hodnotu
        shift_reg_next[ch] = shift_reg[ch];
      end
    end
  end

  // Sekvenčná logika pre uloženie nového stavu
  always_ff @(posedge clk_x_i) begin
    if (!rst_ni) begin
      for (int ch = 0; ch < NUM_PHY_CHANNELS; ch++)
        shift_reg[ch] <= IDLE_WORD;
    end else begin
      shift_reg <= shift_reg_next;
    end
  end

  // --- Výstupné drivery ---
  // DDR vetva: mapuje 2 bity na posedge/negedge signály DDR primitiva.
  // SDR vetva: priamo vyvedie najvyšší/ najnižší bit podľa LSB_FIRST.
  //
  // POZNÁMKA: mapovanie datain_h/datain_l môže byť odlišné
  // podľa implementácie `ddio_out`. Je nutné si overiť na konkrétnej FPGA platforme.
  generate
    genvar k;
    if (DDRIO) begin : g_ddr_output_driver
      for (k = 0; k < NUM_PHY_CHANNELS; k++) begin : g_ddr_ch
        // Pre lepšiu čitateľnosť si definujeme bity pre každú hranu
        logic ddr_posedge_bit, ddr_negedge_bit;
        if (LSB_FIRST) begin : g_lsb_first_shifter
          assign ddr_posedge_bit = shift_reg[k][0];
          assign ddr_negedge_bit = shift_reg[k][1];
        end else begin : g_msb_first_shifter
          // Opravená logika: MSB ide prvý (na posedge), ďalší bit na negedge
          assign ddr_posedge_bit = shift_reg[k][WORD_WIDTH-1];
          assign ddr_negedge_bit = shift_reg[k][WORD_WIDTH-2];
        end

        // POZNÁMKA: Mapovanie `datain_h`/`datain_l` na posedge/negedge závisí
        // od implementácie vášho `ddio_out` wrapperu! Toto je len príklad.
        ddio_out ddr_phy (
          .datain_h (ddr_posedge_bit), // Dáta pre NÁBEŽNÚ hranu (posedge)
          .datain_l (ddr_negedge_bit), // Dáta pre ZOSTUPNÚ hranu (negedge)
          .outclock (clk_x_i),
          .dataout  (phys_o[k])
        );
      end
    end else begin : g_sdr_output_driver
      for (k = 0; k < NUM_PHY_CHANNELS; k++) begin : g_sdr_ch
        assign phys_o[k] = LSB_FIRST ? shift_reg[k][0] : shift_reg[k][WORD_WIDTH-1];
      end
    end
  endgenerate

endmodule

`endif // GENERIC_SERIALIZER
