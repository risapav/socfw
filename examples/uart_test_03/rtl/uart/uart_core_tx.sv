/**
 * @file    uart_core_tx.sv
 * @brief   UART TX core -- registered TXD output (Moore)
 * @param   DATA_WIDTH  Must be 8 (parameter kept for interface compatibility).
 * @details
 *  AXI-Stream-like input: ready_o is high only in UART_IDLE.
 *  fire = valid_i && ready_o -- latches data and starts transmission.
 *
 *  txd_o is a fully registered (Moore) output:
 *    - No combinational glitches on the TX pin.
 *    - The start bit appears one clock after fire.  At 115200 baud / 125 MHz
 *      that is 8 ns, negligible compared to the 8680 ns bit period.
 *
 *  Next-TXD value is computed combinationally from state_d and the
 *  next shift-register value, then registered into txd_q.
 */

`ifndef UART_CORE_TX_SV
`define UART_CORE_TX_SV

`default_nettype none

import uart_pkg::*;

module uart_core_tx #(
  parameter int DATA_WIDTH = 8
)(
  input  wire clk,
  input  wire rstn,

  // Baud timing (from uart_baud_gen)
  input  wire end_tick_i,

  // Configuration
  input  var uart_conf_t cfg_i,

  // AXI-Stream-like input
  input  wire [DATA_WIDTH-1:0] data_i,
  input  wire                  valid_i,
  output logic                 ready_o,

  // UART physical output (registered)
  output logic txd_o,

  // Status
  output uart_status_t status_o,

  // Baud-gen control
  output logic tx_done_pulse_o,
  output logic tx_start_pulse_o
);

  initial assert(DATA_WIDTH == 8);

  // ==========================================================================
  // 1. Handshake
  // ==========================================================================
  uart_state_e state_q, state_d;

  assign ready_o = (state_q == UART_IDLE);

  wire fire_w = valid_i && ready_o;

  // ==========================================================================
  // 2. Status
  // ==========================================================================
  always_comb begin
    status_o         = '0;
    status_o.tx_busy = (state_q != UART_IDLE);
  end

  // ==========================================================================
  // 3. Datapath registers (declared before FSM to avoid forward-reference errors)
  // ==========================================================================
  logic [DATA_WIDTH-1:0]           shreg_q;
  logic [$clog2(DATA_WIDTH+1)-1:0] bit_cnt_q;
  logic [1:0]                      stop_cnt_q;
  logic                            parity_q;

  // ==========================================================================
  // 4. FSM next-state and combinational control pulses
  // ==========================================================================
  always_comb begin
    state_d          = state_q;
    tx_start_pulse_o = 1'b0;
    tx_done_pulse_o  = 1'b0;

    case (state_q)
      UART_IDLE: begin
        if (fire_w) begin
          tx_start_pulse_o = 1'b1;
          state_d          = UART_START;
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
          state_d         = UART_IDLE;
          tx_done_pulse_o = 1'b1;
        end
      end
      default: state_d = UART_IDLE;
    endcase
  end

  // ==========================================================================
  // 5. Datapath register updates
  // ==========================================================================

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_q    <= UART_IDLE;
      shreg_q    <= '0;
      bit_cnt_q  <= '0;
      stop_cnt_q <= '0;
      parity_q   <= 1'b0;
    end else begin
      state_q <= state_d;

      case (state_q)
        UART_IDLE: begin
          if (fire_w) begin
            shreg_q    <= data_i;
            parity_q   <= calc_parity(data_i, cfg_i);
            stop_cnt_q <= cfg_i.stop2 ? 2'd2 : 2'd1;
            bit_cnt_q  <= dbits_to_int(cfg_i.dbits);
          end
        end
        UART_DATA: begin
          if (end_tick_i) begin
            shreg_q   <= {1'b0, shreg_q[DATA_WIDTH-1:1]};
            bit_cnt_q <= bit_cnt_q - 1'b1;
          end
        end
        UART_STOP: begin
          if (end_tick_i) stop_cnt_q <= stop_cnt_q - 1'b1;
        end
        default: ;
      endcase
    end
  end

  // ==========================================================================
  // 6. Registered TXD output (Moore)
  //
  //  shreg_next_w: next value of shift register after this clock edge.
  //    Used to pre-compute the first data bit when entering UART_DATA.
  //
  //  txd_next_w: determined from state_d (next state) and shreg_next_w.
  //    Registered into txd_q.  One clock latency vs Mealy; 8 ns at 125 MHz.
  // ==========================================================================
  logic [DATA_WIDTH-1:0] shreg_next_w;
  logic                  txd_next_w;

  always_comb begin
    shreg_next_w = shreg_q;
    if (state_q == UART_IDLE && fire_w)
      shreg_next_w = data_i;
    else if (state_q == UART_DATA && end_tick_i)
      shreg_next_w = {1'b0, shreg_q[DATA_WIDTH-1:1]};
  end

  always_comb begin
    case (state_d)
      UART_IDLE:   txd_next_w = 1'b1;
      UART_START:  txd_next_w = 1'b0;
      UART_DATA:   txd_next_w = shreg_next_w[0];
      UART_PARITY: txd_next_w = parity_q;
      UART_STOP:   txd_next_w = 1'b1;
      default:     txd_next_w = 1'b1;
    endcase
  end

  logic txd_q;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) txd_q <= 1'b1;
    else       txd_q <= txd_next_w;
  end

  assign txd_o = txd_q;

endmodule

`default_nettype wire

`endif // UART_CORE_TX_SV
