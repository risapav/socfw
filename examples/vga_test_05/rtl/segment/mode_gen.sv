/**
 * @file mode_gen.sv
 * @brief Automatický generátor prevádzkových režimov.
 * @details Modul v pravidelných intervaloch (CHANGE_PERIOD_MS) mení hodnotu mode_o (0-7).
 *          Zároveň poskytuje dáta pre 7-segmentový displej na zobrazenie aktuálneho módu.
 *
 * @param CLOCK_FREQ_HZ    Frekvencia systémových hodín v Hz.
 * @param NUM_DIGITS       Počet číslic 7-seg displeja pripojeného na výstup.
 * @param CHANGE_PERIOD_MS Interval zmeny módu v milisekundách.
 */

`ifndef MODE_GEN_SV
`define MODE_GEN_SV

`default_nettype none

// Automatický generátor VGA módu: každé CHANGE_PERIOD_MS ms inkrementuje
// mód 0-7, zobrazuje ho na seven-seg a posiela do picture_gen ako mode_i.
module mode_gen #(
    parameter int CLOCK_FREQ_HZ    = 50_000_000,
    parameter int NUM_DIGITS       = 3,
    parameter int CHANGE_PERIOD_MS = 2000
)(
    input  logic clk_i,
    input  logic rst_ni,

    ///< Aktuálny mód (0-7)
    output logic [2:0]              mode_o,

    ///< Dáta pre číslice displeja (BCD/HEX)
    output logic [NUM_DIGITS*4-1:0] digits_o,

    ///< Ovládanie bodiek na displeji
    output logic [NUM_DIGITS-1:0]   dots_o
);

    localparam int CHANGE_CYCLES = CLOCK_FREQ_HZ / 1000 * CHANGE_PERIOD_MS;
    localparam int CNT_W = $clog2(CHANGE_CYCLES);

    logic [CNT_W-1:0] prescaler;
    logic [2:0]       mode_q;

    // Logika prechodu stavov a časovania
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            prescaler <= '0;
            mode_q    <= '0;
        end else if (prescaler == CNT_W'(CHANGE_CYCLES - 1)) begin
            prescaler <= '0;
            mode_q    <= mode_q + 1'b1;
        end else begin
            prescaler <= prescaler + 1'b1;
        end
    end

    assign mode_o = mode_q;

    /**
     * Formátovanie výstupu pre displej:
     * Najpravšia číslica (digit 0) zobrazuje mód, ostatné sú zhasnuté (nuly).
     */
    always_comb begin
        digits_o      = '0;
        digits_o[3:0] = 4'(mode_q);
    end

    assign dots_o = '0;

endmodule

`endif
