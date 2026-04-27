/**
 * @brief       Generátor jednej časovej periódy VGA signálu
 * @details     Modul `vga_line` implementuje konečný stavový automat (FSM), ktorý generuje
 *              časovanie jednej línie VGA signálu (horizontálnej alebo vertikálnej) podľa
 *              štruktúry `line_t`. FSM prechádza stavmi: aktívna oblasť (ACT), front porch (FRP),
 *              synchronizačný impulz (SYN), back porch (BCP) a koniec riadku (EOL).
 *              Výstupy indikujú aktuálnu fázu a generujú synchronizačné a riadiace signály.
 *
 * @param[in]   MAX_COUNTER        Najvyššia hodnota, ktorú dosiahne čítač.
 *
 * @input       clk_i              Hlavný hodinový signál.
 * @input       rst_ni             Synchrónny reset, aktívny v L.
 * @input       inc_i              Inkrementačný pulz (tick), ktorý aktivuje zmenu stavu FSM.
 * @input       line_i             Časová štruktúra `line_t` s nastaveniami dĺžok jednotlivých fáz.
 *
 * @output      de_o               Data Enable – vysoká počas aktívnej oblasti (ACT).
 * @output      syn_o              Synchronizačný výstup – vysoký počas fáz SYN.
 * @output      eol_o              End Of Line – jednocyklický pulz označujúci koniec celej periódy.
 * @output      nol_o              Next Of Line – jednocyklický pulz jeden takt pred EOL.
 *
 * @example
 *
 * Názorný príklad použitia:
 *   vga_line #(
 *     .MAX_COUNTER(MaxLineCounter))
 *   ) u_hline (
 *     .clk_i(clk),
 *     .rst_ni(rst_n),
 *     .inc_i(1'b1),
 *     .line_i(h_line),
 *     .de_o(hde),
 *     .syn_o(hsyn),
 *     .eol_o(eol),
 *     .nol_o(nol)
 *   );
 */


`ifndef VGA_LINE
`define VGA_LINE

`timescale 1ns / 1ns
`default_nettype none

import vga_pkg::*;

module vga_line #(
    /** @brief Šírka interného odpočítavacieho registra, určuje maximálnu dĺžku periody. */
    parameter int MAX_COUNTER = MaxLineCounter
)(
    input  wire logic    clk_i,    ///< @brief Hlavný hodinový signál.
    input  wire logic    rst_ni,   ///< @brief Asynchrónny reset, aktívny v L.
    input  wire logic    inc_i,    ///< @brief Inkrementačný pulz (tick), ktorý posúva stavový automat o jeden krok.
    input  line_t        line_i,   ///< @brief Štruktúra s časovacími parametrami (dĺžky periód).
    output logic         de_o,     ///< @brief Data Enable výstup. Vysoký počas aktívnej oblasti (ACT).
    output logic         syn_o,    ///< @brief Sync výstup. Vysoký počas synchronizačného pulzu (SYN).
    output logic         eol_o,    ///< @brief End of Line výstup. Jednoccyklový pulz na konci celého cyklu.
    output logic         nol_o     ///< @brief Next of Line výstup. Jednoccyklový pulz *pred* koncom celého cyklu.
);
    localparam int CounterWidth = $clog2(MAX_COUNTER);
    
    /** @brief Stavy konečného stavového automatu. */
    typedef enum logic [2:0] {
        EOL, ///< End Of Line - koncový stav cyklu (1 takt)
        ACT, ///< Active Area - aktívna viditeľná oblasť
        FRP, ///< Front Porch - predná veranda
        SYN, ///< Sync Pulse - synchronizačný pulz
        BCP  ///< Back Porch - zadná veranda
    } state_e;

    state_e state_q; ///< Register pre aktuálny stav FSM.
    logic [CounterWidth-1:0] counter_q; ///< Register pre odpočítavací čítač.

    //================================================================
    // ==         ZJEDNOTENÁ SEKVENČNÁ LOGIKA PRE FSM A POČÍTADLO      ==
    // Tento jediný blok riadi stavy aj počítadlo, čím sa eliminujú
    // pretekové podmienky (race conditions).
    //================================================================
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q   <= EOL;
            counter_q <= '0;
        end else if (inc_i) begin // Všetky zmeny sa dejú len pri takte `inc_i`
            unique case (state_q)
                EOL: begin
                    // EOL trvá vždy 1 cyklus, okamžite prechádzame do ACT
                    state_q   <= ACT;
                    counter_q <= line_i.visible_area - CounterWidth'(1);
                end

                ACT: begin
                    if (counter_q == 0) begin
                        state_q   <= FRP;
                        counter_q <= line_i.front_porch - CounterWidth'(1);
                    end else begin
                        counter_q <= counter_q - CounterWidth'(1);
                    end
                end

                FRP: begin
                    if (counter_q == 0) begin
                        state_q   <= SYN;
                        counter_q <= line_i.sync_pulse - CounterWidth'(1);
                    end else begin
                        counter_q <= counter_q - CounterWidth'(1);
                    end
                end

                SYN: begin
                    if (counter_q == 0) begin
                        state_q   <= BCP;
                        // Pre BCP+EOL spolu `bp` cyklov, BCP samotné trvá `bp-1`
                        counter_q <= line_i.back_porch - CounterWidth'(2);
                    end else begin
                        counter_q <= counter_q - CounterWidth'(1);
                    end
                end

                BCP: begin
                    if (counter_q == 0) begin
                        state_q   <= EOL;
                        counter_q <= '0;
                    end else begin
                        counter_q <= counter_q - CounterWidth'(1);
                    end
                end

                default: begin
                    state_q   <= EOL;
                    counter_q <= '0;
                end
            endcase
        end
    end

    //================================================================
    // ==              Kombinačná logika pre výstupy                ==
    //================================================================
    assign de_o  = (state_q == ACT);
    assign eol_o = (state_q == EOL);
    assign syn_o = (state_q == SYN);
    assign nol_o = (state_q == BCP) && (counter_q == 1);

endmodule

`endif // VGA_LINE
