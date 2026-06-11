/**
 * @file    uart_axil.sv
 * @brief   AXI-Lite UART peripheral wrapping uart_fifo_os (16x OS RX + FIFO).
 * @param   CLK_FREQ_HZ        System clock in Hz (default 125 MHz).
 * @param   BAUD_RATE          Baud rate (default 115200).
 * @param   STOP2              True for 2 stop bits.
 * @param   PARITY             2'b00=none, 2'b01=odd, 2'b10=even.
 * @param   DBITS              2'b00=8, 2'b01=7, 2'b10=6, 2'b11=5.
 * @param   RX_FIFO_DEPTH      RX FIFO depth in entries (power of 2, default 64).
 * @param   TX_FIFO_DEPTH      TX FIFO depth in entries (power of 2, default 64).
 * @param   RX_FIFO_RAM_STYLE  Quartus RAM style hint for RX FIFO ("logic", "M9K", "AUTO").
 * @param   TX_FIFO_RAM_STYLE  Quartus RAM style hint for TX FIFO ("logic", "M9K", "AUTO").
 * @details
 *  Self-contained AXI-Lite UART peripheral.  All UART parameters are compile-time;
 *  BAUD_DIV and CONF registers are read-only.
 *
 *  Register map (byte offset, all 32-bit):
 *    0x00  RO    ID            0x55415254 ("UART")
 *    0x04  RO    VERSION       0x0001_0400 (major=1, minor=4, patch=0)
 *    0x08  RO    BAUD_DIV_TX   floor(CLK_FREQ_HZ / BAUD_RATE)
 *    0x0C  RO    BAUD_DIV_RX   floor(CLK_FREQ_HZ / (BAUD_RATE * 16))
 *    0x10  RO    CONF          [4]=stop2, [3:2]=parity, [1:0]=dbits
 *    0x14  RO    STATUS        [7]=tx_ready, [6]=rx_valid, [5]=rx_fifo_full,
 *                              [4]=rx_fifo_empty, [3]=tx_fifo_full,
 *                              [2]=tx_fifo_empty, [1]=rx_busy, [0]=tx_busy
 *    0x18  RO    FIFO_LEVEL    [23:12]=rx_level, [11:0]=tx_level
 *    0x1C  RO*   RX_DATA       [8]=valid, [7:0]=data; READ POPS RX FIFO
 *    0x20  WO    TX_DATA       [7:0]=data; write pushes to TX FIFO (drop if full)
 *    0x24  RW    IRQ_ENABLE    [4:0] per-source enable
 *    0x28  W1C   IRQ_STATUS    [4:0] pending; write 1 to clear
 *    0x2C  W1C   ERROR_STATUS  [2]=parity,[1]=frame,[0]=overrun;
 *                              clearing also clears IRQ_STATUS[4:2] and pulses err_clear_i
 *
 *  IRQ_ENABLE / IRQ_STATUS bits:
 *    [4]=overrun_err, [3]=parity_err, [2]=frame_err,
 *    [1]=tx_not_full (level), [0]=rx_not_empty (level)
 *
 *  Error clear sequence:
 *    1. Write ERROR_STATUS (W1C) -- clears error sticky, also clears IRQ_STATUS[4:2],
 *       pulses err_clear_i to UART core.
 *    2. Write IRQ_STATUS[1:0] if level-based bits still need clearing.
 */

`ifndef UART_AXIL_SV
`define UART_AXIL_SV

`default_nettype none

import axi_pkg::*;

module uart_axil #(
  parameter int          CLK_FREQ_HZ       = 125_000_000,
  parameter int          BAUD_RATE         = 115_200,
  parameter bit          STOP2             = 1'b0,
  parameter logic [1:0]  PARITY            = 2'b00,
  parameter logic [1:0]  DBITS             = 2'b00,
  parameter int          RX_FIFO_DEPTH     = 64,
  parameter int          TX_FIFO_DEPTH     = 64,
  parameter string       RX_FIFO_RAM_STYLE = "logic",
  parameter string       TX_FIFO_RAM_STYLE = "logic"
)(
  input  wire clk_i,
  input  wire rst_ni,

  axi4lite_if.slave s_axil,

  input  wire rx_i,
  output wire tx_o,

  output wire irq_o
);

  // Prescalers -- must mirror uart_os.sv (floor for RX, round for TX)
  localparam int PRESCALE_TX    = (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
  localparam int PRESCALE_RX_OS = CLK_FREQ_HZ / (BAUD_RATE * 16);

  // --------------------------------------------------------------------------
  // uart_fifo_os wires
  // --------------------------------------------------------------------------
  wire [7:0] rx_data_w;
  wire       rx_valid_w;
  wire       rx_ready_w;
  wire [7:0] tx_data_w;
  wire       tx_valid_w;
  wire       err_clear_w;
  wire       tx_busy_w,     rx_busy_w;
  wire       tx_fifo_full_w, tx_fifo_empty_w;
  wire       rx_fifo_full_w, rx_fifo_empty_w;
  wire       overrun_err_w,  frame_err_w,  parity_err_w;
  wire [$clog2(TX_FIFO_DEPTH):0] tx_fifo_level_w;
  wire [$clog2(RX_FIFO_DEPTH):0] rx_fifo_level_w;

  uart_fifo_os #(
    .CLK_FREQ_HZ       (CLK_FREQ_HZ),
    .BAUD_RATE         (BAUD_RATE),
    .DATA_WIDTH        (8),
    .STOP2             (STOP2),
    .PARITY            (PARITY),
    .DBITS             (DBITS),
    .RX_FIFO_DEPTH     (RX_FIFO_DEPTH),
    .TX_FIFO_DEPTH     (TX_FIFO_DEPTH),
    .RX_FIFO_RAM_STYLE (RX_FIFO_RAM_STYLE),
    .TX_FIFO_RAM_STYLE (TX_FIFO_RAM_STYLE)
  ) u_uart (
    .clk              (clk_i),
    .rstn             (rst_ni),
    .rx_i             (rx_i),
    .tx_o             (tx_o),
    .tx_data_i        (tx_data_w),
    .tx_valid_i       (tx_valid_w),
    .tx_ready_o       (),
    .rx_data_o        (rx_data_w),
    .rx_valid_o       (rx_valid_w),
    .rx_ready_i       (rx_ready_w),
    .err_clear_i      (err_clear_w),
    .tx_busy_o        (tx_busy_w),
    .rx_busy_o        (rx_busy_w),
    .tx_fifo_level_o  (tx_fifo_level_w),
    .rx_fifo_level_o  (rx_fifo_level_w),
    .tx_fifo_full_o   (tx_fifo_full_w),
    .tx_fifo_empty_o  (tx_fifo_empty_w),
    .rx_fifo_full_o   (rx_fifo_full_w),
    .rx_fifo_empty_o  (rx_fifo_empty_w),
    .rx_fifo_overflow_o  (),
    .tx_fifo_overflow_o  (),
    .rx_fifo_underflow_o (),
    .tx_fifo_underflow_o (),
    .overrun_err_o    (overrun_err_w),
    .frame_err_o      (frame_err_w),
    .parity_err_o     (parity_err_w)
  );

  // --------------------------------------------------------------------------
  // AXI-Lite write path
  // --------------------------------------------------------------------------
  logic        aw_pend_r, w_pend_r, b_valid_r;
  logic [31:0] awaddr_r, wdata_r;
  logic [3:0]  wstrb_r;
  logic [3:0]  wr_idx_w;
  logic        wr_fire_w;

  assign s_axil.AWREADY = ~aw_pend_r;
  assign s_axil.WREADY  = ~w_pend_r;
  assign s_axil.BVALID  = b_valid_r;
  assign s_axil.BRESP   = AXI_RESP_OKAY;

  assign wr_idx_w  = awaddr_r[5:2];
  assign wr_fire_w = aw_pend_r & w_pend_r & ~b_valid_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_pend_r <= 1'b0;
      w_pend_r  <= 1'b0;
      b_valid_r <= 1'b0;
      awaddr_r  <= '0;
      wdata_r   <= '0;
      wstrb_r   <= '0;
    end else begin
      if (s_axil.AWVALID && ~aw_pend_r) begin
        awaddr_r  <= 32'(s_axil.AWADDR);
        aw_pend_r <= 1'b1;
      end
      if (s_axil.WVALID && ~w_pend_r) begin
        wdata_r  <= s_axil.WDATA;
        wstrb_r  <= s_axil.WSTRB;
        w_pend_r <= 1'b1;
      end
      if (wr_fire_w) begin
        aw_pend_r <= 1'b0;
        w_pend_r  <= 1'b0;
        b_valid_r <= 1'b1;
      end
      if (b_valid_r && s_axil.BREADY)
        b_valid_r <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // AXI-Lite read path
  // --------------------------------------------------------------------------
  logic        r_valid_r;
  logic [31:0] rdata_r;
  logic        ar_fire_w;
  logic [3:0]  ar_idx_w;

  assign s_axil.ARREADY = ~r_valid_r;
  assign s_axil.RVALID  = r_valid_r;
  assign s_axil.RDATA   = rdata_r;
  assign s_axil.RRESP   = AXI_RESP_OKAY;

  assign ar_fire_w = s_axil.ARVALID & ~r_valid_r;
  assign ar_idx_w  = s_axil.ARADDR[5:2];

  // --------------------------------------------------------------------------
  // RW / W1C registers (next-state computed combinatorially for clean priority)
  // --------------------------------------------------------------------------
  logic [4:0] irq_enable_q;
  logic [4:0] irq_status_q;
  logic [2:0] error_status_q;

  // IRQ conditions -- level sources re-assert every cycle; error sources sticky
  logic [4:0] irq_cond_w;
  assign irq_cond_w[0] = ~rx_fifo_empty_w;    // rx_not_empty
  assign irq_cond_w[1] = ~tx_fifo_full_w;     // tx_not_full
  assign irq_cond_w[2] = error_status_q[1];   // frame_err sticky
  assign irq_cond_w[3] = error_status_q[2];   // parity_err sticky
  assign irq_cond_w[4] = error_status_q[0];   // overrun_err sticky

  // irq_o: combinatorial from registered state
  assign irq_o = |(irq_enable_q & irq_status_q);

  // TX push: one-cycle pulse on TX_DATA write
  assign tx_valid_w = wr_fire_w & (wr_idx_w == 4'd8);
  assign tx_data_w  = wdata_r[7:0];

  // RX pop: consume FIFO when RX_DATA register is read (if FIFO has data)
  assign rx_ready_w = ar_fire_w & (ar_idx_w == 4'd7) & rx_valid_w;

  // err_clear_i: pulsed when ERROR_STATUS W1C write clears any bit
  assign err_clear_w = wr_fire_w & (wr_idx_w == 4'd11) & |(wdata_r[2:0]);

  // --------------------------------------------------------------------------
  // irq_enable_q (RW)
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      irq_enable_q <= 5'h0;
    else if (wr_fire_w && wr_idx_w == 4'd9 && wstrb_r[0])
      irq_enable_q <= 5'(wdata_r[4:0]);
  end

  // --------------------------------------------------------------------------
  // error_status_q (W1C): HW set by UART errors, SW clear via W1C write
  // err_clear_w fires on the same cycle as the W1C write (wr_fire_w)
  // --------------------------------------------------------------------------
  logic [2:0] error_next_w;
  always_comb begin
    error_next_w    = error_status_q;
    if (overrun_err_w) error_next_w[0] = 1'b1;
    if (frame_err_w)   error_next_w[1] = 1'b1;
    if (parity_err_w)  error_next_w[2] = 1'b1;
    if (wr_fire_w && wr_idx_w == 4'd11)
      error_next_w = error_next_w & ~3'(wdata_r[2:0]);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) error_status_q <= 3'h0;
    else         error_status_q <= error_next_w;
  end

  // --------------------------------------------------------------------------
  // irq_status_q (W1C): OR-set by conditions each cycle, SW clear via W1C write
  // ERROR_STATUS W1C also clears IRQ_STATUS[4:2] (single clear step for errors)
  // --------------------------------------------------------------------------
  logic [4:0] irq_stat_next_w;
  always_comb begin
    irq_stat_next_w = irq_status_q | irq_cond_w;
    if (wr_fire_w && wr_idx_w == 4'd10)
      irq_stat_next_w = irq_stat_next_w & ~5'(wdata_r[4:0]);
    // ERROR_STATUS clear also clears the error IRQ bits
    if (wr_fire_w && wr_idx_w == 4'd11)
      irq_stat_next_w[4:2] = irq_stat_next_w[4:2] & ~3'(wdata_r[2:0]);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) irq_status_q <= 5'h0;
    else         irq_status_q <= irq_stat_next_w;
  end

  // --------------------------------------------------------------------------
  // Read data mux + read response register
  // --------------------------------------------------------------------------
  logic [31:0] status_w;
  logic [31:0] fifo_level_w;

  assign status_w = {24'h0,
    ~tx_fifo_full_w,   // [7] tx_ready
    ~rx_fifo_empty_w,  // [6] rx_valid
    rx_fifo_full_w,    // [5]
    rx_fifo_empty_w,   // [4]
    tx_fifo_full_w,    // [3]
    tx_fifo_empty_w,   // [2]
    rx_busy_w,         // [1]
    tx_busy_w          // [0]
  };

  assign fifo_level_w = {8'h0, 12'(rx_fifo_level_w), 12'(tx_fifo_level_w)};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_valid_r <= 1'b0;
      rdata_r   <= '0;
    end else if (ar_fire_w) begin
      r_valid_r <= 1'b1;
      case (ar_idx_w)
        4'd0:    rdata_r <= 32'h5541_5254;           // ID
        4'd1:    rdata_r <= 32'h0001_0400;           // VERSION
        4'd2:    rdata_r <= 32'(PRESCALE_TX);        // BAUD_DIV_TX
        4'd3:    rdata_r <= 32'(PRESCALE_RX_OS);     // BAUD_DIV_RX
        4'd4:    rdata_r <= {27'h0, STOP2, PARITY, DBITS}; // CONF
        4'd5:    rdata_r <= status_w;                // STATUS
        4'd6:    rdata_r <= fifo_level_w;            // FIFO_LEVEL
        4'd7:    rdata_r <= {23'h0, rx_valid_w, rx_data_w}; // RX_DATA
        4'd8:    rdata_r <= '0;                      // TX_DATA (write-only)
        4'd9:    rdata_r <= {27'h0, irq_enable_q};  // IRQ_ENABLE
        4'd10:   rdata_r <= {27'h0, irq_status_q};  // IRQ_STATUS
        4'd11:   rdata_r <= {29'h0, error_status_q}; // ERROR_STATUS
        default: rdata_r <= '0;
      endcase
    end else if (r_valid_r && s_axil.RREADY) begin
      r_valid_r <= 1'b0;
    end
  end

endmodule

`default_nettype wire

`endif // UART_AXIL_SV
