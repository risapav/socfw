/**
 * @brief       Generátor testovacích obrazcov pre VGA výstup.
 * @details     Modul generuje rôzne testovacie obrazce (šachovnice, prechody, farebné pruhy, pohyblivé prvky)
 *              automaticky prispôsobené rozlíšeniu definovanému parametrom a riadené režimom `mode_i`.
 *              Vstupy sú súradnice pixelov, signály časovania a povolenie činnosti modulu.
 *
 * @param[in]   MaxModes     Počet dostupných režimov generovania obrazcov.
 * @param[in]   MAX_COUNTER_H   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v H smere
 * @param[in]   MAX_COUNTER_V   Najvyššia hodnota, ktorú dosiahne čítač počítajúci pozíciu v V smere

 * @param[in]   ModeWidth    Šírka bitov pre výber režimu (voľba obrazca).
 *
 * @input       clk_i       Hodinový signál (pixel clock).
 * @input       rst_ni      Synchrónny reset, aktívny v L.
 * @input       enable_i    Povolenie generovania obrazcov.
 * @input       h_line_i    Informácie o horizontálnom časovaní (line_t typ).
 * @input       v_line_i    Informácie o vertikálnom časovaní (line_t typ).
 * @input       x_i         Aktuálna X súradnica pixelu.
 * @input       y_i         Aktuálna Y súradnica pixelu.
 * @input       de_i        Data Enable – indikuje viditeľnú oblasť pixelov.
 * @input       mode_i      Výber režimu generátora obrazcov.
 *
 * @output      data_o      Výstupný RGB565 dátový signál pre aktuálny pixel.
 *
 * @example
 *
 * import vga_pkg::*;
 *
 * picture_gen #(
 *     .MaxModes(8),
 *     .MAX_COUNTER_H(MaxPosCounterX),
 *     .MAX_COUNTER_V(MaxPosCounterY)
 * ) u_picture_gen (
 *   .clk_i(clk),
 *   .rst_ni(rst_n),
 *   .enable_i(1'b1),
 *   .h_line_i(h_line),
 *   .v_line_i(v_line),
 *   .x_i(pixel_x),
 *   .y_i(pixel_y),
 *   .de_i(data_enable),
 *   .mode_i(3'd2),
 *   .data_o(rgb_data)
 * );
 */


`ifndef VGA_IMAGE_GEN
`define VGA_IMAGE_GEN

`timescale 1ns/1ns

`default_nettype none

import vga_pkg::*;

// =============================================================================
// == Modul: ImageGenerator
// == Popis: Generuje testovacie obrazce, ktoré sa automaticky prispôsobujú
// ==        rozlíšeniu definovanému v parametri C_VGA_MODE.
// =============================================================================
module picture_gen #(
    parameter int H_RES = 1024,   // horizontálne rozlíšenie
    parameter int V_RES = 768,    // vertikálne rozlíšenie

    parameter int MaxModes = 8,

    // odvodené parametre
    parameter int ModeWidth     = $clog2(MaxModes),
    parameter int CounterWidthX = $clog2(H_RES),
    parameter int CounterWidthY = $clog2(V_RES)
)(
    // --- Vstupy zo systému ---
    input  wire logic clk_i,        // Vstupný hodinový signál (pixel clock)
    input  wire logic rst_ni,       // Synchrónny reset, aktívny v L
    input  wire logic enable_i,     // Povolenie činnosti modulu

    // --- Vstupy pre VLASTNÉ časovanie ---
    input  line_t     h_line_i,
    input  line_t     v_line_i,

    // --- Vstupy súradníc (typicky z modulu PixelCoordinates) ---
    input  wire logic [CounterWidthX-1:0] x_i,
    input  wire logic [CounterWidthY-1:0] y_i,

    // Data Enable signál indikuje, kedy je pixel v aktívnej (viditeľnej) oblasti.
    input  wire logic    de_i,

    // Vstup na riadenie režimu (napr. pripojený na prepínače na doske)
    input  wire logic [ModeWidth-1:0] mode_i,

    // --- Výstup ---
    // Vypočítané RGB565 dáta pre aktuálny pixel
    output rgb565_t      data_o
);

    // Ostatné lokálne parametre
    localparam int CheckerSizeSmall = 3; // 8x8 px
    localparam int CheckerSizeLarge = 5; // 32x32 px
    localparam int AnimWidth = 8;

    // Prehľadný zoznam dostupných režimov generátora.
    typedef enum logic [ModeWidth-1:0] {
        MODE_CHECKER_SMALL  = 3'd0, // Malá šachovnica (8x8 px)
        MODE_CHECKER_LARGE  = 3'd1, // Veľká šachovnica (32x32 px)
        MODE_H_GRADIENT     = 3'd2, // Horizontálny farebný prechod
        MODE_V_GRADIENT     = 3'd3, // Vertikálny čiernobiely prechod
        MODE_COLOR_BARS     = 3'd4, // Vertikálne farebné pruhy (SMPTE)
        MODE_CROSSHAIR      = 3'd5, // Zameriavací kríž v strede
        MODE_DIAG_SCROLL    = 3'd6, // Pohyblivé diagonálne pruhy
        MODE_MOVING_BAR     = 3'd7  // moving bar
    } mode_e;

    // =========================================================================
    // ==               Sekvenčná logika pre animované obrazce              ==
    // =========================================================================

    // Nový always_ff blok pre registráciu výstupu
    rgb565_t data_next;

    always_ff @(posedge clk_i) begin
        if (!rst_ni)
            data_o <= BLACK;
        else if (de_i) // Farbu priradíme len vo viditeľnej oblasti
            data_o <= data_next;
        else
            data_o <= BLACK; // Mimo viditeľnej oblasti posielame čiernu
    end

    // --- Sekvenčná logika pre animáciu (bez zmeny) ---
    logic [AnimWidth-1:0] scroll_offset;
    logic [ModeWidth-1:0] mode_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            mode_q        <= '0;
            scroll_offset <= '0;
        end else if (enable_i) begin
            mode_q <= mode_i;

            // Detekcia konca snímky pre plynulú animáciu
            if (x_i == h_line_i.visible_area-1 && y_i == v_line_i.visible_area-1) begin
                scroll_offset <= scroll_offset + AnimWidth'(1);
            end
        end
    end

    // =========================================================================
    // ==        KOMBINAČNÁ LOGIKA - DYNAMICKÝ GENERÁTOR OBRAZCOV            ==
    // =========================================================================
    always_comb begin : generate_output
        data_next = BLACK;

        case (mode_e'(mode_q))

            // Tieto režimy sú prirodzene flexibilné a nepotrebujú zmenu
            MODE_CHECKER_SMALL: data_next =
                (x_i[CheckerSizeSmall] ^ y_i[CheckerSizeSmall]) ? WHITE : BLACK;
            MODE_CHECKER_LARGE: data_next =
                (x_i[CheckerSizeLarge] ^ y_i[CheckerSizeLarge]) ? BLUE : YELLOW;

            MODE_H_GRADIENT: begin
                // aby sme predišli chybám "index out of range".
                logic [15:0] x_extended;
                x_extended = x_i; // Automaticky sa doplní nulami zľava

                data_next.red = x_extended[10:6];
                data_next.grn = x_extended[9:4];
                data_next.blu = x_extended[7:3];
            end

            MODE_V_GRADIENT: begin
                // aby sme predišli chybám "index out of range".
                logic [15:0] y_extended;
                y_extended = y_i;

                data_next.red = y_extended[10:6];
                data_next.grn = y_extended[9:4];
                data_next.blu = y_extended[7:3];
            end

            MODE_DIAG_SCROLL:   begin
                // aby sme predišli chybám "index out of range".
                logic [15:0] sum_extended;
                sum_extended = x_i + y_i + scroll_offset;

                data_next.red = sum_extended[10:6];
                data_next.grn = sum_extended[9:4];
                data_next.blu = sum_extended[7:3];
            end

            MODE_MOVING_BAR:    begin
                if (((x_i + scroll_offset) & 8'h3F) < 16) data_next = RED;
                else data_next = BLACK;
            end

            // --- DYNAMICKÁ LOGIKA PRE FAREBNÉ PRUHY ---
            MODE_COLOR_BARS: begin
                // Vyhneme sa hardvérovej deličke použitím násobenia.
                // Podmienka `x_i < C_WIDTH / 8` je ekvivalentná `x_i * 8 < C_WIDTH`.
                // Násobenie 8 je len bitový posun doľava o 3, čo je hardvérovo triviálne.
                logic [CounterWidthX+2:0] x_times_8;
                x_times_8 = x_i << 3;

                if      (x_times_8 < h_line_i.visible_area * 1) data_next = WHITE;
                else if (x_times_8 < h_line_i.visible_area * 2) data_next = YELLOW;
                else if (x_times_8 < h_line_i.visible_area * 3) data_next = CYAN;
                else if (x_times_8 < h_line_i.visible_area * 4) data_next = GREEN;
                else if (x_times_8 < h_line_i.visible_area * 5) data_next = PURPLE;
                else if (x_times_8 < h_line_i.visible_area * 6) data_next = RED;
                else if (x_times_8 < h_line_i.visible_area * 7) data_next = BLUE;
                else                                            data_next = BLACK;
            end

            // --- DYNAMICKÁ LOGIKA PRE ZAMERIAVACÍ KRÍŽ ---
            MODE_CROSSHAIR: begin
                logic [CounterWidthX-1:0] center_x;
                logic [CounterWidthY-1:0] center_y;
                logic is_on_x_line, is_on_y_line;

                // Stred vypočítame bitovým posunom doprava (delenie dvomi)
                center_x = h_line_i.visible_area >> 1;
                center_y = v_line_i.visible_area >> 1;

                // Podmienka pre vykreslenie čiary
                is_on_y_line = (y_i > (center_y - 2)) && (y_i < (center_y + 2));
                is_on_x_line = (x_i > (center_x - 2)) && (x_i < (center_x + 2));

                if (is_on_x_line || is_on_y_line)
                    data_next = WHITE;
                else
                    data_next = DARKGRAY;
            end

            default: data_next = ORANGE;

        endcase
    end
endmodule

`endif //VGA_IMAGE_GEN
