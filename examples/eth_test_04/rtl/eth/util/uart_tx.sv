/**
 * @file uart_tx.sv
 * @brief 8N1 UART transmitter, LSB-first, idle-high, shift-register based.
 * @param CLK_HZ  Input clock frequency in Hz.
 * @param BAUD    UART baud rate.
 * @details
 *   BAUD_DIV = CLK_HZ / BAUD clock cycles per bit period.
 *   Frame format: start(0) | data[0..7] | stop(1), 10 bit periods total.
 *   ready_o is asserted while idle; deasserts for 10 bit periods after load.
 *   Handshake: valid_i && ready_o loads the byte and begins transmission.
 */
`ifndef UART_TX_SV
`define UART_TX_SV

`default_nettype none

module uart_tx #(
  parameter int CLK_HZ = 125_000_000,
  parameter int BAUD   = 115_200
) (
  input  wire logic       clk_i,
  input  wire logic       rst_ni,
  input  wire logic [7:0] data_i,
  input  wire logic       valid_i,
  output      logic       ready_o,
  output      logic       tx_o
);

  localparam int BAUD_DIV = CLK_HZ / BAUD;
  localparam int CNT_W    = $clog2(BAUD_DIV);

  logic [CNT_W-1:0] baud_cnt_q;
  logic [9:0]       shift_q;    // {stop, data[7:0], start}; shift right each bit period
  logic [3:0]       bit_cnt_q;  // 0..9 (10 bits per 8N1 frame)
  logic             busy_q;

  assign ready_o = !busy_q;
  assign tx_o    = busy_q ? shift_q[0] : 1'b1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      baud_cnt_q <= '0;
      shift_q    <= '1;
      bit_cnt_q  <= 4'd0;
      busy_q     <= 1'b0;
    end else begin
      if (!busy_q) begin
        if (valid_i) begin
          shift_q    <= {1'b1, data_i, 1'b0};
          bit_cnt_q  <= 4'd0;
          baud_cnt_q <= '0;
          busy_q     <= 1'b1;
        end
      end else begin
        if (baud_cnt_q == CNT_W'(BAUD_DIV - 1)) begin
          baud_cnt_q <= '0;
          if (bit_cnt_q == 4'd9) begin
            busy_q <= 1'b0;
          end else begin
            shift_q   <= {1'b1, shift_q[9:1]};
            bit_cnt_q <= bit_cnt_q + 4'd1;
          end
        end else begin
          baud_cnt_q <= baud_cnt_q + 1;
        end
      end
    end
  end

endmodule

`endif // UART_TX_SV
