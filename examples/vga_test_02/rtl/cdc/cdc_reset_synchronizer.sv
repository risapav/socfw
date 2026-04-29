/**
 * @file        cdc_reset_synchronizer.sv
 * @brief       Synchronizátor asynchrónneho resetu (Reset Bridge).
 * @details     Asynchrónne aktivuje a synchrónne deaktivuje reset signál
 * v cieľovej hodinovej doméne. Zabraňuje metastabilite pri uvoľnení resetu.
 *
 * @param STAGES Počet synchronizačných stupňov (min. 2).
 * @param WIDTH  Šírka resetu (Musí byť 1. Parameter je tu pre kompatibilitu inštancií).
 *
 * @input  clk_i    Cieľové hodiny.
 * @input  rst_ni   Vstupný asynchrónny reset (active-low).
 * @output rst_no   Výstupný synchronizovaný reset (active-low).
 */

`default_nettype none

`ifndef CDC_RESET_SYNCHRONIZER_SV
`define CDC_RESET_SYNCHRONIZER_SV

module cdc_reset_synchronizer #(
    parameter int unsigned STAGES = 2,
    parameter int unsigned WIDTH  = 1 // Pridané pre kompatibilitu s axis_cdc_fifo
)(
    input  wire logic clk_i,
    input  wire logic rst_ni,
    output logic      rst_no
);

    // =========================================================================
    // 1. Kontrola Parametrov
    // =========================================================================
    initial begin
        if (STAGES < 2)
            $fatal("cdc_reset_synchronizer: STAGES must be >= 2");
        if (WIDTH != 1)
            $fatal("cdc_reset_synchronizer: WIDTH must be 1. Multi-bit reset sync is unsafe!");
    end

    // =========================================================================
    // 2. Synchronizačný Reťazec
    // =========================================================================
    // Atribúty pre syntetizátory na identifikáciu synchronizátora a umiestnenie blízko seba
    (* ASYNC_REG = "TRUE" *)
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [STAGES-1:0] rst_sync_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            // Asynchrónna aktivácia resetu (ihneď do 0)
            rst_sync_q <= '0;
        end else begin
            // Synchrónna deaktivácia (posun 1 cez registre)
            rst_sync_q <= {rst_sync_q[STAGES-2:0], 1'b1};
        end
    end

    // =========================================================================
    // 3. Výstup
    // =========================================================================
    // Výstup je posledný stupeň posuvného registra
    assign rst_no = rst_sync_q[STAGES-1];

endmodule

`endif // CDC_RESET_SYNCHRONIZER_SV

`default_nettype wire
