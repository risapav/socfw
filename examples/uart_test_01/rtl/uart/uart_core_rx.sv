/**
 * @version 1.1.0
 * @date    18.2.2026
 * @author  Pavol Risa
 *
 * @file    uart_core_rx.sv
 * @brief   UART RX core – Moore FSM optimized for minimal latency using refactored uart_pkg
 */

`ifndef UART_CORE_RX_SV
`define UART_CORE_RX_SV

`default_nettype none

import uart_pkg::*;

module uart_core_rx #(
  parameter int DATA_WIDTH = 8
)(
  input  wire           clk,
  input  wire           rstn,

  // UART phy
  input  wire           rxd_i,

  // Timing
  input  wire           start_tick_i,
  input  wire           half_tick_i,
  input  wire           end_tick_i,

  // Konfigurácia
  input  var uart_conf_t    cfg_i,

  // Data interface
  output logic [DATA_WIDTH-1:0] data_o,
  output logic          valid_o,
  input  wire           ready_i,

  // Status interface
  output uart_status_t   status_o,

  // Riadenie
  output logic           rx_start_pulse_o,
  input  wire            err_clear_i
);
  initial begin
    assert(DATA_WIDTH <= 16);
  end

  // ==========================================================================
  // 1. Interné signály a registre
  // ==========================================================================
  uart_state_e state_q, state_d;

  logic [DATA_WIDTH-1:0] shreg_q;               // posuvný register pre data
  logic [$clog2(DATA_WIDTH+1)-1:0] bit_cnt_q;   // počet data bitov
  logic [1:0] stop_cnt_q;                        // počet stop bitov

  logic overrun_err_q, frame_err_q, parity_err_q;

  // Synchronizácia a detekcia hrany
  logic rxd_sync;
  logic rxd_reg_0, rxd_reg_1, rxd_old_q;
  logic start_edge;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      {rxd_reg_1, rxd_reg_0} <= 2'b11;
      rxd_old_q <= 1'b1;
    end else begin
      {rxd_reg_1, rxd_reg_0} <= {rxd_reg_0, rxd_i};
      rxd_old_q <= rxd_reg_1;
    end
  end

  assign rxd_sync   = rxd_reg_1;
  assign start_edge = (rxd_old_q && !rxd_sync);

  // ==========================================================================
  // 2. Moore Status Mapping
  // ==========================================================================
  always_comb begin
    status_o             = '0;
    status_o.rx_busy     = (state_q != UART_IDLE);
    status_o.overrun_err = overrun_err_q;
    status_o.frame_err   = frame_err_q;
    status_o.parity_err  = parity_err_q;
  end

  // ==========================================================================
  // 3. FSM: Next State Logic – minimal latency
  // ==========================================================================
  always_comb begin
    state_d = state_q;
    case (state_q)
      UART_IDLE:  if (start_edge) state_d = UART_START;
      UART_START: begin
        if (half_tick_i && rxd_sync) state_d = UART_IDLE; // false start
        if (end_tick_i)              state_d = UART_DATA;
      end
      UART_DATA:  if (end_tick_i && bit_cnt_q == 4'd1)
                     state_d = (cfg_i.parity == 2'b00) ? UART_STOP : UART_PARITY;
      UART_PARITY: if (end_tick_i) state_d = UART_STOP;
      UART_STOP:  if (end_tick_i && stop_cnt_q == 2'd1) state_d = UART_IDLE;
      default:    state_d = UART_IDLE;
    endcase
  end

  // ==========================================================================
  // 4. Kombinačné výstupy – zero latency
  // ==========================================================================
  always_comb begin
    rx_start_pulse_o = (state_q == UART_IDLE) && start_edge;

    // VALID sa aktivuje presne po poslednom stop bite
    valid_o = (state_q == UART_STOP) && end_tick_i && (stop_cnt_q == 2'd1);

    // Dáta sú dostupné priamo zo shift registra
    case (cfg_i.dbits)
      2'b01:   data_o = {1'b0, shreg_q[DATA_WIDTH-1:1]}; // 7-bit
      2'b10:   data_o = {2'b0, shreg_q[DATA_WIDTH-1:2]}; // 6-bit
      2'b11:   data_o = {3'b0, shreg_q[DATA_WIDTH-1:3]}; // 5-bit
      default: data_o = shreg_q;                         // 8-bit
    endcase
  end

  // ==========================================================================
  // 5. Datapath – sekvenčná logika
  // ==========================================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_q <= UART_IDLE;
      {shreg_q, bit_cnt_q, stop_cnt_q} <= '0;
      {overrun_err_q, frame_err_q, parity_err_q} <= '0;
    end else begin
      state_q <= state_d;

      if (err_clear_i)
        {overrun_err_q, frame_err_q, parity_err_q} <= '0;

      // Overrun check
      if (valid_o && !ready_i) overrun_err_q <= 1'b1;

      case (state_q)
        UART_START: begin
          if (half_tick_i) begin
            stop_cnt_q <= cfg_i.stop2 ? 2'd2 : 2'd1;
            bit_cnt_q  <= dbits_to_int(cfg_i.dbits);
            shreg_q    <= '0;
          end
        end

        UART_DATA: begin
          if (half_tick_i) shreg_q <= {rxd_sync, shreg_q[DATA_WIDTH-1:1]};
          if (end_tick_i && bit_cnt_q > 1) bit_cnt_q <= bit_cnt_q - 1'b1;
        end

        UART_PARITY: begin
          if (half_tick_i) begin
            // Výpočet parity
            if (rxd_sync != calc_parity(data_o, cfg_i))
              parity_err_q <= 1'b1;
          end
        end

        UART_STOP: begin
          if (half_tick_i && !rxd_sync) frame_err_q <= 1'b1;
          if (end_tick_i && stop_cnt_q > 1) stop_cnt_q <= stop_cnt_q - 1'b1;
        end

        default: ;
      endcase
    end
  end

endmodule

`endif // UART_CORE_RX_SV
