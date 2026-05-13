/**
 * @brief       Modul pre multiplexovanie 7-segmentového displeja.
 * @details     Tento modul umožňuje zobrazovanie viacerých číslic na jednom 7-segmentovom displeji pomocou multiplexovania.
 *              Vstupné číslice a bodky sú postupne zobrazované v pravidelnom časovom intervale s frekvenciou `DIGIT_REFRESH_HZ`.
 *              Modul obsahuje interný segmentový dekóder a podporuje displeje so spoločnou anódou alebo katódou.
 *
 * @param[in]   CLOCK_FREQ_HZ      Frekvencia hodinového signálu (Hz). Predvolené: 50_000_000.
 * @param[in]   NUM_DIGITS         Počet číslic na displeji. Predvolené: 3.
 * @param[in]   DIGIT_REFRESH_HZ   Frekvencia prepínania medzi číslicami (Hz). Predvolené: 250.
 * @param[in]   COMMON_ANODE       Typ displeja: 1 = spoločná anóda (CA), 0 = spoločná katóda (CK).
 *
 * @input       clk_i              Vstupný hodinový signál.
 * @input       rst_ni             Synchronný reset, aktívny v L.
 * @input       digits_i           Pole číslic (0–F) pre každý digit.
 * @input       dots_i             Pole logických hodnôt pre desatinné bodky.
 *
 * @output      digit_sel_o        Výber aktuálne zobrazovanej číslice (one-hot).
 * @output      segment_sel_o      Výstupné segmenty: DP,G,F,E,D,C,B,A.
 * @output      current_digit_o    Index práve zobrazovanej číslice.
 *
 * @example
 * seven_seg_mux #(
 *   .CLOCK_FREQ_HZ(50_000_000),
 *   .NUM_DIGITS(4),
 *   .DIGIT_REFRESH_HZ(500),
 *   .COMMON_ANODE(1)
 * ) u_display (
 *   .clk_i(clk),
 *   .rst_ni(rst_n),
 *   .digits_i({digit3, digit2, digit1, digit0}),
 *   .dots_i({dot3, dot2, dot1, dot0}),
 *   .digit_sel_o(digit_sel),
 *   .segment_sel_o(segment_sel),
 *   .current_digit_o(active_digit)
 * );
 */


`ifndef SEVEN_SEG_SV
`define SEVEN_SEG_SV

`default_nettype none

module seven_seg_mux #(
  parameter int CLOCK_FREQ_HZ    = 50_000_000,   // frekvencia hodinového signálu
  parameter int NUM_DIGITS       = 3,            // počet číslic displeja
  parameter int DIGIT_REFRESH_HZ = 250,          // multiplex. frekvencia každého digitu
  parameter bit COMMON_ANODE     = 1             // 1 = spoločná anóda, 0 = spoločná katóda
)(
  input  wire logic              clk_i,
  input  wire logic              rst_ni,
  input  wire logic [3:0]        digits_i [NUM_DIGITS], // číslice 0–F
  input  wire logic              dots_i   [NUM_DIGITS], // bodky
  output logic [NUM_DIGITS-1:0]  digit_sel_o,            // výber číslice
  output logic [7:0]             segment_sel_o,          // výstup segmentov (DP,G,F,E,D,C,B,A)
  output logic [$clog2(NUM_DIGITS)-1:0] current_digit_o  // výber aktívneho indexu (voliteľné)
);

  // Výpočet počtu hodín medzi prepínaním číslic
  localparam int TicksPerDigit = (DIGIT_REFRESH_HZ == 0 || CLOCK_FREQ_HZ == 0)
                                    ? 1 : CLOCK_FREQ_HZ / DIGIT_REFRESH_HZ;

  localparam int TicksWidth = $clog2(TicksPerDigit);
  localparam int NumDigitsWidth = $clog2(NUM_DIGITS);

  logic [TicksWidth-1:0] tick_counter;
  logic [NumDigitsWidth-1:0] seg_sel_idx;

  // Interné signály pre nasledujúci stav výstupov
  logic [NUM_DIGITS-1:0] digit_sel_next;
  logic [7:0]            segment_sel_next;

  assign current_digit_o = seg_sel_idx;

  // Časovač pre multiplexovanie číslic
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tick_counter <= '0;
      seg_sel_idx  <= '0;
    end else if (tick_counter == TicksPerDigit - 1) begin
      tick_counter <= '0;
      seg_sel_idx  <= (seg_sel_idx == NUM_DIGITS - 1) ? '0 : seg_sel_idx + NumDigitsWidth'(1);
    end else begin
      tick_counter <= tick_counter + TicksWidth'(1);
    end
  end

  // Segmentový dekóder 4-bit čísla (0-F) + desatinná bodka
  function automatic logic [7:0] seg_decoder(
    input logic [3:0] val,
    input logic       dot
  );
    logic [6:0] seg_raw; // G-F-E-D-C-B-A bez DP
    logic [7:0] seg_full;

    case (val)
      // GFEDCBA (segmenty bez bodky)
      4'h0: seg_raw = 7'b1000000;
      4'h1: seg_raw = 7'b1111001;
      4'h2: seg_raw = 7'b0100100;
      4'h3: seg_raw = 7'b0110000;
      4'h4: seg_raw = 7'b0011001;
      4'h5: seg_raw = 7'b0010010;
      4'h6: seg_raw = 7'b0000010;
      4'h7: seg_raw = 7'b1111000;
      4'h8: seg_raw = 7'b0000000;
      4'h9: seg_raw = 7'b0010000;
      4'hA: seg_raw = 7'b0001000;
      4'hB: seg_raw = 7'b0000011;
      4'hC: seg_raw = 7'b1000110;
      4'hD: seg_raw = 7'b0100001;
      4'hE: seg_raw = 7'b0000110;
      4'hF: seg_raw = 7'b0001110;
      default: seg_raw = 7'b1111111; // všetko zhasnuté
    endcase

    // Pridanie bodky ako MSB (bit 7 = DP)
    seg_full  = {~dot, seg_raw}; // DP,G,F,E,D,C,B,A

    // Výstup podľa typu displeja
    return (COMMON_ANODE) ? seg_full : ~seg_full;
  endfunction

  // Výber aktívnej číslice podľa typu displeja (CA alebo CK)
  always_comb begin
    // Výpočet nasledujúceho stavu pre výber číslice
    digit_sel_next = (COMMON_ANODE) ? '1 : '0; // default: všetky neaktívne
    if (COMMON_ANODE)
      digit_sel_next[seg_sel_idx] = 1'b0; // aktívne LOW
    else
      digit_sel_next[seg_sel_idx] = 1'b1; // aktívne HIGH

    // Výpočet nasledujúceho stavu pre segmenty
    if (seg_sel_idx < NUM_DIGITS)
      segment_sel_next = seg_decoder(digits_i[seg_sel_idx], dots_i[seg_sel_idx]);
    else
      segment_sel_next = (COMMON_ANODE) ? 8'hFF : 8'h00; // všetko zhasnuté
  end

  // NOVÉ: FF Ostrovček - registrácia vypočítaných hodnôt do výstupov
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      // Po resete bezpečne zhasnúť displej
      digit_sel_o   <= (COMMON_ANODE) ? '1 : '0;
      segment_sel_o <= (COMMON_ANODE) ? 8'hFF : 8'h00;
    end else begin
      // V každom cykle sa výstupy aktualizujú na novú, stabilnú hodnotu
      digit_sel_o   <= digit_sel_next;
      segment_sel_o <= segment_sel_next;
    end
  end


endmodule

`endif // SEVEN_SEG_SV
