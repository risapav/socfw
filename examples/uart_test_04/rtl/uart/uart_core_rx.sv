/**
 * @file    uart_core_rx.sv
 * @brief   UART RX core -- Moore FSM with true AXI-Stream output
 * @param   DATA_WIDTH  Must be 8 (parameter kept for interface compatibility).
 * @details
 *  Receives a standard UART frame (start + data + optional parity + stop).
 *
 *  Output interface is a proper AXI-Stream source:
 *    valid_o stays high until the consumer asserts ready_i.
 *    data_o  is stable while valid_o is high.
 *  An output holding register absorbs the single-cycle frame-done pulse from
 *  the FSM so the downstream logic never needs to react within one clock.
 *
 *  Overrun: if a new frame completes while the holding register is full (the
 *  previous byte has not been consumed), the new byte is dropped and
 *  overrun_err in status_o is set.  It remains set until err_clear_i.
 *
 *  Back-to-back frames: detected in UART_STOP -- if the line goes low on the
 *  last stop bit, the FSM jumps directly to UART_START.
 */

`ifndef UART_CORE_RX_SV
`define UART_CORE_RX_SV

`default_nettype none

import uart_pkg::*;

module uart_core_rx #(
  parameter int DATA_WIDTH = 8
)(
  input  wire clk,
  input  wire rstn,

  // UART physical input
  input  wire rxd_i,

  // Baud timing (from uart_baud_gen)
  input  wire half_tick_i,
  input  wire end_tick_i,

  // Configuration
  input  var uart_conf_t cfg_i,

  // AXI-Stream output (held valid/ready)
  output logic [DATA_WIDTH-1:0] data_o,
  output logic                  valid_o,
  input  wire                   ready_i,

  // Status
  output uart_status_t status_o,

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

  wire rxd_sync_w    = rxd_r1_q;
  wire start_edge_w  = rxd_old_q && !rxd_r1_q; // falling edge = start bit

  // ==========================================================================
  // 2. FSM
  // ==========================================================================
  uart_state_e state_q, state_d;

  logic [DATA_WIDTH-1:0]           shreg_q;
  logic [$clog2(DATA_WIDTH+1)-1:0] bit_cnt_q;
  logic [1:0]                      stop_cnt_q;
  logic                            overrun_err_q, frame_err_q, parity_err_q;
  // stop_sampled_ok_q: set when a valid (high) stop bit is sampled at half_tick_i
  // pending_start_q:   set when a falling edge arrives after stop_sampled_ok_q,
  //                    but before end_tick_i -- captures early back-to-back start bits
  logic                            stop_sampled_ok_q;
  logic                            pending_start_q;

  always_comb begin
    state_d = state_q;
    case (state_q)
      UART_IDLE: begin
        if (start_edge_w) state_d = UART_START;
      end
      UART_START: begin
        if (half_tick_i && rxd_sync_w) state_d = UART_IDLE; // false start
        if (end_tick_i)                state_d = UART_DATA;
      end
      UART_DATA: begin
        if (end_tick_i && bit_cnt_q == 4'd1)
          state_d = (cfg_i.parity == 2'b00) ? UART_STOP : UART_PARITY;
      end
      UART_PARITY: begin
        if (end_tick_i) state_d = UART_STOP;
      end
      UART_STOP: begin
        if (end_tick_i && stop_cnt_q == 2'd1) begin
          // pending_start_q catches edges that arrived before end_tick_i
          state_d = (pending_start_q || start_edge_w) ? UART_START : UART_IDLE;
        end
      end
      default: state_d = UART_IDLE;
    endcase
  end

  // ==========================================================================
  // 3. Baud-gen phase-align pulse (fired at start of start bit)
  // ==========================================================================
  always_comb begin
    rx_start_pulse_o =
      (state_q == UART_IDLE && start_edge_w) ||
      (state_q == UART_STOP && end_tick_i && stop_cnt_q == 2'd1 &&
       (pending_start_q || start_edge_w));
  end

  // ==========================================================================
  // 4. Status (combinational Moore output)
  // ==========================================================================
  always_comb begin
    status_o             = '0;
    status_o.rx_busy     = (state_q != UART_IDLE);
    status_o.overrun_err = overrun_err_q;
    status_o.frame_err   = frame_err_q;
    status_o.parity_err  = parity_err_q;
  end

  // ==========================================================================
  // 5. Data decode from shift register (combinational)
  // ==========================================================================
  logic [DATA_WIDTH-1:0] rx_data_w;

  always_comb begin
    case (cfg_i.dbits)
      2'b01:   rx_data_w = {1'b0, shreg_q[DATA_WIDTH-1:1]}; // 7-bit
      2'b10:   rx_data_w = {2'b0, shreg_q[DATA_WIDTH-1:2]}; // 6-bit
      2'b11:   rx_data_w = {3'b0, shreg_q[DATA_WIDTH-1:3]}; // 5-bit
      default: rx_data_w = shreg_q;                         // 8-bit
    endcase
  end

  // frame_done_w fires one cycle at the end of the last stop bit
  wire frame_done_w = (state_q == UART_STOP) && end_tick_i && (stop_cnt_q == 2'd1);

  // ==========================================================================
  // 6. Output holding register (true AXI-Stream source)
  // ==========================================================================
  logic [DATA_WIDTH-1:0] rx_hold_q;
  logic                  rx_valid_q;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      rx_hold_q  <= '0;
      rx_valid_q <= 1'b0;
    end else begin
      if (frame_done_w && (!rx_valid_q || ready_i)) begin
        // New byte -- holding register free or being consumed this cycle
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
  // 7. Datapath and error registers
  // ==========================================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_q      <= UART_IDLE;
      shreg_q      <= '0;
      bit_cnt_q    <= '0;
      stop_cnt_q   <= '0;
      overrun_err_q     <= 1'b0;
      frame_err_q       <= 1'b0;
      parity_err_q      <= 1'b0;
      stop_sampled_ok_q <= 1'b0;
      pending_start_q   <= 1'b0;
    end else begin
      state_q <= state_d;

      if (err_clear_i)
        {overrun_err_q, frame_err_q, parity_err_q} <= '0;

      // Overrun: new frame arrived while holding register full
      if (frame_done_w && rx_valid_q && !ready_i)
        overrun_err_q <= 1'b1;

      case (state_q)
        UART_START: begin
          if (half_tick_i) begin
            stop_cnt_q <= cfg_i.stop2 ? 2'd2 : 2'd1;
            bit_cnt_q  <= dbits_to_int(cfg_i.dbits);
            shreg_q    <= '0;
          end
        end

        UART_DATA: begin
          if (half_tick_i) shreg_q <= {rxd_sync_w, shreg_q[DATA_WIDTH-1:1]};
          if (end_tick_i && bit_cnt_q > 1) bit_cnt_q <= bit_cnt_q - 1'b1;
        end

        UART_PARITY: begin
          if (half_tick_i) begin
            if (rxd_sync_w != calc_parity(rx_data_w, cfg_i))
              parity_err_q <= 1'b1;
          end
        end

        UART_STOP: begin
          if (half_tick_i) begin
            if (!rxd_sync_w) frame_err_q      <= 1'b1;
            else             stop_sampled_ok_q <= 1'b1;
          end
          // Capture early back-to-back start edge (before end_tick_i)
          if (stop_sampled_ok_q && start_edge_w) pending_start_q <= 1'b1;
          if (end_tick_i) begin
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

`endif // UART_CORE_RX_SV
