/**
 * @file        axi_error_policy.sv
 * @brief       Centrálna politika chýb pre AXI4-Lite subsystém.
 * @details     Definuje chybové stavy, identifikačné patterny pre ladenie
 * a konverzné funkcie pre mapovanie interných chýb na AXI protokol.
 * Kompatibilné s Intel Quartus Prime 25.1 Lite.
 */

`ifndef AXI_ERROR_POLICY_SV
`define AXI_ERROR_POLICY_SV


`default_nettype none

package axi_error_policy;

  import axi_pkg::*;

  // ---------------------------------------------------------------------
  // Typy chýb (Vyššia abstrakcia pre internú logiku)
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {
    AXI_ERR_NONE    = 2'b00, // Operácia prebehla v poriadku
    AXI_ERR_DECERR  = 2'b01, // Neexistujúca adresa (Address Decode Error)
    AXI_ERR_SLVERR  = 2'b10, // Chyba na strane Slave (napr. nepovolený zápis)
    AXI_ERR_TIMEOUT = 2'b11  // Vypršanie času (Watchdog/Interconnect timeout)
  } axi_error_t;

  // ---------------------------------------------------------------------
  // 32-bit referenčné patterny (Ladenie cez Signal Tap / Simuláciu)
  // ---------------------------------------------------------------------
  // Tieto konštanty sa objavia v RDATA zbernici pri výskyte chyby.
  localparam logic [31:0] PATTERN_DECERR = 32'hDEAD_BEEF;
  localparam logic [31:0] PATTERN_SLVERR = 32'hBAD0_0000;
  localparam logic [31:0] PATTERN_TIMEOUT = 32'hEEEE_EEEE;

  // ---------------------------------------------------------------------
  // Mapovacie funkcie
  // ---------------------------------------------------------------------

  /**
  * @brief Konvertuje interný chybový typ na štandardný AXI_RESP kód.
  * @param err Interný stav chyby typu axi_error_t.
  * @return logic [1:0] Štandardizovaný AXI response (OKAY/SLVERR/DECERR).
  */
  function automatic logic [1:0] to_axi_resp(input axi_error_t err);
    case (err)
      AXI_ERR_NONE:    return AXI_RESP_OKAY;
      AXI_ERR_DECERR:  return AXI_RESP_DECERR;
      AXI_ERR_SLVERR:  return AXI_RESP_SLVERR;
      AXI_ERR_TIMEOUT: return AXI_RESP_SLVERR;  // Timeout sa v AXI hlási ako SLVERR
      default:         return AXI_RESP_DECERR;
    endcase
  endfunction

  /**
     * @brief Vracia dátový pattern prislúchajúci danému typu chyby.
     * @param err Interný stav chyby typu axi_error_t.
     * @return logic [31:0] 32-bitová hodnota pre RDATA zbernicu.
     */
  function automatic logic [31:0] to_error_pattern(input axi_error_t err);
    case (err)
      AXI_ERR_DECERR:  return PATTERN_DECERR;
      AXI_ERR_SLVERR:  return PATTERN_SLVERR;
      AXI_ERR_TIMEOUT: return PATTERN_TIMEOUT;
      default:         return PATTERN_DECERR;
    endcase
  endfunction

endpackage : axi_error_policy

`endif  // AXI_ERROR_POLICY_SV
