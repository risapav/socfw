/**
 * @file rx_uart_debug.sv
 * @brief UART debug tap for eth_rx_mac meta output.
 * @param CLK_HZ  Clock frequency (must match eth_rx_clk_i, default 125 MHz).
 * @param BAUD    UART baud rate (default 115200).
 * @param N_BYTES Bytes per debug record (default 20).
 * @details
 *   On each m_meta_valid_i pulse, captures one 20-byte record and sends it
 *   over UART 8N1.  If a frame arrives while sending, it is silently dropped.
 *
 *   Record layout (all multi-byte fields MSB first):
 *     [0..5]   DST MAC
 *     [6..11]  SRC MAC
 *     [12..13] EtherType
 *     [14]     status: {6'b0, mac_ok, fcs_ok}
 *     [15..19] 0x00 (padding)
 */
`ifndef RX_UART_DEBUG_SV
`define RX_UART_DEBUG_SV

`default_nettype none

module rx_uart_debug #(
  parameter int CLK_HZ  = 125_000_000,
  parameter int BAUD    = 115_200,
  parameter int N_BYTES = 20
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // RX MAC meta (valid/ready from eth_rx_mac, rx_clk domain)
  input  wire logic        m_meta_valid_i,
  input  wire logic [47:0] m_meta_dst_mac_i,
  input  wire logic [47:0] m_meta_src_mac_i,
  input  wire logic [15:0] m_meta_eth_type_i,
  input  wire logic        m_meta_fcs_ok_i,
  input  wire logic        m_meta_mac_ok_i,

  output      logic        uart_tx_o
);

  localparam int IDX_W    = $clog2(N_BYTES);
  localparam int IDX_LAST = N_BYTES - 1;

  // UART TX signals
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

  logic [7:0]        buf_q  [0:N_BYTES-1];
  logic [IDX_W-1:0]  idx_q;
  logic              busy_q;

  assign tx_data_w  = buf_q[idx_q];
  assign tx_valid_w = busy_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      idx_q  <= '0;
      busy_q <= 1'b0;
    end else begin
      if (!busy_q) begin
        if (m_meta_valid_i) begin
          buf_q[0]  <= m_meta_dst_mac_i[47:40];
          buf_q[1]  <= m_meta_dst_mac_i[39:32];
          buf_q[2]  <= m_meta_dst_mac_i[31:24];
          buf_q[3]  <= m_meta_dst_mac_i[23:16];
          buf_q[4]  <= m_meta_dst_mac_i[15:8];
          buf_q[5]  <= m_meta_dst_mac_i[7:0];
          buf_q[6]  <= m_meta_src_mac_i[47:40];
          buf_q[7]  <= m_meta_src_mac_i[39:32];
          buf_q[8]  <= m_meta_src_mac_i[31:24];
          buf_q[9]  <= m_meta_src_mac_i[23:16];
          buf_q[10] <= m_meta_src_mac_i[15:8];
          buf_q[11] <= m_meta_src_mac_i[7:0];
          buf_q[12] <= m_meta_eth_type_i[15:8];
          buf_q[13] <= m_meta_eth_type_i[7:0];
          buf_q[14] <= {6'b0, m_meta_mac_ok_i, m_meta_fcs_ok_i};
          buf_q[15] <= 8'h00;
          buf_q[16] <= 8'h00;
          buf_q[17] <= 8'h00;
          buf_q[18] <= 8'h00;
          buf_q[19] <= 8'h00;
          idx_q     <= '0;
          busy_q    <= 1'b1;
        end
      end else begin
        if (tx_ready_w) begin
          if (idx_q == IDX_W'(IDX_LAST)) begin
            busy_q <= 1'b0;
          end else begin
            idx_q <= idx_q + IDX_W'(1);
          end
        end
      end
    end
  end

endmodule

`endif // RX_UART_DEBUG_SV
