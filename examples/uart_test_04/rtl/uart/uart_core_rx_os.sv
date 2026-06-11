/**
 * @file    uart_core_rx_os.sv
 * @brief   UART RX core -- 16x oversampled, majority-vote center sample.
 * @param   DATA_WIDTH  Must be 8 (parameter kept for interface compatibility).
 * @details
 *  16x oversampled variant of uart_core_rx.  Connects to uart_baud_gen running
 *  at 16x baud rate (PRESCALE = CLK_FREQ / (BAUD_RATE * 16)).
 *
 *  Internal 4-bit counter os_cnt_q tracks position within each bit window (0..15).
 *  The baud_gen is phase-aligned on each start bit via rx_start_pulse_o.
 *
 *  START bit:  Falling edge detected via 2-FF synchroniser.
 *              Verified at os_cnt_q==7 (center of bit, ~8 OS ticks after edge).
 *              If rxd==1 at center: false start, return to IDLE (glitch reject).
 *  DATA bits:  Majority vote of samples at os_cnt_q==6, 7, 8.
 *              Bit shifted into shreg_q at os_cnt_q==15 (window end).
 *  PARITY bit: Sampled at os_cnt_q==7 (center).
 *  STOP bit:   Sampled at os_cnt_q==7; frame_err set if rxd==0.
 *
 *  Output interface is identical to uart_core_rx: AXI-Stream held-valid.
 *  Back-to-back frame support identical to uart_core_rx via pending_start_q.
 */

`ifndef UART_CORE_RX_OS_SV
`define UART_CORE_RX_OS_SV

`default_nettype none

import uart_pkg::*;

module uart_core_rx_os #(
  parameter int DATA_WIDTH = 8
)(
  input  wire clk,
  input  wire rstn,

  // UART physical input
  input  wire rxd_i,

  // 16x baud tick from uart_baud_gen (end_tick_o at PRESCALE_OS period)
  input  wire os_tick_i,

  // Configuration
  input  var uart_conf_t cfg_i,

  // AXI-Stream output (held valid/ready)
  output logic [DATA_WIDTH-1:0] data_o,
  output logic                  valid_o,
  input  wire                   ready_i,

  // Status
  output uart_core_status_t status_o,

  // Phase-align pulse to uart_baud_gen.start_i
  output logic rx_start_pulse_o,

  // Clear sticky error flags
  input  wire err_clear_i
);

  initial assert(DATA_WIDTH == 8);

  // ==========================================================================
  // 1. RXD 2-FF synchroniser + falling-edge detect
  // ==========================================================================
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  logic rxd_r0_q;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  logic rxd_r1_q;
  logic rxd_old_q;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      {rxd_r1_q, rxd_r0_q} <= 2'b11;
      rxd_old_q             <= 1'b1;
    end else begin
      {rxd_r1_q, rxd_r0_q} <= {rxd_r0_q, rxd_i};
      rxd_old_q             <= rxd_r1_q;
    end
  end

  wire rxd_sync_w   = rxd_r1_q;
  wire start_edge_w = rxd_old_q && !rxd_r1_q;

  // ==========================================================================
  // 2. OS tick counter (0..15, one per bit window)
  // ==========================================================================
  logic [3:0] os_cnt_q;

  // Pulses: center sample and bit-window end
  wire os_sample_w = os_tick_i && (os_cnt_q == 4'd7);
  wire os_bitend_w = os_tick_i && (os_cnt_q == 4'd15);

  // Pre-center sample ticks for majority vote
  wire os_smpl6_tick_w = os_tick_i && (os_cnt_q == 4'd6);
  wire os_smpl8_tick_w = os_tick_i && (os_cnt_q == 4'd8);

  // ==========================================================================
  // 3. FSM (combinational next state)
  // ==========================================================================
  uart_state_e state_q, state_d;

  logic [DATA_WIDTH-1:0]           shreg_q;
  logic [$clog2(DATA_WIDTH+1)-1:0] bit_cnt_q;
  logic [1:0]                      stop_cnt_q;
  logic                            overrun_err_q, frame_err_q, parity_err_q;
  logic                            stop_sampled_ok_q, pending_start_q;

  // Majority-vote samples for data bits
  logic smpl6_q, smpl7_q, smpl8_q;
  wire  majority_w = (smpl6_q & smpl7_q) | (smpl7_q & smpl8_q) | (smpl6_q & smpl8_q);

  always_comb begin
    state_d = state_q;
    case (state_q)
      UART_IDLE: begin
        if (start_edge_w) state_d = UART_START;
      end
      UART_START: begin
        // False start: rxd still high at center → glitch
        if (os_sample_w && rxd_sync_w) state_d = UART_IDLE;
        if (os_bitend_w)               state_d = UART_DATA;
      end
      UART_DATA: begin
        if (os_bitend_w && bit_cnt_q == 4'd1)
          state_d = (cfg_i.parity == 2'b00) ? UART_STOP : UART_PARITY;
      end
      UART_PARITY: begin
        if (os_bitend_w) state_d = UART_STOP;
      end
      UART_STOP: begin
        if (os_bitend_w && stop_cnt_q == 2'd1)
          state_d = (pending_start_q || start_edge_w) ? UART_START : UART_IDLE;
      end
      default: state_d = UART_IDLE;
    endcase
  end

  // ==========================================================================
  // 4. Phase-align pulse (fired at start-bit detection or back-to-back)
  // ==========================================================================
  always_comb begin
    rx_start_pulse_o =
      (state_q == UART_IDLE && start_edge_w) ||
      (state_q == UART_STOP && os_bitend_w && stop_cnt_q == 2'd1 &&
       (pending_start_q || start_edge_w));
  end

  // ==========================================================================
  // 5. Status
  // ==========================================================================
  always_comb begin
    status_o             = '0;
    status_o.rx_busy     = (state_q != UART_IDLE);
    status_o.overrun_err = overrun_err_q;
    status_o.frame_err   = frame_err_q;
    status_o.parity_err  = parity_err_q;
  end

  // ==========================================================================
  // 6. Data decode from shift register
  // ==========================================================================
  logic [DATA_WIDTH-1:0] rx_data_w;

  always_comb begin
    case (cfg_i.dbits)
      2'b01:   rx_data_w = {1'b0, shreg_q[DATA_WIDTH-1:1]};
      2'b10:   rx_data_w = {2'b0, shreg_q[DATA_WIDTH-1:2]};
      2'b11:   rx_data_w = {3'b0, shreg_q[DATA_WIDTH-1:3]};
      default: rx_data_w = shreg_q;
    endcase
  end

  wire frame_done_w = (state_q == UART_STOP) && os_bitend_w && (stop_cnt_q == 2'd1);

  // ==========================================================================
  // 7. Output holding register (AXI-Stream held-valid)
  // ==========================================================================
  logic [DATA_WIDTH-1:0] rx_hold_q;
  logic                  rx_valid_q;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      rx_hold_q  <= '0;
      rx_valid_q <= 1'b0;
    end else begin
      if (frame_done_w && (!rx_valid_q || ready_i)) begin
        rx_hold_q  <= rx_data_w;
        rx_valid_q <= 1'b1;
      end else if (!frame_done_w && rx_valid_q && ready_i) begin
        rx_valid_q <= 1'b0;
      end
    end
  end

  assign valid_o = rx_valid_q;
  assign data_o  = rx_hold_q;

  // ==========================================================================
  // 8. OS counter, datapath, and error registers
  // ==========================================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_q           <= UART_IDLE;
      os_cnt_q          <= '0;
      shreg_q           <= '0;
      bit_cnt_q         <= '0;
      stop_cnt_q        <= '0;
      smpl6_q           <= 1'b0;
      smpl7_q           <= 1'b0;
      smpl8_q           <= 1'b0;
      overrun_err_q     <= 1'b0;
      frame_err_q       <= 1'b0;
      parity_err_q      <= 1'b0;
      stop_sampled_ok_q <= 1'b0;
      pending_start_q   <= 1'b0;
    end else begin
      state_q <= state_d;

      // OS counter: reset when entering START, increment each OS tick
      if (state_d == UART_START && state_q != UART_START) begin
        os_cnt_q <= '0;
      end else if (state_q != UART_IDLE && os_tick_i) begin
        os_cnt_q <= os_cnt_q + 4'd1;
      end else if (state_q == UART_IDLE) begin
        os_cnt_q <= '0;
      end

      if (err_clear_i)
        {overrun_err_q, frame_err_q, parity_err_q} <= '0;

      if (frame_done_w && rx_valid_q && !ready_i)
        overrun_err_q <= 1'b1;

      case (state_q)
        UART_START: begin
          if (os_sample_w) begin
            stop_cnt_q <= cfg_i.stop2 ? 2'd2 : 2'd1;
            bit_cnt_q  <= dbits_to_int(cfg_i.dbits);
            shreg_q    <= '0;
          end
        end

        UART_DATA: begin
          // Capture majority-vote samples
          if (os_smpl6_tick_w) smpl6_q <= rxd_sync_w;
          if (os_sample_w)     smpl7_q <= rxd_sync_w;
          if (os_smpl8_tick_w) smpl8_q <= rxd_sync_w;
          // Shift in majority-voted bit at window end
          if (os_bitend_w) begin
            shreg_q   <= {majority_w, shreg_q[DATA_WIDTH-1:1]};
            if (bit_cnt_q > 1) bit_cnt_q <= bit_cnt_q - 1'b1;
          end
        end

        UART_PARITY: begin
          if (os_sample_w) begin
            if (rxd_sync_w != calc_parity(rx_data_w, cfg_i))
              parity_err_q <= 1'b1;
          end
        end

        UART_STOP: begin
          if (os_sample_w) begin
            if (!rxd_sync_w) frame_err_q      <= 1'b1;
            else             stop_sampled_ok_q <= 1'b1;
          end
          if (stop_sampled_ok_q && start_edge_w) pending_start_q <= 1'b1;
          if (os_bitend_w) begin
            if (stop_cnt_q > 1) stop_cnt_q <= stop_cnt_q - 1'b1;
            else begin
              stop_sampled_ok_q <= 1'b0;
              pending_start_q   <= 1'b0;
            end
          end
        end

        default: ;
      endcase
    end
  end

endmodule

`default_nettype wire

`endif // UART_CORE_RX_OS_SV
