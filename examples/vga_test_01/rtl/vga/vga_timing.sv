/**
 * @brief       VGA generátor časovania
 * @details     Tento modul zabezpečuje generovanie horizontálneho a vertikálneho časovania pre VGA výstup.
 *              Pracuje s dvoma nezávislými inštanciami `vga_line` – pre horizontálne a vertikálne časovanie.
 *              Každý generátor prijíma štruktúru `line_t` s parametrami časovania (sync, back porch, active, front porch).
 *              Modul vypočítava signály ako hsync, vsync, hde, vde, koniec riadku (eol) a koniec snímky (eof).
 *
 * @param[in]   MAX_COUNTER_H   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v H smere
 * @param[in]   MAX_COUNTER_V   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v V smere
 *
 * @input       clk_i           Systémové hodiny (pixel clock)
 * @input       rst_ni          Asynchrónny reset, aktívny v L
 * @input       enable_i        Povolenie činnosti (napr. z časovača pre refresh)
 * @input       h_line_i        Horizontálna štruktúra `line_t` so všetkými parametrami VGA riadku
 * @input       v_line_i        Vertikálna štruktúra `line_t` pre riadky a snímky
 *
 * @output      hde_o           Príznak, že sa nachádzame v aktívnej časti riadku (data enable pre pixely)
 * @output      vde_o           Príznak, že sa nachádzame v aktívnej oblasti obrázka (riadky)
 * @output      hsyn_o          Horizontálny synchronizačný impulz, upravený podľa polarity
 * @output      vsyn_o          Vertikálny synchronizačný impulz, upravený podľa polarity
 * @output      eol_o           Jeden pulz na konci každého riadku
 * @output      eof_o           Jeden pulz na konci celej snímky (kombinácia eol a koniec vertikálneho počítadla)
 *
 * @example
 * Názorný príklad použitia:
 *
 *   import vga_pkg::*;
 *   
 *   localparam VgaMode = VGA_640x480_60;
 *   
 *   // --- Signály pre prepojenie modulov ---
 *   wire       hde, vde;       // Data Enable signály
 *   wire       eol, eof;       // Pulzy konca riadku/snímky
 *   wire       vsync, hsync;   // Synchro pulzy pre grafiku VGA
 *   
 *   line_t      h_line;
 *   line_t      v_line;
 *   
 *   `ifdef __ICARUS__
 *   // Pre simuláciu (Icarus) zadáme parametre manuálne
 *   h_line = '{640, 16, 96, 48, PulseActiveLow};
 *   v_line = '{480, 10, 2, 33, PulseActiveLow};
 *   `else
 *   // Pre syntézu (Quartus) použijeme funkciu z balíčka vga_pkg
 *   vga_params_t vga_params = get_vga_params(VgaMode);
 *   assign h_line = vga_params.h_line;
 *   assign v_line = vga_params.v_line;
 *   `endif
 *
 *   vga_timing #(
 *     .MAX_COUNTER_H(MaxPosCounterX),
 *     .MAX_COUNTER_V(MaxPosCounterY)
 *   ) u_vga_timing (
 *     .clk_i(clk),
 *     .rst_ni(rst_n),
 *     .enable_i(1'b1),
 *     .h_line_i(h_line),
 *     .v_line_i(v_line),
 *     .hde_o(hde),
 *     .vde_o(vde),
 *     .hsyn_o(hsync),
 *     .vsyn_o(vsync),
 *     .eol_o(eol),
 *     .eof_o(eof)
 *   );
 */

`ifndef VGA_TIMING
`define VGA_TIMING

`timescale 1ns / 1ns
`default_nettype none

import vga_pkg::*;


module vga_timing #(
    /** @brief Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v H smere */
    parameter int MAX_COUNTER_H = MaxPosCounterX,    
    /** @brief Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v V smere. */
    parameter int MAX_COUNTER_V = MaxPosCounterY
)(
    // --- Hlavné Vstupy ---
    input  wire logic clk_i,      ///< @brief Systémové hodiny (pixel clock).
    input  wire logic rst_ni,     ///< @brief Asynchrónny reset, aktívny v L.
    input  wire logic enable_i,   ///< @brief Povolenie činnosti modulu.

    // --- Vstupy pre VLASTNÉ časovanie ---
    input  line_t   h_line_i,     ///< @brief Štruktúra s kompletným horizontálnym časovaním.
    input  line_t   v_line_i,     ///< @brief Štruktúra s kompletným vertikálnym časovaním.

    // --- Výstupy ---
    output logic    hde_o,      ///< @brief Horizontálna aktívna oblasť (Horizontal Data Enable). Vysoká, keď sa majú kresliť pixely.
    output logic    vde_o,      ///< @brief Vertikálna aktívna oblasť (Vertical Data Enable). Vysoká, keď je aktívny riadok.
    output logic    hsyn_o,     ///< @brief Finálny horizontálny synchronizačný impulz (s aplikovanou polaritou).
    output logic    vsyn_o,     ///< @brief Finálny vertikálny synchronizačný impulz (s aplikovanou polaritou).
    output logic    eol_o,      ///< @brief Pulz na konci celého riadku (End of Line). Trvá jeden cyklus `clk_i`.
    output logic    eof_o       ///< @brief Pulz na konci celej snímky (End of Frame). Trvá jeden cyklus `clk_i`.
);

    //======================================================
    // ==                 Interné signály                  ==
    //======================================================

    // Udalosti z `Line` generátorov pred finálnou úpravou polarity
    wire h_sync_event;
    wire v_sync_event;

    // Riadiace signály medzi generátormi
    wire v_line_end_d, v_line_nol_d;
    wire h_line_end_d, h_line_nol_d;

    // Inštancia FSM pre horizontálne časovanie
    vga_line #(
        .MAX_COUNTER(MAX_COUNTER_H)
    ) h_line_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .inc_i(enable_i),
        .line_i(h_line_i),
        .de_o(hde_o),
        .syn_o(h_sync_event),
        .eol_o(h_line_end_d),
        .nol_o(h_line_nol_d) // Tento pulz taktuje vertikálny generátor
    );

    // Inštancia FSM pre vertikálne časovanie
    vga_line #(
        .MAX_COUNTER(MAX_COUNTER_V)
    ) v_line_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .inc_i(h_line_nol_d), // Vertikálny generátor je inkrementovaný na konci každého riadku
        .line_i(v_line_i),
        .de_o(vde_o),
        .syn_o(v_sync_event),
        .eol_o(v_line_end_d),
        .nol_o() // Nepoužitý
    );

    //======================================================
    // ==           Kombinačná logika pre výstupy          ==
    //======================================================

    assign hsyn_o = (h_sync_event == h_line_i.polarity);
    assign vsyn_o = (v_sync_event == v_line_i.polarity);

    assign eol_o = h_line_end_d;
    assign eof_o = h_line_end_d && v_line_end_d;

endmodule

`endif // VGA_TIMING
