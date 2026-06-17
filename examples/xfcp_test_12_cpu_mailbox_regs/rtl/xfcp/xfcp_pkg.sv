/**
 * @file    xfcp_pkg.sv
 * @brief   Definicia struktur a opkodov protokolu XFCP v1.3+MEM.
 * @details Paket format (response):
 *            Bajt 0: SOP (0xFD)
 *            Bajt 1: OPCODE
 *            Bajt 2: SEQ
 *            Bajt 3: STATUS (xfcp_status_e)
 *            Bajt 4+: type-specific payload
 *
 *          GET_CAPS (xfcp_test_08 rozsirenie):
 *            Request:  FE 01 seq 00 00 00 00 00 00  (COUNT=0, no payload)
 *            Response: FD 02 seq STATUS [8B caps struct] 00+TLAST
 *
 *          GET_TARGET_INFO (xfcp_test_09 rozsirenie):
 *            Request:  FE 03 seq 00 00 00 00 00 [index]  (COUNT=0, ADDR[7:0]=index)
 *            Response: FD 04 seq STATUS [16B target struct] 00+TLAST
 *
 *          MEM_READ (xfcp_test_10 rozsirenie):
 *            Request:  FE 30 seq 00 COUNT[15:8] COUNT[7:0] ADDR[31:24..0] (no payload)
 *            Response: FD 32 seq STATUS [COUNT bytes data] 00+TLAST
 *
 *          MEM_WRITE (xfcp_test_10 rozsirenie):
 *            Request:  FE 31 seq 00 COUNT[15:8] COUNT[7:0] ADDR[31:24..0] [COUNT bytes]
 *            Response: FD 33 seq STATUS 00+TLAST (no payload)
 *
 *          Target struct (16 bajtov, 4 x 32-bit slova MSB-first):
 *            Byte  0: target_type (0x01=AXIL, 0x02=STREAM, 0x03=MEM)
 *            Byte  1: target_id   (index)
 *            Byte  2: flags       (0x00)
 *            Byte  3: reserved
 *            Byte 4-7: base_addr  (32b big-endian)
 *            Byte 8-9: max_transfer (16b big-endian)
 *            Byte 10:  align
 *            Byte 11:  reserved
 *            Byte 12-15: name     (4 ASCII chars)
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
  //    0x01        GET_CAPS
  //    0x02        RESP_GET_CAPS
  //    0x03        GET_TARGET_INFO
  //    0x04        RESP_GET_TARGET_INFO
  //    0x10/0x11   AXIL READ/WRITE (request)
  //    0x12/0x13   AXIL READ/WRITE (response)
  //    0x20/0x21   STREAM_WRITE/READ (request)
  //    0x22/0x23   STREAM_WRITE/READ (response)
  //    0x30/0x31   MEM_READ/MEM_WRITE (request)
  //    0x32/0x33   RESP_MEM_READ/RESP_MEM_WRITE (response)
  // ========================================================================
  typedef enum logic [7:0] {
    XFCP_OP_ID                    = 8'h00,
    XFCP_OP_GET_CAPS              = 8'h01,
    XFCP_OP_RESP_GET_CAPS         = 8'h02,
    XFCP_OP_GET_TARGET_INFO       = 8'h03,
    XFCP_OP_RESP_GET_TARGET_INFO  = 8'h04,
    XFCP_OP_READ                  = 8'h10,
    XFCP_OP_WRITE                 = 8'h11,
    XFCP_OP_RESP_READ             = 8'h12,
    XFCP_OP_RESP_WRITE            = 8'h13,
    XFCP_OP_STREAM_WRITE          = 8'h20,
    XFCP_OP_STREAM_READ           = 8'h21,
    XFCP_OP_RESP_STREAM_WRITE     = 8'h22,
    XFCP_OP_RESP_STREAM_READ      = 8'h23,
    XFCP_OP_MEM_READ              = 8'h30,
    XFCP_OP_MEM_WRITE             = 8'h31,
    XFCP_OP_RESP_MEM_READ         = 8'h32,
    XFCP_OP_RESP_MEM_WRITE        = 8'h33
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

  // ========================================================================
  // 6. Helper funkcie
  // ========================================================================

  function automatic xfcp_op_e xfcp_resp_for_op(input xfcp_op_e op);
    unique case (op)
      XFCP_OP_GET_CAPS:         return XFCP_OP_RESP_GET_CAPS;
      XFCP_OP_GET_TARGET_INFO:  return XFCP_OP_RESP_GET_TARGET_INFO;
      XFCP_OP_READ:             return XFCP_OP_RESP_READ;
      XFCP_OP_WRITE:            return XFCP_OP_RESP_WRITE;
      XFCP_OP_STREAM_READ:      return XFCP_OP_RESP_STREAM_READ;
      XFCP_OP_STREAM_WRITE:     return XFCP_OP_RESP_STREAM_WRITE;
      XFCP_OP_MEM_READ:         return XFCP_OP_RESP_MEM_READ;
      XFCP_OP_MEM_WRITE:        return XFCP_OP_RESP_MEM_WRITE;
      default:                  return XFCP_OP_RESP_WRITE;
    endcase
  endfunction

  function automatic logic xfcp_op_is_axil(input xfcp_op_e op);
    return (op == XFCP_OP_ID || op == XFCP_OP_READ || op == XFCP_OP_WRITE);
  endfunction

  function automatic logic xfcp_op_is_stream(input xfcp_op_e op);
    return (op == XFCP_OP_STREAM_WRITE || op == XFCP_OP_STREAM_READ);
  endfunction

  function automatic logic xfcp_op_is_caps(input xfcp_op_e op);
    return (op == XFCP_OP_GET_CAPS);
  endfunction

  function automatic logic xfcp_op_is_targets(input xfcp_op_e op);
    return (op == XFCP_OP_GET_TARGET_INFO);
  endfunction

  function automatic logic xfcp_op_is_mem(input xfcp_op_e op);
    return (op == XFCP_OP_MEM_READ || op == XFCP_OP_MEM_WRITE);
  endfunction

  // Vrati 1 ak RESPONSE opcode obsahuje datovy payload (ideme do ST_PAYLOAD).
  function automatic logic xfcp_resp_has_payload(input xfcp_op_e op);
    return (op == XFCP_OP_RESP_READ)
        || (op == XFCP_OP_RESP_STREAM_READ)
        || (op == XFCP_OP_RESP_GET_CAPS)
        || (op == XFCP_OP_RESP_GET_TARGET_INFO)
        || (op == XFCP_OP_RESP_MEM_READ);
  endfunction

endpackage

`endif // XFCP_PKG_SV
