/**
 * @file gmii_raw_tap.sv
 * @brief Raw GMII byte tap: captures first N_BYTES after SFD and sends via UART.
 * @param CLK_HZ   Clock frequency in Hz (must match eth_rx_clk_i, default 125 MHz).
 * @param BAUD     UART baud rate (default 115200).
 * @param N_BYTES  Bytes to capture after SFD detection (default 32).
 * @details
 *   Monitors gmii_rx_dv_i and gmii_rxd_i directly (same signals entering eth_rx_mac,
 *   before eth_rx_mac's internal pipeline register).
 *   On SFD (0xD5) detection with RXDV asserted, captures the next N_BYTES data bytes.
 *   If RXDV deasserts before N_BYTES collected (truncated frame), the partial capture
 *   is sent as-is; remaining bytes retain stale values from the previous frame.
 *   Sends the captured record via UART 8N1.
 *   If a second frame arrives while UART is transmitting, it is silently dropped.
 *
 *   Record layout (N_BYTES=32):
 *     [0..5]   DST MAC  (first 6 bytes after SFD)
 *     [6..11]  SRC MAC
 *     [12..13] EtherType
 *     [14..31] payload start / FCS bytes
 */
`ifndef GMII_RAW_TAP_SV
`define GMII_RAW_TAP_SV

`default_nettype none

module gmii_raw_tap #(
  parameter int CLK_HZ  = 125_000_000,
  parameter int BAUD    = 115_200,
  parameter int N_BYTES = 32
) (
  input  wire logic       clk_i,
  input  wire logic       rst_ni,

  // Raw GMII inputs (eth_rx_clk_i domain, directly from PHY — same as eth_rx_mac input)
  input  wire logic       gmii_rx_dv_i,
  input  wire logic [7:0] gmii_rxd_i,

  output      logic       uart_tx_o
);

  localparam int CNT_W = $clog2(N_BYTES);

  typedef enum logic [1:0] {
    ST_WAIT    = 2'd0,
    ST_CAPTURE = 2'd1,
    ST_SEND    = 2'd2
  } state_e;

  state_e              state_q;
  logic [7:0]          buf_q [0:N_BYTES-1];
  logic [CNT_W-1:0]    cap_cnt_q;
  logic [CNT_W-1:0]    snd_cnt_q;

  logic [7:0] tx_data_w;
  logic       tx_valid_w;
  logic       tx_ready_w;

  uart_tx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD)
  ) u_uart_tx (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .data_i  (tx_data_w),
    .valid_i (tx_valid_w),
    .ready_o (tx_ready_w),
    .tx_o    (uart_tx_o)
  );

  assign tx_data_w  = buf_q[snd_cnt_q];
  assign tx_valid_w = (state_q == ST_SEND);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= ST_WAIT;
      cap_cnt_q <= '0;
      snd_cnt_q <= '0;
    end else begin
      case (state_q)

        ST_WAIT: begin
          // Detect SFD (preamble end byte 0xD5) with RXDV asserted
          if (gmii_rx_dv_i && gmii_rxd_i == 8'hD5) begin
            state_q   <= ST_CAPTURE;
            cap_cnt_q <= '0;
          end
        end

        ST_CAPTURE: begin
          if (!gmii_rx_dv_i) begin
            // Frame ended early — send partial capture (remaining bytes are stale)
            state_q   <= ST_SEND;
            snd_cnt_q <= '0;
          end else if (cap_cnt_q == CNT_W'(N_BYTES - 1)) begin
            // Last byte — store and transition to send
            buf_q[cap_cnt_q] <= gmii_rxd_i;
            state_q          <= ST_SEND;
            snd_cnt_q        <= '0;
          end else begin
            buf_q[cap_cnt_q] <= gmii_rxd_i;
            cap_cnt_q        <= cap_cnt_q + CNT_W'(1);
          end
        end

        ST_SEND: begin
          if (tx_ready_w) begin
            if (snd_cnt_q == CNT_W'(N_BYTES - 1)) begin
              state_q <= ST_WAIT;
            end else begin
              snd_cnt_q <= snd_cnt_q + CNT_W'(1);
            end
          end
        end

        default: state_q <= ST_WAIT;

      endcase
    end
  end

endmodule

`endif // GMII_RAW_TAP_SV
