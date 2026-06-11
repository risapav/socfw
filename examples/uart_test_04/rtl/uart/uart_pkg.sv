/**
 * @file    uart_pkg.sv
 * @brief   UART ABI definitions: register map, IRQ/ERROR bit indices, status types.
 *
 * @details
 *  Single source of truth for UART register ABI.
 *  Used by: uart_axil, uart core modules, SoC integration, SW header generation.
 *
 *  Register map (uart_axil, AXI-Lite slave):
 *    0x00  RO    ID            0x55415254 ("UART")
 *    0x04  RO    VERSION       0x0001_0500 (major=1, minor=5, patch=0)
 *    0x08  RO    BAUD_DIV_TX   floor(CLK / BAUD)
 *    0x0C  RO    BAUD_DIV_RX   floor(CLK / (BAUD * 16))
 *    0x10  RO    CONF          [4]=stop2, [3:2]=parity, [1:0]=dbits
 *    0x14  RO    STATUS        see UART_STATUS_* bit indices
 *    0x18  RO    FIFO_LEVEL    [23:12]=rx_level, [11:0]=tx_level
 *    0x1C  RO*   RX_DATA       [8]=valid, [7:0]=data; READ POPS RX FIFO
 *    0x20  WO    TX_DATA       [7:0]=data; sets ERROR_STATUS[3] if TX FIFO full
 *    0x24  RW    IRQ_ENABLE    [5:0] see UART_IRQ_* bit indices
 *    0x28  W1C   IRQ_STATUS    [5:0] see UART_IRQ_* bit indices
 *    0x2C  W1C   ERROR_STATUS  [3:0] see UART_ERR_* bit indices;
 *                              W1C also clears the corresponding IRQ_STATUS bit
 */

`ifndef UART_PKG_SV
`define UART_PKG_SV

package uart_pkg;

  // ============================================================================
  // UART CORE STATUS -- used by uart_core_tx/rx, uart_os, uart, uart_fifo_os
  // (NOT the same as the uart_axil STATUS register at 0x14)
  // ============================================================================
  typedef struct packed {
    logic [26:0] reserved;
    logic        parity_err;   // bit 4
    logic        frame_err;    // bit 3
    logic        overrun_err;  // bit 2
    logic        rx_busy;      // bit 1
    logic        tx_busy;      // bit 0
  } uart_core_status_t;

  // ============================================================================
  // UART CONF REGISTER struct
  // ============================================================================
  typedef struct packed {
    logic [26:0] reserved;    // [31:5]
    logic        stop2;       // [4]
    logic [1:0]  parity;      // [3:2]  00: None, 01: Odd, 10: Even
    logic [1:0]  dbits;       // [1:0]  00=8, 01=7, 10=6, 11=5
  } uart_conf_t;

  // ============================================================================
  // AXI-LITE REGISTER OFFSETS (uart_axil.sv)
  //   Single source of truth. DO NOT CHANGE without version bump.
  // ============================================================================
  localparam logic [7:0] UART_REG_ID           = 8'h00;
  localparam logic [7:0] UART_REG_VERSION      = 8'h04;
  localparam logic [7:0] UART_REG_BAUD_DIV_TX  = 8'h08;
  localparam logic [7:0] UART_REG_BAUD_DIV_RX  = 8'h0C;
  localparam logic [7:0] UART_REG_CONF         = 8'h10;
  localparam logic [7:0] UART_REG_STATUS       = 8'h14;
  localparam logic [7:0] UART_REG_FIFO_LEVEL   = 8'h18;
  localparam logic [7:0] UART_REG_RX_DATA      = 8'h1C;
  localparam logic [7:0] UART_REG_TX_DATA      = 8'h20;
  localparam logic [7:0] UART_REG_IRQ_ENABLE   = 8'h24;
  localparam logic [7:0] UART_REG_IRQ_STATUS   = 8'h28;
  localparam logic [7:0] UART_REG_ERROR_STATUS = 8'h2C;

  // ============================================================================
  // STATUS REGISTER BIT INDICES (UART_REG_STATUS, 0x14)
  // ============================================================================
  localparam int UART_STATUS_TX_BUSY        = 0;
  localparam int UART_STATUS_RX_BUSY        = 1;
  localparam int UART_STATUS_TX_FIFO_EMPTY  = 2;
  localparam int UART_STATUS_TX_FIFO_FULL   = 3;
  localparam int UART_STATUS_RX_FIFO_EMPTY  = 4;
  localparam int UART_STATUS_RX_FIFO_FULL   = 5;
  localparam int UART_STATUS_RX_VALID       = 6;  // RX FIFO non-empty
  localparam int UART_STATUS_TX_READY       = 7;  // TX FIFO not full

  // ============================================================================
  // IRQ BIT INDICES (UART_REG_IRQ_ENABLE / IRQ_STATUS, 0x24 / 0x28)
  //   [0] and [1] are level-latched: they re-assert after W1C if condition persists.
  //   [2..5] are sticky: cleared by W1C only (ERROR_STATUS W1C cascades to [2..5]).
  // ============================================================================
  localparam int UART_IRQ_RX_NOT_EMPTY       = 0;  // level: RX FIFO non-empty
  localparam int UART_IRQ_TX_NOT_FULL        = 1;  // level: TX FIFO not full
  localparam int UART_IRQ_FRAME_ERR          = 2;  // sticky: frame error
  localparam int UART_IRQ_PARITY_ERR         = 3;  // sticky: parity error
  localparam int UART_IRQ_OVERRUN_ERR        = 4;  // sticky: RX overrun
  localparam int UART_IRQ_TX_WRITE_WHEN_FULL = 5;  // sticky: TX write dropped (FIFO full)

  // ============================================================================
  // ERROR_STATUS BIT INDICES (UART_REG_ERROR_STATUS, 0x2C, W1C)
  //   Clearing ERROR[n] also clears the corresponding IRQ_STATUS bit.
  // ============================================================================
  localparam int UART_ERR_OVERRUN       = 0;  // -> IRQ[4]
  localparam int UART_ERR_FRAME         = 1;  // -> IRQ[2]
  localparam int UART_ERR_PARITY        = 2;  // -> IRQ[3]
  localparam int UART_ERR_TX_WRITE_FULL = 3;  // -> IRQ[5]

  // ============================================================================
  // uart_axil STATUS register struct (UART_REG_STATUS, 0x14)
  // ============================================================================
  typedef struct packed {
    logic [23:0] reserved;
    logic        tx_ready;        // [7] TX FIFO not full
    logic        rx_valid;        // [6] RX FIFO non-empty
    logic        rx_fifo_full;    // [5]
    logic        rx_fifo_empty;   // [4]
    logic        tx_fifo_full;    // [3]
    logic        tx_fifo_empty;   // [2]
    logic        rx_busy;         // [1]
    logic        tx_busy;         // [0]
  } uart_axil_status_t;

  // ============================================================================
  // UART FSM states (shared by TX and RX cores)
  // ============================================================================
  typedef enum logic [2:0] {
    UART_IDLE,
    UART_START,
    UART_DATA,
    UART_PARITY,
    UART_STOP
  } uart_state_e;

  // ============================================================================
  // Helper: decode DBITS config to integer word length
  // ============================================================================
  function automatic logic [3:0] dbits_to_int(logic [1:0] cfg);
    case (cfg)
      2'b00:   return 8;
      2'b01:   return 7;
      2'b10:   return 6;
      default: return 5;
    endcase
  endfunction

  // ============================================================================
  // Helper: compute parity bit for given data and config
  // ============================================================================
  function automatic logic calc_parity(logic [7:0] data, uart_conf_t cfg);
    logic [7:0] masked_data;
    logic       p;

    case (cfg.dbits)
      2'b01:   masked_data = data & 8'h7F;
      2'b10:   masked_data = data & 8'h3F;
      2'b11:   masked_data = data & 8'h1F;
      default: masked_data = data;
    endcase

    p = ^masked_data;
    return (cfg.parity == 2'b01) ? ~p : p;
  endfunction

endpackage

`endif // UART_PKG_SV
