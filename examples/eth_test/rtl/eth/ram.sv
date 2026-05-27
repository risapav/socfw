/**
 * @file        ram.sv
 * @brief       Odvodená dvojportová pamäť RAM (Inferred Simple Dual-Port RAM).
 * @details     Modul plne nahrádza zastarané Quartus Megafunction (altsyncram) súbory.
 * Je napísaný v čistom SystemVerilogu, pričom Quartus 25.1 ho
 * automaticky syntetizuje do dedikovaných pamäťových blokov (M9K/M10K/M20K).
 * Má oddelený port pre zápis a čítanie a 2-taktovú latenciu čítania.
 *
 * @param       DATA_WIDTH Šírka dátového slova (default: 32 bitov).
 * @param       ADDR_WIDTH Šírka adresnej zbernice (default: 9 bitov = 512 slov).
 */

`ifndef RAM_SV
`define RAM_SV

`default_nettype none

module ram #(
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned ADDR_WIDTH = 9
)(
  // Port A: Zápis
  input  wire                   clk_wr_i,
  input  wire                   we_i,
  input  wire  [ADDR_WIDTH-1:0] addr_wr_i,
  input  wire  [DATA_WIDTH-1:0] data_i,

  // Port B: Čítanie
  input  wire                   clk_rd_i,
  input  wire  [ADDR_WIDTH-1:0] addr_rd_i,
  output logic [DATA_WIDTH-1:0] data_o
);

  localparam int unsigned DEPTH = 2**ADDR_WIDTH;

  // Quartus RAM inference atribút zabezpečí, že syntéza nevyužije LUTs
  (* ramstyle = "no_rw_check" *) logic [DATA_WIDTH-1:0] mem [DEPTH];

  logic [DATA_WIDTH-1:0] read_data_q;

  // ==========================================================================
  // Zápisový port (Write)
  // ==========================================================================
  always_ff @(posedge clk_wr_i) begin
    if (we_i) begin
      mem[addr_wr_i] <= data_i;
    end
  end

  // ==========================================================================
  // Čítací port (Read) s 2-taktovou latenciou (Registered output)
  // ==========================================================================
  always_ff @(posedge clk_rd_i) begin
    // 1. takt: čítanie do interného registra (odpovedá 'address_reg_b')
    read_data_q <= mem[addr_rd_i];

    // 2. takt: prechod na výstupný register (odpovedá 'outdata_reg_b')
    data_o      <= read_data_q;
  end

endmodule

`endif // RAM_SV
