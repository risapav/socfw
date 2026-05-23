/**
 * @version 1.0.0
 * @date    17.2.2026
 * @author  Pavol Risa
 *
 * @file        skid_buffer.sv
 * @brief       Full-Throughput Pipeline Register (Skid Buffer).
 * @details     Oddeľuje kombinačné cesty medzi Master a Slave bez vkladania wait-states.
 * Umožňuje dosiahnuť 100% priepustnosť aj pri protitlaku (backpressure).
 */

`ifndef SKID_BUFFER_SV
`define SKID_BUFFER_SV

`default_nettype none

module skid_buffer #(
    parameter int unsigned WIDTH = 32
)(
    input  wire               clk_i,
    input  wire               rst_ni,

    // Slave interface (Vstup - smerom k zdroju dát)
    input  wire               s_valid_i,
    output logic              s_ready_o,
    input  wire  [WIDTH-1:0]  s_data_i,

    // Master interface (Výstup - smerom k cieľu dát)
    output      logic         m_valid_o,
    input  wire               m_ready_i,
    output logic [WIDTH-1:0]  m_data_o
);

    // Skid storage registre
    logic [WIDTH-1:0] data_buffer_q;
    logic             valid_buffer_q;

    // --- Logika pripravenosti (Ready Logic) ---
    // Slave je pripravený, ak je buffer prázdny alebo ak Master práve odoberá dáta.
    assign s_ready_o = !valid_buffer_q || m_ready_i;

    // --- Logika výstupu (Output Logic) ---
    // Výstup je validný, ak máme dáta v bufferi (skid) alebo ak prichádzajú nové dáta (bypass).
    assign m_valid_o = valid_buffer_q || s_valid_i;

    // Ak je v bufferi platný obsah, má prioritu (zachovanie poradia dát).
    assign m_data_o  = valid_buffer_q ? data_buffer_q : s_data_i;

    // --- Správa registra (Buffer Management) ---
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_buffer_q <= 1'b0;
            data_buffer_q  <= '0;
        end else begin
            // Logika plnenia buffera (ak Slave posiela a Master neberie)
            if (s_valid_i && s_ready_o && !m_ready_i) begin
                data_buffer_q  <= s_data_i;
                valid_buffer_q <= 1'b1;
            end
            // Logika uvoľnenia buffera (ak Master berie a Slave neposiela nové dáta)
            else if (m_ready_i && !s_valid_i) begin
                valid_buffer_q <= 1'b0;
            end
            // Ak Master berie a Slave posiela (Bypass/Flow-through), stav valid_buffer_q sa nemení
        end
    end

endmodule

`endif // SKID_BUFFER_SV
