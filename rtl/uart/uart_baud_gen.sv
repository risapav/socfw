/**
 * @file    uart_baud_gen.sv
 * @brief   UART baud generator -- start_tick + half_tick + end_tick
 * @param   PRESCALE_WIDTH  Bit-width of the prescale counter.
 * @details
 *  Generates three tick pulses per bit period:
 *    start_tick_o  -- beginning of bit period
 *    half_tick_o   -- center of bit period (RX sampling point)
 *    end_tick_o    -- end of bit period (state transition)
 *
 *  start_i: phase-align trigger.
 *    TX: assert on fire (IDLE->START), aligns to bit start.
 *    RX: assert on start-bit falling edge, aligns center-sample to bit middle.
 *
 *  After reset all tick outputs are 0.  The first tick fires after one full
 *  period, not immediately, so downstream FSMs see clean behaviour on reset.
 */

`ifndef UART_BAUD_GEN_SV
`define UART_BAUD_GEN_SV

`default_nettype none

module uart_baud_gen #(
  parameter int PRESCALE_WIDTH = 16
)(
  input  wire clk,
  input  wire rstn,

  input  wire start_i,                         // phase-align: reload counter
  input  wire enable_i,                        // run while RX/TX busy

  input  wire [PRESCALE_WIDTH-1:0] prescale_i, // clk / baud

  output logic start_tick_o,
  output logic half_tick_o,
  output logic end_tick_o
);

  localparam int MIN_PRESCALE = 8;

  logic [PRESCALE_WIDTH-1:0] count_q;
  logic [PRESCALE_WIDTH-1:0] half_offset_w;
  logic [PRESCALE_WIDTH-1:0] prescale_safe_w;

  assign prescale_safe_w = (prescale_i < PRESCALE_WIDTH'(MIN_PRESCALE))
                             ? PRESCALE_WIDTH'(MIN_PRESCALE)
                             : prescale_i;

  assign half_offset_w = (prescale_safe_w - PRESCALE_WIDTH'(1)) >> 1;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      count_q      <= '0;
      start_tick_o <= 1'b0;
      half_tick_o  <= 1'b0;
      end_tick_o   <= 1'b0;
    end else begin
      if (start_i) begin
        count_q      <= prescale_safe_w - PRESCALE_WIDTH'(1);
        start_tick_o <= 1'b1;
        half_tick_o  <= 1'b0;
        end_tick_o   <= 1'b0;
      end else if (enable_i) begin
        start_tick_o <= (count_q == '0);
        half_tick_o  <= (count_q == half_offset_w);
        end_tick_o   <= (count_q == PRESCALE_WIDTH'(1));
        count_q      <= (count_q == '0) ? prescale_safe_w - PRESCALE_WIDTH'(1)
                                        : count_q - PRESCALE_WIDTH'(1);
      end else begin
        start_tick_o <= 1'b0;
        half_tick_o  <= 1'b0;
        end_tick_o   <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire

`endif // UART_BAUD_GEN_SV
