/**
 * @brief       VGA kontrolér pre výstup RGB signálu a synchronizačných impulzov
 * @details     Modul `vga_ctrl` je vrcholový riadiaci modul pre VGA výstup. Integruje generátor časovania (`vga_timing`)
 *              a výstupnú logiku, ktorá riadi synchronizačné impulzy, data enable signály a farebný výstup.
 *              Z FIFO zásobníka načítava RGB dáta v režime "aktívne zobrazovanie" (hde & vde). Ak FIFO neobsahuje dáta
 *              počas požiadavky, výstupne sa generuje diagnostická farba `UNDERRUN_COLOR`.
 *              Počas blankingu sa výstupne generuje `BLANKING_COLOR`.
 *
 * @param[in]   BLANKING_COLOR     Farba (RGB565), ktorá sa zobrazuje počas "blanking" intervalov.
 * @param[in]   UNDERRUN_COLOR     Diagnostická farba zobrazovaná pri podtečení FIFO.
 * @param[in]   MAX_COUNTER_H   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v H smere
 * @param[in]   MAX_COUNTER_V   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v V smere
 *
 * @input       clk_i              Hlavný hodinový signál (pixel clock).
 * @input       rst_ni             Asynchrónny reset, aktívny v L.
 * @input       enable_i           Povolenie činnosti (aktivuje generovanie signálov).
 *
 * @input       h_line_i           Časové parametre pre horizontálnu synchronizáciu (štruktúra typu `line_t`).
 * @input       v_line_i           Časové parametre pre vertikálnu synchronizáciu (štruktúra typu `line_t`).
 *
 * @input       fifo_data_i        RGB565 farebné dáta pre aktuálny pixel z FIFO zásobníka.
 * @input       fifo_empty_i       Signál indikujúci prázdny FIFO (podtečenie).
 *
 * @output      hde_o              Aktivita horizontálnej oblasti (1 počas ACT fázy).
 * @output      vde_o              Aktivita vertikálnej oblasti (1 počas ACT fázy).
 * @output      dat_o              Výstupné RGB dáta (typ `vga_data_t`) pre DAC.
 * @output      syn_o              Výstupný signál typu `vga_sync_t` (obsahuje h_sync a v_sync).
 * @output      eol_o              Pulz na konci riadku (End Of Line).
 * @output      eof_o              Pulz na konci celej snímky (End Of Frame).
 *
 * @example
 * Názorný príklad použitia:
 *
 *   import vga_pkg::*;
 *   
 *   localparam VgaMode = VGA_640x480_60;
 *   localparam int PixelClockHz = get_pixel_clock(VgaMode);
 *   
 *   // --- Signály pre prepojenie modulov ---
 *   rgb565_t picture_data;     // Dáta z generátora obrazu
 *   rgb565_t   data_out;       // Finálne dáta z VGA radiča
 *   vga_sync_t sync_out;       // Finálne sync signály z VGA radiča
 *   wire       hde, vde;       // Data Enable signály
 *   wire       eol, eof;       // Pulzy konca riadku/snímky
 *   
 *   line_t      h_line;
 *   line_t      v_line;
 *       
 *   `ifdef __ICARUS__
 *         // Pre simuláciu (Icarus) zadáme parametre manuálne
 *         h_line = '{640, 16, 96, 48, PulseActiveLow};
 *         v_line = '{480, 10, 2, 33, PulseActiveLow};
 *   `else
 *          // Pre syntézu (Quartus) použijeme funkciu z balíčka vga_pkg
 * 	        vga_params_t vga_params = get_vga_params(VgaMode);
 *          assign h_line = vga_params.h_line;
 *          assign v_line = vga_params.v_line;
 *   `endif
 *       
 *   // --- Inštancia VGA radiča (časovanie + dátová cesta) ---
 *   vga_ctrl #(
 *       .BLANKING_COLOR(16'h0000),
 *       .UNDERRUN_COLOR(16'hF81F)
 *   ) u_ctrl (
 *       .clk_i        (pixel_clk),
 *       .rst_ni       (rst_n),
 *       .enable_i     (1'b1), // Radič beží neustále
 *       .h_line_i     (h_line),
 *       .v_line_i     (v_line),
 *       .fifo_data_i  (picture_data),
 *       .fifo_empty_i (1'b0), // Zdroj dát (generátor) nie je nikdy prázdny
 *       .hde_o        (hde),
 *       .vde_o        (vde),
 *       .dat_o        (data_out),
 *       .syn_o        (sync_out),
 *       .eol_o        (eol),
 *       .eof_o        (eof)
 *   );
 */

`ifndef VGA_CTRL
`define VGA_CTRL

`timescale 1ns/1ns
`default_nettype none

import vga_pkg::*;

module vga_ctrl #(
    /** @brief Farba zobrazená počas zatemňovacích (blanking) intervalov. */
    parameter vga_data_t BLANKING_COLOR = BLACK,
    /** @brief Farba zobrazená pri podtečení FIFO, slúži na vizuálnu diagnostiku. */
    parameter vga_data_t UNDERRUN_COLOR = PURPLE,
    /** @brief Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v H smere. */
    parameter int MAX_COUNTER_H = MaxPosCounterX,    
    /** @brief Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v V smere. */
    parameter int MAX_COUNTER_V = MaxPosCounterY
)(
    // --- Hlavné Vstupy ---
    input  wire logic clk_i,        ///< @brief Systémové hodiny (pixel clock).
    input  wire logic rst_ni,       ///< @brief Synchrónny reset, aktívny v L.
    input  wire logic enable_i,     ///< @brief Povolenie činnosti celého kontroléra.

    // --- Vstupy pre VLASTNÉ časovanie ---
    input  line_t     h_line_i,     ///< @brief Parametre pre horizontálne časovanie.
    input  line_t     v_line_i,     ///< @brief Parametre pre vertikálne časovanie.

    // --- Vstupy z FIFO buffera ---
    input  rgb565_t   fifo_data_i,  ///< @brief Dáta jedného pixelu (RGB565) z FIFO.
    input  wire logic fifo_empty_i, ///< @brief Flag signalizujúci, že FIFO je prázdne.

    // --- Výstupy do fyzického VGA rozhrania ---
    output logic      hde_o,      ///< @brief Registrovaný signál horizontálnej aktívnej oblasti.
    output logic      vde_o,      ///< @brief Registrovaný signál vertikálnej aktívnej oblasti.
    output rgb565_t   dat_o,      ///< @brief Registrované výstupné RGB dáta pre VGA DAC.
    output vga_sync_t syn_o,      ///< @brief Registrované synchronizačné signály (h_sync a v_sync).
    output logic      eol_o,      ///< @brief Registrovaný pulz na konci každého riadku.
    output logic      eof_o       ///< @brief Registrovaný pulz na konci každej snímky.
);

    // =========================================================================
    // ==                          INTERNÉ SIGNÁLY                          ==
    // =========================================================================

    // Surové (neregistrované) signály z pod-modulu Timing
    wire hde_d, vde_d;
    wire hsyn_d, vsyn_d;
    wire eol_d, eof_d;

    // Pomocné signály pre riadenie toku dát
    wire valid_pixel, underrun;

    // Výstupné registre pre zabezpečenie stability a časovania
    reg        hde_q, vde_q;
    reg        eol_q, eof_q;
    rgb565_t   data_q;
    vga_sync_t sync_q;


    // =========================================================================
    // ==                        GENERÁTOR ČASOVANIA                        ==
    // =========================================================================

    // Inštancia modulu Timing, ktorý generuje všetky základné časovacie signály.
    vga_timing #(
        .MAX_COUNTER_H(MAX_COUNTER_H),
        .MAX_COUNTER_V(MAX_COUNTER_V)
    ) timing_inst (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .enable_i   (enable_i),
        .h_line_i   (h_line_i),
        .v_line_i   (v_line_i),
        .hde_o      (hde_d),
        .vde_o      (vde_d),
        .hsyn_o     (hsyn_d),
        .vsyn_o     (vsyn_d),
        .eol_o      (eol_d),
        .eof_o      (eof_d)
    );

    // =========================================================================
    // ==               LOGIKA PRE UNDERRUN A PLATNÉ PIXELY                 ==
    // =========================================================================

    // Underrun nastane, ak radič vyžaduje pixel (de=1), ale FIFO je prázdne.
    assign underrun = hde_d & vde_d & fifo_empty_i;
    // Pixel je platný, ak ho radič vyžaduje a FIFO NIE JE prázdne.
    assign valid_pixel = hde_d & vde_d & ~fifo_empty_i;


    // =========================================================================
    // ==                    VÝSTUPNÁ REGISTRAČNÁ LOGIKA                    ==
    // =========================================================================

    // Tento blok registruje všetky výstupy, aby boli čisté a zosynchronizované s hodinami.
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            // ----- Resetovacie hodnoty -----
            hde_q     <= 1'b0;
            vde_q     <= 1'b0;
            data_q    <= BLANKING_COLOR;
            sync_q.hs <= 1'b1; // Predvolená neaktívna úroveň
            sync_q.vs <= 1'b1; // Predvolená neaktívna úroveň
            eol_q     <= 1'b0;
            eof_q     <= 1'b0;
        end else if (enable_i) begin
            // ----- Hodnoty počas normálneho behu -----

            // Registrujeme "surové" signály z generátora časovania
            hde_q     <= hde_d;
            vde_q     <= vde_d;
            sync_q.hs <= hsyn_d;
            sync_q.vs <= vsyn_d;
            eol_q     <= eol_d;
            eof_q     <= eof_d;

            // Logika multiplexera pre výber farby pixelu
            if (underrun) begin
                data_q <= UNDERRUN_COLOR;
            end else if (valid_pixel) begin
                data_q <= fifo_data_i;
            end else begin
                data_q <= BLANKING_COLOR;
            end
        end
    end

    // =========================================================================
    // ==                         VÝSTUPNÉ PRIRADENIA                       ==
    // =========================================================================

    // Priradenie stabilných, registrovaných signálov na fyzické výstupy modulu.
    assign hde_o  = hde_q;
    assign vde_o  = vde_q;
    assign dat_o  = data_q;
    assign syn_o  = sync_q;
    assign eol_o  = eol_q;
    assign eof_o  = eof_q;

endmodule

`endif // VGA_CTRL

