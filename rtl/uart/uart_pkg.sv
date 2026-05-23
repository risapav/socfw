/**
 * @file    uart_pkg.sv
 * @brief   UART HW/SW ABI definitions (status, config, errors)
 *
 * @details
 *  - Jediný zdroj pravdy pre UART register ABI
 *  - Použiteľné v:
 *      * UART IP core
 *      * SoC integrácii
 *      * SW header generation
 */

`ifndef UART_PKG_SV
`define UART_PKG_SV

package uart_pkg;

  // ============================================================================
  // STATUS REGISTER BIT POSITIONS
  // ============================================================================
  // NOTE:
  //  - index = bit position
  //  - hodnoty sú pevná súčasť ABI (NEMENIŤ bez bump verzie)

  localparam int ST_TX_BUSY     = 0;
  localparam int ST_RX_BUSY     = 1;
  localparam int ST_OVERRUN_ERR = 2;
  localparam int ST_FRAME_ERR   = 3;
  localparam int ST_PARITY_ERR  = 4;

  localparam int ST_WIDTH       = 32;

  // ============================================================================
  // STATUS REGISTER STRUCT (ABI-safe)
  // ============================================================================
  typedef struct packed {
    logic [ST_WIDTH-6:0]    reserved;       // bits [31:5]
    logic                   parity_err;     // bit 4
    logic                   frame_err;      // bit 3
    logic                   overrun_err;    // bit 2
    logic                   rx_busy;        // bit 1
    logic                   tx_busy;        // bit 0
  } uart_status_t;

  // ============================================================================
  // UART CONFIG REGISTER (CONF)
  // ============================================================================
  typedef struct packed {
    logic [26:0] reserved;    // [31:5]
    logic       stop2;        // [4]
    logic [1:0] parity;       // [3:2]  00: None, 01: Odd, 10: Even
    logic [1:0] dbits;        // [1:0]  00=8,01=7,10=6,11=5
  } uart_conf_t;

  // ============================================================================
  // REGISTER OFFSETS (AXI-Lite)
  // ============================================================================
  localparam logic [7:0] UART_REG_ID      = 8'h00;
  localparam logic [7:0] UART_REG_BAUD    = 8'h04;
  localparam logic [7:0] UART_REG_CONF    = 8'h08;
  localparam logic [7:0] UART_REG_ERRCLR  = 8'h0C;
  localparam logic [7:0] UART_REG_STATUS  = 8'h10;
  localparam logic [7:0] UART_REG_TX_CNT  = 8'h14;
  localparam logic [7:0] UART_REG_RX_CNT  = 8'h18;

  // ----------------------------
  // UART FSM states (RX aj TX)
  // ----------------------------
  typedef enum logic [2:0] {
    UART_IDLE,
    UART_START,
    UART_DATA,
    UART_PARITY,
    UART_STOP,
    UART_POSTSTOP,
    UART_VALIDATE   // RX-only, TX ho nepoužíva
  } uart_state_e;

  // ----------------------------
  // Data bits decode
  // ----------------------------
  function automatic logic [3:0] dbits_to_int(logic [1:0] cfg);
    case (cfg)
      2'b00:   return 8;
      2'b01:   return 7;
      2'b10:   return 6;
      default: return 5;
    endcase
  endfunction

  // ----------------------------
  // Parity calculation
  // ----------------------------
  function automatic logic calc_parity(logic [7:0] data, uart_conf_t cfg);
    logic [7:0] masked_data;
    logic       p;

    // Maskujeme dáta podľa dĺžky slova, aby sme ignorovali "šum" v horných bitoch
    case (cfg.dbits)
      2'b01:   masked_data = data & 8'h7F; // 7 bitov
      2'b10:   masked_data = data & 8'h3F; // 6 bitov
      2'b11:   masked_data = data & 8'h1F; // 5 bitov
      default: masked_data = data;         // 8 bitov
    endcase

    p = ^masked_data; // XOR všetkých relevantných bitov

    // 01: Odd (nepárna) -> p sa invertuje, ak je počet jednotiek párny
    // 10: Even (párna)  -> p ostáva (vráti 1, ak je počet jednotiek nepárny)
    return (cfg.parity == 2'b01) ? ~p : p;
  endfunction

endpackage

`endif // UART_PKG_SV
