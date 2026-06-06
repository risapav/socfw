/**
 * @file       cdc_two_flop_synchronizer.sv
 * @brief      Dvojstupňový synchronizátor signálu pre CDC.
 * @details    Implementuje štandardný 2-FF synchronizátor na potlačenie metastability.
 * Výstup q_o je výstupom druhého klopného obvodu.
 * Obsahuje atribúty pre správne umiestnenie v FPGA (Quartus/Vivado).
 *
 * @param WIDTH Počet bitov signálu.
 *
 * @input clk_i  Hodinový signál cieľovej domény.
 * @input rst_ni Asynchrónny reset (aktívny LOW).
 * @input d_i    Vstupný asynchrónny signál.
 * @output q_o   Synchronizovaný výstup.
 */

`ifndef CDC_TWO_FLOP_SYNCHRONIZER_SV
`define CDC_TWO_FLOP_SYNCHRONIZER_SV

`default_nettype none

module cdc_two_flop_synchronizer #(
    parameter int WIDTH = 1
) (
    input  wire logic             clk_i,
    input  wire logic             rst_ni,
    input  wire logic [WIDTH-1:0] d_i,
    output      logic [WIDTH-1:0] q_o
);

    // Prvý stupeň synchronizácie (meta-stabilný stupeň)
    // Atribúty aplikujeme na oba stupne (stage 1 aj stage 2/output)
    // Poznámka: Quartus atribút sa aplikuje na premennú, Xilinx ASYNC_REG tiež.

    (* ASYNC_REG = "TRUE" *)
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [WIDTH-1:0] q_stage1;

    // Druhý stupeň je priamo výstup q_o.
    // Pre Xilinx je dobré mať ASYNC_REG aj na výstupe, ak je to súčasť reťazca,
    // ale tu stačí zabezpečiť, aby q_stage1 a q_o boli blízko seba.
    // V SystemVerilogu sa atribúty zvyčajne vzťahujú na nasledujúcu deklaráciu.

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            q_stage1 <= '0;
            q_o      <= '0;
        end else begin
            // 1. Stupeň: Zachytenie asynchrónneho vstupu
            q_stage1 <= d_i;

            // 2. Stupeň: Stabilizácia (výstup)
            q_o      <= q_stage1;
        end
    end

endmodule

`endif // CDC_TWO_FLOP_SYNCHRONIZER_SV

`default_nettype wire
