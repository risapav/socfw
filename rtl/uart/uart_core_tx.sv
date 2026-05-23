/**
 * @version 1.1.0
 * @date    18.2.2026
 * @author  Pavol Risa
 * @file    uart_core_tx_ultra.sv
 * @brief   UART TX core – Ultra-low latency (Mealy outputs)
 *
 * Optimalizácia:
 *  - txd_o reaguje okamžite na fire (štart bit) bez čakania na stavový prechod
 *  - tx_start_pulse_o generované Mealyho štýlom
 *  - Zachovaná kompatibilita s uart_conf_t a uart_status_t
 */

`ifndef UART_CORE_TX_ULTRA_SV
`define UART_CORE_TX_ULTRA_SV

`default_nettype none

import uart_pkg::*;

module uart_core_tx #(
    parameter int DATA_WIDTH = 8
)(
    input  wire           clk,
    input  wire           rstn,

    // Timing
    input  wire           start_tick_i,
    input  wire           half_tick_i,
    input  wire           end_tick_i,

    // Konfigurácia (štruktúra z uart_pkg)
    input  var uart_conf_t     cfg_i,

    // Data interface (AXI-Stream like)
    input  wire [DATA_WIDTH-1:0]    data_i,
    input  wire           valid_i,
    output logic           ready_o,

    // UART fyzické rozhranie (PHY)
    output logic           txd_o,

    // Status interface (štruktúra z uart_pkg)
    output uart_status_t   status_o,

    // Riadenie baud generátora
    output logic           tx_done_pulse_o,
    output logic           tx_start_pulse_o
);

  // ---------------------------------------
  // Assert DATA_WIDTH
  // ---------------------------------------
  initial assert(DATA_WIDTH <= 16);

  // --- Interné stavy ---
  uart_state_e state_q, state_d;

  // Datapath registre
  logic [DATA_WIDTH-1:0] shreg_q;
  logic [$clog2(DATA_WIDTH+1)-1:0] bit_cnt_q;
  logic [1:0] stop_cnt_q;
  logic parity_q;

  // Handshake
  logic fire;
  assign ready_o = (state_q == UART_IDLE);
  assign fire    = valid_i && ready_o;

  // ==========================================================================
  // 1. Status mapping
  // ==========================================================================
  always_comb begin
    status_o = '0;
    status_o.tx_busy = (state_q != UART_IDLE);
  end

  // ==========================================================================
  // 2. FSM – Next state
  // ==========================================================================
  always_comb begin
    state_d = state_q;
    tx_start_pulse_o = 1'b0;
    tx_done_pulse_o  = 1'b0;

    case (state_q)
      UART_IDLE: begin
        if (fire) begin
          tx_start_pulse_o = 1'b1; // okamžitý štart
          state_d = UART_START;
        end
      end

      UART_START: begin
        if (end_tick_i) state_d = UART_DATA;
      end

      UART_DATA: begin
        if (end_tick_i && bit_cnt_q == 4'd1)
          state_d = (cfg_i.parity != 2'b00) ? UART_PARITY : UART_STOP;
      end

      UART_PARITY: begin
        if (end_tick_i) state_d = UART_STOP;
      end

      UART_STOP: begin
        if (end_tick_i && stop_cnt_q == 2'd1) begin
          state_d = UART_IDLE;
          tx_done_pulse_o = 1'b1;
        end
      end

      default: state_d = UART_IDLE;
    endcase
  end

  // ==========================================================================
  // 3. Datapath – sekvenčná logika
  // ==========================================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_q <= UART_IDLE;
      {shreg_q, bit_cnt_q, stop_cnt_q, parity_q} <= '0;
    end else begin
      state_q <= state_d;

      case (state_q)
        UART_IDLE: if (fire) begin
          shreg_q    <= data_i;
          parity_q   <= calc_parity(data_i, cfg_i);
          stop_cnt_q <= cfg_i.stop2 ? 2'd2 : 2'd1;
          bit_cnt_q  <= dbits_to_int(cfg_i.dbits);
        end

        UART_DATA: if (end_tick_i) begin
          shreg_q   <= {1'b0, shreg_q[DATA_WIDTH-1:1]};
          bit_cnt_q <= bit_cnt_q - 1'b1;
        end

        UART_STOP: if (end_tick_i) stop_cnt_q <= stop_cnt_q - 1'b1;

        default: ;
      endcase
    end
  end

  // ==========================================================================
  // 4. Mealyho výstup pre txd_o – okamžitý štart bit
  // ==========================================================================
  always_comb begin
    if (fire) begin
      txd_o = 1'b0; // okamžitý štart bit aj v IDLE stave
    end else begin
      case (state_q)
        UART_START:  txd_o = 1'b0;
        UART_DATA:   txd_o = shreg_q[0];
        UART_PARITY: txd_o = parity_q;
        default:     txd_o = 1'b1;
      endcase
    end
  end

endmodule

`endif // UART_CORE_TX_ULTRA_SV
