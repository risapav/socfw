/**
 * @version 1.0.0
 * @date    17.2.2026
 * @author  Pavol Risa
 *
 * @file    axis_uart_tx.sv
 * @brief   AXI-Stream UART TX wrapper (Refactored for uart_pkg structures)
 * @details
 * Modul zapúzdruje vysielacie jadro UART a baud generátor.
 * Využíva AXI-Stream Slave rozhranie pre príjem dát na vysielanie.
 */

`ifndef AXIS_UART_TX_SV
`define AXIS_UART_TX_SV

`default_nettype none

import uart_pkg::*;

module axis_uart_tx #(
  parameter int DATA_WIDTH = 8
)(
  // AXI-Stream Slave Interface
  axi4s_if.slave       s_axis,

  // UART Fyzické rozhranie (PHY)
  output logic         txd_o,

  // Timing
  input  wire [15:0]  prescale_i, // clk / baud

  // Konfigurácia (štruktúra z uart_pkg)
  input  var uart_conf_t   cfg_i,

  // Status rozhranie
  output uart_core_status_t status_o,

  // Udalosti (Pulzy)
  output logic         tx_done_pulse_o // 🔴 Pulz generovaný po dokončení vysielania
);

  // --- Interné signály ---
  logic         tx_s_tick, tx_h_tick, tx_e_tick;
  logic         tx_start_pulse;

  uart_core_status_t core_status;

  // Prepojenie statusu smerom von
  assign status_o = core_status;

  // ==========================================================================
  // 1. Baudrate Generátor pre TX
  // ==========================================================================
  uart_baud_gen i_baud_gen (
    .clk          (s_axis.TCLK),
    .rstn         (s_axis.TRESETn),

    // Resetujeme čítač pri 'fire' pulze (nové dáta), aby štart bit začal okamžite
    .start_i      (tx_start_pulse),  // 🔴 TX štart: nabije plnú periódu
    .enable_i     (core_status.tx_busy),  // 🟢 Beží, keď je RX/TX busy

    .prescale_i   (prescale_i),

    .start_tick_o (tx_s_tick),
    .half_tick_o  (tx_h_tick),
    .end_tick_o   (tx_e_tick)
  );

  // ==========================================================================
  // 2. UART Core TX (Nízkoúrovňové jadro)
  // ==========================================================================
  uart_core_tx #(
    .DATA_WIDTH   (DATA_WIDTH)
  ) i_core (
    .clk              (s_axis.TCLK),
    .rstn             (s_axis.TRESETn),

    // Timing
    .start_tick_i     (tx_s_tick),
    .half_tick_i      (tx_h_tick),
    .end_tick_i       (tx_e_tick),

    // Konfigurácia cez štruktúru
    .cfg_i            (cfg_i),

    // Dátové rozhranie (AXI-Stream Slave mapping)
    .data_i           (s_axis.TDATA[DATA_WIDTH-1:0]),
    .valid_i          (s_axis.TVALID),
    .ready_o          (s_axis.TREADY),

    // Fyzický výstup PHY
    .txd_o            (txd_o),

    // Status a Riadenie metronómu
    .status_o         (core_status),
    .tx_start_pulse_o (tx_start_pulse),
    .tx_done_pulse_o  (tx_done_pulse_o)
  );

endmodule

`endif // AXIS_UART_TX_SV
