/**
 * @file        data_num.sv
 * @brief       Počítadlo prenesených dát (Data Number Counter).
 * @details     Tento modul slúži ako jednoduché počítadlo, ktoré sa
 * inkrementuje vždy, keď je aktívny signál povolenia vysielania (tx_en_i).
 * Ak je vysielanie neaktívne, počítadlo sa automaticky vynuluje.
 * Modul je užitočný pre diagnostiku dĺžky prenášaného paketu.
 */

`ifndef DATA_NUM_SV
`define DATA_NUM_SV

`default_nettype none

module data_num (
  input  wire         clk_i,
  input  wire         rst_ni,
  input  wire         tx_en_i,
  output logic [12:0] my_num_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      my_num_o <= 13'd0;
    end else begin
      // Ak je vysielanie aktívne, inkrementuj. Inak udržuj/vynuluj.
      if (tx_en_i) begin
        my_num_o <= my_num_o + 1'b1;
      end else begin
        my_num_o <= 13'd0;
      end
    end
  end

endmodule

`endif // DATA_NUM_SV
