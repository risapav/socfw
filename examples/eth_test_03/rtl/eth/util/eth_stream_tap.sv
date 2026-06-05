/**
 * @file eth_stream_tap.sv
 * @brief AXI-Stream tap: captures the first CAPTURE_BYTES of each Ethernet frame
 *   via UART 8N1.
 * @details Read-only tap on mac_tdata/mac_tvalid/mac_tlast; never modifies tready.
 *   Bytes are written into an async_fifo (write: eth_rx_clk_i, read: sys_clk_i)
 *   and drained one byte at a time to uart_tx in sys_clk domain. Re-arms on
 *   each tlast, so every frame produces up to CAPTURE_BYTES UART bytes.
 * @param CAPTURE_BYTES  Bytes to capture per frame.
 * @param SYS_CLK_HZ     sys_clk_i frequency for UART baud generation.
 * @param BAUD_RATE      UART baud rate.
 */

`ifndef ETH_STREAM_TAP_SV
`define ETH_STREAM_TAP_SV

`default_nettype none

module eth_stream_tap #(
  parameter int CAPTURE_BYTES = 20,
  parameter int SYS_CLK_HZ   = 50_000_000,
  parameter int BAUD_RATE     = 115200
)(
  input  wire logic       eth_rx_clk_i,
  input  wire logic       sys_clk_i,
  input  wire logic       rst_ni,

  input  wire logic [7:0] s_axis_tdata_i,
  input  wire logic       s_axis_tvalid_i,
  input  wire logic       s_axis_tlast_i,

  output      logic       uart_tx_o
);

  localparam int CNT_W     = $clog2(CAPTURE_BYTES + 1);
  localparam int FIFO_DEPTH = 64;

  // =========================================================================
  // ETH_RX_CLK domain: capture first CAPTURE_BYTES of each frame
  // =========================================================================
  logic            armed_q;
  logic [CNT_W-1:0] cnt_q;
  logic            wr_valid_w;
  logic            wr_ready_w;

  assign wr_valid_w = armed_q && s_axis_tvalid_i;

  always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      armed_q <= 1'b1;
      cnt_q   <= '0;
    end else begin
      if (s_axis_tvalid_i && s_axis_tlast_i) begin
        // End of frame: re-arm for the next frame
        armed_q <= 1'b1;
        cnt_q   <= '0;
      end else if (wr_valid_w && wr_ready_w) begin
        if (cnt_q == CNT_W'(CAPTURE_BYTES - 1))
          armed_q <= 1'b0;
        else
          cnt_q <= cnt_q + CNT_W'(1);
      end
    end
  end

  // =========================================================================
  // Async FIFO: CDC eth_rx_clk -> sys_clk
  // =========================================================================
  logic [7:0] rd_data_w;
  logic       rd_valid_w;
  logic       uart_ready_w;

  async_fifo #(
    .DATA_WIDTH(8),
    .DEPTH     (FIFO_DEPTH)
  ) u_cap_fifo (
    .wr_clk_i  (eth_rx_clk_i),
    .wr_rst_ni (rst_ni),
    .wr_data_i (s_axis_tdata_i),
    .wr_valid_i(wr_valid_w),
    .wr_ready_o(wr_ready_w),
    .rd_clk_i  (sys_clk_i),
    .rd_rst_ni (rst_ni),
    .rd_data_o (rd_data_w),
    .rd_valid_o(rd_valid_w),
    .rd_ready_i(uart_ready_w)
  );

  // =========================================================================
  // SYS_CLK domain: UART drain
  // FIFO is popped whenever uart_tx is idle (ready_o==1). uart_tx latches
  // rd_data_o in the same cycle rd_ready_i fires, before the FIFO advances.
  // =========================================================================
  uart_tx #(
    .CLK_HZ   (SYS_CLK_HZ),
    .BAUD_RATE(BAUD_RATE)
  ) u_uart (
    .clk_i  (sys_clk_i),
    .rst_ni (rst_ni),
    .data_i (rd_data_w),
    .valid_i(rd_valid_w),
    .ready_o(uart_ready_w),
    .tx_o   (uart_tx_o)
  );

endmodule

`endif // ETH_STREAM_TAP_SV
