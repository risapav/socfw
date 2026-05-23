/**
 * @file        axi_pkg.sv
 * @brief       Centrálna konfigurácia AXI-Stream zbernice.
 * @details     Tento balíček definuje základné parametre a dátové typy
 * pre AXI4-Stream komunikáciu používanú v celom projekte.
 * Umožňuje jednotnú konfiguráciu šírky dát a používateľských signálov.
 *
 * @param       AXI_TDATA_WIDTH   Šírka TDATA zbernice v bitoch (default: 16).
 * @param       AXI_TUSER_WIDTH   Šírka TUSER signálu v bitoch (default: 1).
 *
 * @typedef     axi4s_payload_t   Dátová štruktúra pre AXI4-Stream prenos.
 *
 * @example
 * // Príklad použitia v module:
 * import axi_pkg::*;
 * axi4s_payload_t payload;
 * assign payload.TDATA = 16'hABCD;
 * assign payload.TUSER = 1'b0;
 * assign payload.TLAST = 1'b1;
 */

`ifndef AXI_PKG_SV
`define AXI_PKG_SV

`default_nettype none

package axi_pkg;
  // NOTE:
  // This package contains ONLY synthesizable constructs.
  // No dynamic types, classes, or time-based constructs are used.
  // Fully compatible with Intel Quartus Prime.

  // ================================================================
  //  CENTRÁLNA KONFIGURÁCIA AXI ZBERNICE
  // ================================================================
  // Úpravou týchto parametrov sa zmení šírka AXI-Stream zbernice
  // v celom projekte, ktorý tento balíček importuje.

  localparam int AXI_TDATA_WIDTH = 16;  // Šírka TDATA v bitoch (napr. RGB565)
  localparam int AXI_TUSER_WIDTH = 1;  // Šírka TUSER v bitoch (napr. SOF), MUST be >= 1
  // NOTE: AXI_TUSER_WIDTH must be >= 1 (Quartus does not support zero-width vectors)
  localparam int AXI_TKEEP_WIDTH = (AXI_TDATA_WIDTH / 8) > 0 ? (AXI_TDATA_WIDTH / 8) : 1;
  // NOTE: AXI_TDATA_WIDTH must be a multiple of 8 to support TKEEP correctly.
/*
  // synthesis translate_off
  initial begin
    if (AXI_TDATA_WIDTH % 8 != 0) $error("AXI_TDATA_WIDTH must be multiple of 8");
  end
  // synthesis translate_on
*/
  // ================================================================
  //  AXI4-Stream Dátové Typy (Payloads)
  // ================================================================
  // Táto štruktúra definuje dátový obsah (payload) pre AXI-Stream.
  // Jej šírka sa automaticky prispôsobuje podľa parametrov vyššie.
  // Použitie `packed` je kľúčové, aby sa so štruktúrou dalo
  // pracovať ako s jedným súvislým bitovým vektorom.

  // NOTE:
  // Packed struct ensures deterministic bit layout for FIFOs and registers.
  typedef struct packed {
    logic                       TLAST;  // 1-bitový signál konca paketu (EOL/EOF)
    logic [AXI_TKEEP_WIDTH-1:0] TKEEP;
    logic [AXI_TUSER_WIDTH-1:0] TUSER;  // Používateľský signál (SOF)
    logic [AXI_TDATA_WIDTH-1:0] TDATA;  // Dátová zbernica (Video Data)
  } axi4s_payload_t;
  // NOTE: Field order is chosen to place TDATA in LSBs for easier FIFO mapping.

  // Pomocný parameter pre výpočet šírky FIFO bufferov
  localparam int PAYLOAD_WIDTH = AXI_TDATA_WIDTH + AXI_TUSER_WIDTH + AXI_TKEEP_WIDTH + 1;  // TLAST

  // ================================================================
  // AXI4 / AXI4-Lite Response Codes
  // ================================================================
  typedef enum logic [1:0] {
    AXI_RESP_OKAY   = 2'b00,  // Normal access success
    AXI_RESP_EXOKAY = 2'b01,  // Exclusive access success
    AXI_RESP_SLVERR = 2'b10,  // Slave error
    AXI_RESP_DECERR = 2'b11   // Decode error
  } axi_resp_t;

  // ================================================================
  // AXI Burst Types
  // ================================================================
  typedef enum logic [1:0] {
    AXI_BURST_FIXED = 2'b00,
    AXI_BURST_INCR  = 2'b01,
    AXI_BURST_WRAP  = 2'b10
  } axi_burst_t;

  // ================================================================
  // AXI Transfer Size Encoding (2^AWSIZE bytes)
  // ================================================================
  typedef enum logic [2:0] {
    AXI_SIZE_1B   = 3'd0,
    AXI_SIZE_2B   = 3'd1,
    AXI_SIZE_4B   = 3'd2,
    AXI_SIZE_8B   = 3'd3,
    AXI_SIZE_16B  = 3'd4,
    AXI_SIZE_32B  = 3'd5,
    AXI_SIZE_64B  = 3'd6,
    AXI_SIZE_128B = 3'd7
  } axi_size_t;

  // ================================================================
  // AXI-Lite Register Types and Descriptors
  // ================================================================

  typedef enum logic [1:0] {
    AXIL_RO    = 2'b00, // read-only
    AXIL_RW    = 2'b01, // read/write
    AXIL_W1C   = 2'b10, // write-1-to-clear
    AXIL_PULSE = 2'b11  // write generates 1-cycle pulse
  } axil_reg_type_e;

  typedef struct packed {
    logic [7:0]     offset;       // byte offset
    logic [31:0]    reset_value;  // reset value
    axil_reg_type_e reg_type;     // register behavior
  } axil_reg_desc_t;


endpackage : axi_pkg

// ================================================================
// Notes:
// - All parameters are compile-time constants.
// - This package is safe for synthesis and simulation.
// - Intended for use with axi_interfaces.sv and AXI-compliant RTL.
// ================================================================

`endif  // AXI_PKG_SV

