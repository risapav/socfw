/**
 * @version 1.0.0
 * @date    17.2.2026
 * @author  Pavol Risa
 *
 * @file    axis_uart_rx.sv
 * @brief   AXI-Stream UART RX wrapper (Refactored for uart_pkg structures)
 * @details
 * Tento modul obaľuje nízkoúrovňové UART RX jadro a baud generátor do
 * AXI-Stream rozhrania. Využíva štruktúry z uart_pkg pre čistú konfiguráciu.
 */

`ifndef AXIS_UART_RX_SV
`define AXIS_UART_RX_SV

`default_nettype none

import uart_pkg::*;

module axis_uart_rx #(
  parameter int DATA_WIDTH  = 8,
  parameter bit AXIS_TLAST  = 1'b1  // 1 = assert TLAST on every byte; 0 = streaming (no TLAST)
)(
  // AXI-Stream Master Interface
  axi4s_if.master      m_axis,

  // UART Fyzické rozhranie (vstup z filtra/synchronizátora)
  input  wire         rxd_i,

  // Timing
  input  wire [15:0]  prescale_i, // clk / baud

  // Konfigurácia (štruktúra z uart_pkg)
  input  var uart_conf_t   cfg_i,

  // Status rozhranie
  output uart_status_t status_o,

  input  wire         err_clear_i // resetovanie poruch komunikacie
);

  // --- Interné signály ---
  logic         rx_s_tick, rx_h_tick, rx_e_tick;
  logic         rx_start_pulse;

  // prijate data s potvrdenim
  logic         core_valid;
  logic [DATA_WIDTH-1:0]   core_data;

  uart_status_t core_status;

  // Prepojenie statusu smerom von
  assign status_o = core_status;

  // ==========================================================================
  // 1. Baudrate Generátor pre RX
  // ==========================================================================
  uart_baud_gen i_baud_gen (
    .clk          (m_axis.TCLK),
    .rstn         (m_axis.TRESETn),

    // Resetujeme čítač pri detekcii hrany štart bitu pre presné fázovanie
    .start_i      (rx_start_pulse),  // 🔵 RX štart: nabije polovicu (Phase Sync)
    .enable_i     (core_status.rx_busy),    // 🟢 Beží, keď je RX/TX busy

    .prescale_i   (prescale_i),

    .start_tick_o (rx_s_tick),
    .half_tick_o  (rx_h_tick),
    .end_tick_o   (rx_e_tick)
  );

  // ==========================================================================
  // 2. UART Core RX (Nízkoúrovňové jadro)
  // ==========================================================================
  uart_core_rx #(
    .DATA_WIDTH   (DATA_WIDTH)
  ) i_core (
    .clk              (m_axis.TCLK),
    .rstn             (m_axis.TRESETn),

    // Fyzický vstup PHY
    .rxd_i            (rxd_i),

    // Timing
    .start_tick_i     (rx_s_tick),
    .half_tick_i      (rx_h_tick),
    .end_tick_i       (rx_e_tick),

    // Konfigurácia cez štruktúru
    .cfg_i            (cfg_i),

    // Dátové rozhranie
    .data_o           (core_data),
    .valid_o          (core_valid),
    .ready_i          (m_axis.TREADY),

    // Status a Riadenie
    .status_o         (core_status),
    .rx_start_pulse_o (rx_start_pulse),
    .err_clear_i      (err_clear_i)
  );

  // ==========================================================================
  // 3. AXI-Stream Mapping
  // ==========================================================================
  assign m_axis.TVALID = core_valid;
  assign m_axis.TDATA  = core_data;
  assign m_axis.TKEEP  = '1;          // Všetky bajty sú platné
  assign m_axis.TLAST  = AXIS_TLAST;  // 1 = per-byte TLAST; 0 = streaming (XFCP over UART)
  assign m_axis.TUSER  = '0;
  assign m_axis.TID    = '0;
  assign m_axis.TDEST  = '0;

endmodule

`endif // AXIS_UART_RX_SV
