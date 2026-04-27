/**
 * @version 1.1.0
 * @date    18.2.2026
 * @author  Pavol Risa
 *
 * @file    uart_baud_gen.sv
 * @brief   UART baud generator – start_tick + half_tick + end_tick
 *
 * Generuje:
 *  - start_tick_o: impulz na začiatku bitovej periódy
 *  - half_tick_o : impulz v strede bitovej periódy (sampling)
 *  - end_tick_o  : impulz na konci bitovej periódy
 *
 * Podporuje:
 *  - TX štart synchronizovaný na začiatok bitu
 *  - RX štart synchronizovaný na stred START bitu (phase align)
 */

`ifndef UART_BAUD_GEN_SV
`define UART_BAUD_GEN_SV

`default_nettype none

module uart_baud_gen #(
    parameter integer PRESCALE_WIDTH = 16
) (
    input  wire                 clk,
    input  wire                 rstn,

    input  wire                 start_i,   // 🔴 TX, RX štart: nabije plnú periódu
    input  wire                 enable_i,  // 🟢 Beží, keď je RX/TX busy

    input  wire [PRESCALE_WIDTH-1:0] prescale_i, // clk / baud

    output logic                 start_tick_o, // 1 takt na začiatku bitu
    output logic                 half_tick_o,  // 1 takt v strede bitu
    output logic                 end_tick_o    // 1 takt na konci bitu
);

    // --------------------------------------------------------------------------
    // Interné registre
    // --------------------------------------------------------------------------
    localparam integer COUNT_WIDTH = PRESCALE_WIDTH;
    logic [COUNT_WIDTH-1:0] count_q, count_d;
    logic [COUNT_WIDTH-1:0] half_offset;

    // --------------------------------------------------------------------------
    // Half tick offset – stred bitu
    // --------------------------------------------------------------------------
    always_comb begin
        half_offset = (prescale_i - COUNT_WIDTH'(1)) >> 1;
    end

    // --------------------------------------------------------------------------
    // Hlavný sekvenčný blok
    // --------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            count_q      <= prescale_i - COUNT_WIDTH'(1); // prvý tick hneď
            start_tick_o <= 1'b1;
            half_tick_o  <= 1'b0;
            end_tick_o   <= 1'b0;
        end else begin
            if (start_i) begin
                count_q      <= prescale_i - COUNT_WIDTH'(1);
                start_tick_o <= 1'b1;
                half_tick_o  <= 1'b0;
                end_tick_o   <= 1'b0;
            end else if (enable_i) begin
                start_tick_o <= (count_q == 0);
                half_tick_o  <= (count_q == half_offset);
                end_tick_o   <= (count_q == 1);

                if (count_q == 0)
                    count_q <= prescale_i - COUNT_WIDTH'(1);
                else
                    count_q <= count_q - COUNT_WIDTH'(1);
            end else begin
                // idle
                start_tick_o <= 1'b0;
                half_tick_o  <= 1'b0;
                end_tick_o   <= 1'b0;
            end
        end
    end

endmodule

`endif // UART_BAUD_GEN_SV
