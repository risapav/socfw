/**
 * @brief       Generátor VGA súradníc pixelov (X, Y)
 * @details     Modul `vga_pixel_xy` generuje súradnice aktuálneho pixelu na obrazovke (X, Y)
 *              na základe hodín (pixel clock), pulzov konca riadku (eol_i) a snímky (eof_i).
 *              Pozícia bodu (X, Y), ktorý sa nachádza vo viditeľnej časti obrazu.
 *              Inkrementuje X každý takt a resetuje ho na konci riadku. Y sa inkrementuje
 *              na konci každého riadku a resetuje na konci snímky. Vhodné na generovanie
 *              pozície pre grafický výstup v rámci VGA časovania.
 *
 * @param[in]   MAX_COUNTER_H   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v H smere
 * @param[in]   MAX_COUNTER_V   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v V smere
 *
 * @input       clk_i               Hodinový signál – pixel clock.
 * @input       rst_ni              Asynchrónny reset (aktívny v L).
 * @input       enable_i            Povolenie inkrementácie (aktivuje čítanie X/Y).
 * @input       eol_i               Pulz konca riadku – resetuje X a inkrementuje Y.
 * @input       eof_i               Pulz konca snímky – resetuje Y.
 *
 * @output      x_o                 Pozícia X súradnice v aktívnej časti obrazu
 * @output      y_o                 Pozícia Y súradnice v aktívnej časti obrazu
 *
 * @example
 * Názorný príklad použitia:
 *
 *   import vga_pkg::*;
 *
 *   vga_pixel_xy #(
 *     .MAX_COUNTER_H(MaxPosCounterX),
 *     .MAX_COUNTER_V(MaxPosCounterY)
 *   ) u_pixel_xy (
 *     .clk_i(clk),
 *     .rst_ni(rst_n),
 *     .enable_i(1'b1),
 *     .eol_i(eol),
 *     .eof_i(eof),
 *     .x_o(x),
 *     .y_o(y)
 *   );
 */


`ifndef VGA_PIXEL_XY
`define VGA_PIXEL_XY

`timescale 1ns/1ns
`default_nettype none

import vga_pkg::*;

module vga_pixel_xy #(
    // --- Parametre pre celkové rozmery snímky ---
    /** @brief Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v H smere */
    parameter int MAX_COUNTER_H = MaxPosCounterX,    
    /** @brief Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v V smere. */
    parameter int MAX_COUNTER_V = MaxPosCounterY, 
    
    // Definujeme šírku ako ďalší PARAMETER, nie localparam
    parameter int CounterWidthX = $clog2(MAX_COUNTER_H),
    parameter int CounterWidthY = $clog2(MAX_COUNTER_V)    
)(
    input  wire logic clk_i,        ///< @brief Vstupný hodinový signál (pixel clock).
    input  wire logic rst_ni,       ///< @brief Asynchrónny reset, aktívny v L.
    input  wire logic enable_i,     ///< @brief Povolenie inkrementácie počítadiel.
    input  wire logic eol_i,        ///< @brief Vstupný pulz konca riadku (End of Line), resetuje X a inkrementuje Y.
    input  wire logic eof_i,        ///< @brief Vstupný pulz konca snímky (End of Frame), resetuje Y.

    output logic [CounterWidthX-1:0] x_o, //pozícia x v aktívnej časti obrazu
    output logic [CounterWidthY-1:0] y_o  //pozícia y v aktívnej časti obrazu
);

    //================================================================
    // ==                     Logika Počítadiel                      ==
    // Jeden `always_ff` blok pre oba počítadlá pre lepšiu prehľadnosť.
    //================================================================
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            x_o <= '0;
            y_o <= '0;
        end else if (enable_i) begin

            // --- Logika pre X súradnicu ---
            // Počítadlo X sa inkrementuje každý takt a resetuje na konci riadku.
            if (eol_i) begin
                x_o <= '0;
            end else begin
                x_o <= x_o + CounterWidthX'(1);
            end

            // --- Logika pre Y súradnicu ---
            // Počítadlo Y sa inkrementuje iba na konci riadku
            // a resetuje sa na konci celej snímky.
            if (eof_i) begin
                y_o <= '0;
            end else if (eol_i) begin
                y_o <= y_o + CounterWidthY'(1);
            end

        end
    end

endmodule

`endif // VGA_PIXEL_XY
