/**
 * @version 1.1.0
 * @date    22.5.2026
 * @author  Pavol Risa
 *
 * @file    axis_uart_rx.sv
 * @brief   AXI-Stream UART RX wrapper with output skid register
 * @details
 * Wraps low-level UART RX core and baud generator into AXI-Stream interface.
 * Uses uart_pkg structures for clean configuration.
 * Output skid register prevents byte loss when downstream TREADY=0 during
 * the 1-cycle core_valid pulse (AXI-Stream spec compliance fix).
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
  output uart_core_status_t status_o,

  input  wire         err_clear_i // resetovanie poruch komunikacie
);

  // --- Interné signály ---
  logic         rx_s_tick, rx_h_tick, rx_e_tick;
  logic         rx_start_pulse;

  // prijate data s potvrdenim
  logic         core_valid;
  logic [DATA_WIDTH-1:0]   core_data;

  uart_core_status_t core_status;

  // Prepojenie statusu smerom von
  assign status_o = core_status;

  // Skid register signals (declared here so they can be used in i_core instantiation below)
  logic [DATA_WIDTH-1:0] out_data_q;
  logic                  out_valid_q;
  wire                   skid_ready_w = !out_valid_q || m_axis.TREADY;

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
    .ready_i          (skid_ready_w),

    // Status a Riadenie
    .status_o         (core_status),
    .rx_start_pulse_o (rx_start_pulse),
    .err_clear_i      (err_clear_i)
  );

  // ==========================================================================
  // 3. Output skid register -- holds byte until downstream TREADY=1
  // Prevents byte loss if TREADY=0 during the 1-cycle core_valid pulse.
  // ==========================================================================
  always_ff @(posedge m_axis.TCLK or negedge m_axis.TRESETn) begin
    if (!m_axis.TRESETn) begin
      out_valid_q <= 1'b0;
      out_data_q  <= '0;
    end else if (skid_ready_w) begin
      out_valid_q <= core_valid;
      if (core_valid)
        out_data_q <= core_data;
    end
  end

  // ==========================================================================
  // 4. AXI-Stream Mapping
  // ==========================================================================
  assign m_axis.TVALID = out_valid_q;
  assign m_axis.TDATA  = out_data_q;
  assign m_axis.TKEEP  = '1;
  assign m_axis.TLAST  = AXIS_TLAST;
  assign m_axis.TUSER  = '0;
  assign m_axis.TID    = '0;
  assign m_axis.TDEST  = '0;

endmodule

`endif // AXIS_UART_RX_SV
