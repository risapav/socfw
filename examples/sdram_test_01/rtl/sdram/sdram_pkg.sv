/**
 * @file sdram_pkg.sv
 * @brief Globálne definície, typy a parametre pre SDRAM Controller.
 * @details Obsahuje výpočty bitových polí pre AXI-to-SDRAM mapping a JEDEC príkazy.
 * Doplnená podpora pre ID tagging a burst tracking.
 *
 * Changelog:
 *  [v160] T_WTR_CYCLES znížené z 2 na 1 — SDR SDRAM pri CL=3 potrebuje
 *         len 1 cyklus Write-to-Read turnaround. Overené simuláciou v160.
 *  [v160] T_RDL_CYCLES = CAS_LATENCY + 1 (Read-to-Precharge)
 */
`ifndef SDRAM_PKG_SV
`define SDRAM_PKG_SV

`default_nettype none

package sdram_pkg;

// ===========================================================================
// 1. MEMORY GEOMETRY (Konfigurovateľné)
// ===========================================================================
parameter int DATA_WIDTH      = 16;
parameter int ROW_ADDR_WIDTH  = 13;
parameter int BANK_ADDR_WIDTH = 2;
parameter int COL_ADDR_WIDTH  = 9;
parameter int AXI_ID_WIDTH    = 4;
parameter int AXI_DATA_WIDTH  = 32;  // [NEW] explicitná šírka AXI dátovej zbernice

// Pomocné konštanty
localparam int NUM_BANKS = 1 << BANK_ADDR_WIDTH;
localparam int NUM_ROWS  = 1 << ROW_ADDR_WIDTH;
localparam int NUM_COLS  = 1 << COL_ADDR_WIDTH;

// ===========================================================================
// 2. TIMING PARAMETERS (@100 MHz, JEDEC SDRAM)
// ===========================================================================
parameter int T_RCD_CYCLES  = 2;   // Row to Column Delay
parameter int T_RP_CYCLES   = 2;   // Row Precharge time
parameter int T_RFC_CYCLES  = 7;   // Refresh Cycle time
parameter int T_RAS_CYCLES  = 4;   // Row Active time (min)
parameter int CAS_LATENCY   = 3;   // CAS Latency (CL)
parameter int T_WR_CYCLES   = 2;   // Write Recovery time
parameter int T_WTR_CYCLES  = 1;   // [v160] Write-to-Read turnaround (znížené z 2)
parameter int T_RDL_CYCLES  = CAS_LATENCY + 1;  // Read-to-Precharge
parameter int T_REFI_CYCLES = 780; // Refresh interval (64ms / 8192 rows @ 100MHz)

// ===========================================================================
// 3. AXI -> SDRAM ADDRESS MAPPING
// ===========================================================================
// Príklad pre DATA_WIDTH=16, COL=9, BANK=2, ROW=13:
//   AXI addr [31:0]:
//   [0]      = byte offset (ignorovaný, 16-bit = 2B zarovnanie)
//   [9:1]    = col  (9 bitov)
//   [11:10]  = bank (2 bity)
//   [24:12]  = row  (13 bitov)
//   [31:25]  = nevyužité
localparam int BYTE_OFFSET_W = $clog2(DATA_WIDTH/8);
localparam int COL_BIT_LOW   = BYTE_OFFSET_W;
localparam int COL_BIT_HIGH  = COL_BIT_LOW  + COL_ADDR_WIDTH  - 1;
localparam int BANK_BIT_LOW  = COL_BIT_HIGH + 1;
localparam int BANK_BIT_HIGH = BANK_BIT_LOW + BANK_ADDR_WIDTH - 1;
localparam int ROW_BIT_LOW   = BANK_BIT_HIGH + 1;
localparam int ROW_BIT_HIGH  = ROW_BIT_LOW  + ROW_ADDR_WIDTH  - 1;

/*
// Sanity check — adresový priestor musí sa zmestiť do AXI_DATA_WIDTH bitov
// (ROW_BIT_HIGH + 1 <= AXI_DATA_WIDTH)
// synthesis translate_off
// V SystemVerilogu sa statické overenie v balíku píše bez 'if'
// Ak je podmienka nepravdivá, kompilácia skončí chybou.
// Poznámka: ROW_BIT_HIGH + 1 nesmie prekročiť AXI_DATA_WIDTH (32)
  static assert (ROW_BIT_HIGH < 32) else $error("SDRAM address mapping exceeds 32-bit AXI address space!");
// synthesis translate_on
*/

// ===========================================================================
// 4. SDRAM COMMANDS (JEDEC: {CS_N, RAS_N, CAS_N, WE_N})
// ===========================================================================
typedef enum logic [3:0] {
  CMD_MRS  = 4'b0000,  // Mode Register Set
  CMD_REF  = 4'b0001,  // Auto Refresh
  CMD_PRE  = 4'b0010,  // Precharge
  CMD_ACT  = 4'b0011,  // Active (Row Activate)
  CMD_WR   = 4'b0100,  // Write
  CMD_RD   = 4'b0101,  // Read
  CMD_TERM = 4'b0110,  // Burst Terminate
  CMD_NOP  = 4'b0111   // No Operation
} phy_cmd_e;

// ===========================================================================
// 5. DATA STRUCTURES
// ===========================================================================

/**
 * @struct sdram_addr_t
 * @brief Dekódovaná adresa pre vnútornú logiku kontroléra.
 */
typedef struct packed {
  logic [ROW_ADDR_WIDTH-1:0]  row;
  logic [BANK_ADDR_WIDTH-1:0] bank;
  logic [COL_ADDR_WIDTH-1:0]  col;
} sdram_addr_t;

/**
 * @struct sdram_cmd_t
 * @brief Rozšírený príkaz pre Scheduler a Read Engine.
 * @details Obsahuje meta-dáta potrebné na udržanie AXI kontextu cez pipeline.
 */
typedef struct packed {
  sdram_addr_t             addr;
  logic                    write_en;
  logic [7:0]              burst_len;
  logic [AXI_ID_WIDTH-1:0] id;    // AXI Transaction ID
  logic                    last;  // Posledný beat v burste
} sdram_cmd_t;

endpackage : sdram_pkg
`endif // SDRAM_PKG_SV
