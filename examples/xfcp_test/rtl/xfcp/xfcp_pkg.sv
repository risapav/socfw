/**
 * @file    xfcp_pkg.sv
 * @brief   Definícia štruktúr a opkódov protokolu XFCP.
 * @details Tento balík obsahuje všetky zdieľané konštanty, enumerácie a
 * štruktúry potrebné pre komunikáciu cez XFCP-AXIL Bridge.
 */

`ifndef XFCP_PKG_SV
`define XFCP_PKG_SV

package xfcp_pkg;

  // ========================================================================
  // 1. Globálne parametre protokolu
  // ========================================================================
  localparam int XFCP_ADDR_WIDTH  = 32;
  localparam int XFCP_COUNT_WIDTH = 16;

  // ========================================================================
  // 2. Protokolové značky (SOP - Start Of Packet)
  // ========================================================================
  // SOP pre požiadavku (Request)
  localparam logic [7:0] XFCP_SOP_REQ   = 8'hFE;
  // SOP pre odpoveď (Response) alebo smerovanie cesty (Routing Path)
  localparam logic [7:0] XFCP_SOP_RPATH = 8'hFF;

  // SOP pre odpoveď
  localparam logic [7:0] XFCP_SOP_RESP = 8'hFE;

  // ========================================================================
  // 3. Typy operácií (Opcodes)
  // ========================================================================
  typedef enum logic [7:0] {
    XFCP_OP_ID          = 8'h00, // Identifikácia zariadenia
    XFCP_OP_READ   = 8'h10, // AXI-Lite Čítanie
    XFCP_OP_WRITE  = 8'h11, // AXI-Lite Zápis
    XFCP_OP_RESP_READ   = 8'h12, // Odpoveď na čítanie (s payloadom)
    XFCP_OP_RESP_WRITE  = 8'h13  // Odpoveď na zápis (bez payloadu)
  } xfcp_op_e;

  // ========================================================================
  // 4. Dátové štruktúry
  // ========================================================================

  /**
   * @struct xfcp_req_hdr_t
   * @brief  Zabalená štruktúra hlavičky XFCP požiadavky.
   */
  typedef struct packed {
    xfcp_op_e                    opcode;
    logic [XFCP_ADDR_WIDTH-1:0]  addr;
    logic [XFCP_COUNT_WIDTH-1:0] count;
  } xfcp_req_hdr_t;

endpackage

`endif // XFCP_PKG_SV
