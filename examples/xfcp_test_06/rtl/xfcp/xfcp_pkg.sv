/**
 * @file    xfcp_pkg.sv
 * @brief   Definicia struktur a opkodov protokolu XFCP v0.9+STATUS.
 * @details Pridany xfcp_status_e a xfcp_resp_hdr_t pre STATUS vrstvu.
 *          Paket format (response):
 *            Bajt 0: SOP (0xFD)
 *            Bajt 1: OPCODE
 *            Bajt 2: SEQ
 *            Bajt 3: STATUS (xfcp_status_e)
 *            Bajt 4+: type-specific payload
 */

`ifndef XFCP_PKG_SV
`define XFCP_PKG_SV

package xfcp_pkg;

  // ========================================================================
  // 1. Globalne parametre protokolu
  // ========================================================================
  localparam int XFCP_ADDR_WIDTH  = 32;
  localparam int XFCP_COUNT_WIDTH = 16;

  // ========================================================================
  // 2. Protokolove znacky (SOP)
  // ========================================================================
  localparam logic [7:0] XFCP_SOP_REQ   = 8'hFE;
  localparam logic [7:0] XFCP_SOP_RPATH = 8'hFF;
  localparam logic [7:0] XFCP_SOP_RESP  = 8'hFD;

  // ========================================================================
  // 3. Typy operacii (Opcodes)
  // ========================================================================
  typedef enum logic [7:0] {
    XFCP_OP_ID         = 8'h00,
    XFCP_OP_READ       = 8'h10,
    XFCP_OP_WRITE      = 8'h11,
    XFCP_OP_RESP_READ  = 8'h12,
    XFCP_OP_RESP_WRITE = 8'h13
  } xfcp_op_e;

  // ========================================================================
  // 4. Status kody (v0.9+STATUS)
  // ========================================================================
  typedef enum logic [7:0] {
    XFCP_ST_OK             = 8'h00,
    XFCP_ST_BAD_OPCODE     = 8'h01,
    XFCP_ST_BAD_LENGTH     = 8'h02,
    XFCP_ST_BAD_ADDRESS    = 8'h03,
    XFCP_ST_AXI_SLVERR     = 8'h04,
    XFCP_ST_AXI_DECERR     = 8'h05,
    XFCP_ST_TIMEOUT        = 8'h06,
    XFCP_ST_BUSY           = 8'h07,
    XFCP_ST_OVERFLOW       = 8'h08,
    XFCP_ST_UNSUPPORTED    = 8'h09,
    XFCP_ST_INTERNAL_ERROR = 8'h7F
  } xfcp_status_e;

  // ========================================================================
  // 5. Datove struktury
  // ========================================================================
  typedef struct packed {
    xfcp_op_e                    opcode;
    logic [7:0]                  seq;
    logic [XFCP_ADDR_WIDTH-1:0]  addr;
    logic [XFCP_COUNT_WIDTH-1:0] count;
  } xfcp_req_hdr_t;

  typedef struct packed {
    xfcp_op_e       opcode;
    logic [7:0]     seq;
    xfcp_status_e   status;
    logic [15:0]    count;
  } xfcp_resp_hdr_t;

endpackage

`endif // XFCP_PKG_SV
