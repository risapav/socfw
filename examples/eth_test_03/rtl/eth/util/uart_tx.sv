/**
 * @file uart_tx.sv
 * @brief Generic UART transmitter, 8N1 format.
 * @details One start bit (0), 8 data bits LSB-first, one stop bit (1).
 *   ready_o is high only in IDLE. Pulse valid_i for one cycle while
 *   ready_o is high to transmit a byte.
 * @param CLK_HZ    Input clock frequency in Hz.
 * @param BAUD_RATE UART baud rate.
 */

`ifndef UART_TX_SV
`define UART_TX_SV

`default_nettype none

module uart_tx #(
  parameter int CLK_HZ    = 50_000_000,
  parameter int BAUD_RATE = 115200
)(
  input  wire logic       clk_i,
  input  wire logic       rst_ni,
  input  wire logic [7:0] data_i,
  input  wire logic       valid_i,
  output      logic       ready_o,
  output      logic       tx_o
);

  localparam int TICKS  = CLK_HZ / BAUD_RATE;
  localparam int TICK_W = $clog2(TICKS + 1);

  typedef enum logic [1:0] {
    ST_IDLE  = 2'd0,
    ST_START = 2'd1,
    ST_DATA  = 2'd2,
    ST_STOP  = 2'd3
  } state_e;

  state_e            state_q;
  logic [TICK_W-1:0] tick_q;
  logic [2:0]        bit_q;
  logic [7:0]        shift_q;

  assign ready_o = (state_q == ST_IDLE);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      tick_q  <= '0;
      bit_q   <= '0;
      shift_q <= '0;
      tx_o    <= 1'b1;
    end else begin
      case (state_q)
        ST_IDLE: begin
          tx_o <= 1'b1;
          if (valid_i) begin
            shift_q <= data_i;
            tick_q  <= '0;
            state_q <= ST_START;
          end
        end

        ST_START: begin
          tx_o <= 1'b0;
          if (tick_q == TICK_W'(TICKS - 1)) begin
            tick_q  <= '0;
            bit_q   <= '0;
            state_q <= ST_DATA;
          end else begin
            tick_q <= tick_q + TICK_W'(1);
          end
        end

        ST_DATA: begin
          tx_o <= shift_q[0];
          if (tick_q == TICK_W'(TICKS - 1)) begin
            tick_q  <= '0;
            shift_q <= {1'b0, shift_q[7:1]};
            if (bit_q == 3'd7) begin
              state_q <= ST_STOP;
            end else begin
              bit_q <= bit_q + 3'd1;
            end
          end else begin
            tick_q <= tick_q + TICK_W'(1);
          end
        end

        ST_STOP: begin
          tx_o <= 1'b1;
          if (tick_q == TICK_W'(TICKS - 1)) begin
            tick_q  <= '0;
            state_q <= ST_IDLE;
          end else begin
            tick_q <= tick_q + TICK_W'(1);
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

endmodule

`endif // UART_TX_SV
