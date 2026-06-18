/**
 * @file bank_machine.sv
 * @brief Row tracking modul pre jednu SDRAM banku.
 *
 * @details
 * Sleduje stav konkrétnej banky (otvorená/zatvorená) a index aktívneho riadku.
 * Modul je pasívny tracker; rozhodnutia o časovaní vykonáva timing_manager
 * a logiku prepínania riadi memory_scheduler.
 *
 * @param ROW_ADDR_WIDTH Šírka adresy riadku (default 13 z sdram_pkg).
 */

`ifndef BANK_MACHINE_SV
`define BANK_MACHINE_SV

`default_nettype none
import sdram_pkg::*;

module bank_machine #(
  parameter int ROW_ADDR_WIDTH = 13
)(
  input  wire clk,
  input  wire rstn,

  // --- Príkazy od Schedulera ---
  input  wire                      do_activate,  // Pulz pri CMD_ACT
  input  wire                      do_precharge, // Pulz pri CMD_PRE
  input  wire [ROW_ADDR_WIDTH-1:0] row_addr,     // Adresa riadku pri ACT

  // --- Query Interface (od FIFO/Scheduler) ---
  input  wire [ROW_ADDR_WIDTH-1:0] query_row,    // Riadok, ktorý chceme obslúžiť

  // --- Status Výstupy ---
  output logic                     row_open,     // 1 = Banka má otvorený riadok
  output logic                     row_hit,      // 1 = Otvorený riadok sa zhoduje s query
  output logic [ROW_ADDR_WIDTH-1:0] curr_row     // Aktuálne otvorený riadok (pre debug)
);

  // ===========================================================================
  // INTERNÉ REGISTRE
  // ===========================================================================
  logic                      open_reg;
  logic [ROW_ADDR_WIDTH-1:0] row_reg;

  // ===========================================================================
  // LOGIKA STATUSU (Kombinačná)
  // ===========================================================================

  // Banka je otvorená len ak je open_reg nastavený
  assign row_open = open_reg;

  // Row Hit nastáva len ak je banka otvorená A riadok v registri sedí s dopytom
  assign row_hit  = open_reg && (row_reg == query_row);

  // Výstup aktuálneho riadku pre scheduler (napr. pre diagnostiku kolízií)
  assign curr_row = row_reg;

  // ===========================================================================
  // AKTUALIZÁCIA STAVU (Sekvenčná)
  // ===========================================================================
  /**
   * @details
   * Logika prechodu:
   * 1. Reset: Banka je zatvorená.
   * 2. ACTIVATE: Uložíme adresu riadku a označíme banku ako otvorenú.
   * 3. PRECHARGE: Označíme banku ako zatvorenú.
   *
   * Poznámka: do_activate a do_precharge by nemali nastať v tom istom takte.
   */
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      open_reg <= 1'b0;
      row_reg  <= '0;
    end else begin
      if (do_activate) begin
        open_reg <= 1'b1;
        row_reg  <= row_addr;
      end else if (do_precharge) begin
        open_reg <= 1'b0;
        // row_reg si ponecháva starú hodnotu (nemusíme nulovať pre úsporu logiky)
      end
    end
  end

endmodule

`endif // BANK_MACHINE_SV
