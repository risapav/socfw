/**
 * @file  axil_uart_adapter.sv
 * @brief AXI-Lite UART diagnostic adapter (UART).
 * @param BAUD_DIV_DEFAULT  Reset value for the BAUD_DIV register (default 434 = 50 MHz/115200).
 * @details
 *   Register map (byte offset, all 32-bit):
 *     0x00  RO    COMPONENT_ID  -- constant 0x55415254 ("UART")
 *     0x04  RW    BAUD_DIV      -- baud rate prescaler; reset = BAUD_DIV_DEFAULT
 *     0x08  RW    CONFIG        -- [1:0]=data_bits(00=8b), [2]=parity_en, [3]=parity_odd, [4]=stop2
 *     0x0C  PULSE ERR_CLR       -- [0]=clear sticky error flags and assert err_clr_o
 *     0x10  RO    STATUS        -- [0]=tx_busy, [1]=rx_busy, [2]=overrun, [3]=frame, [4]=parity
 *     0x14  RO    TX_FIFO_CNT   -- tx_fifo_cnt_i pass-through
 *     0x18  RO    RX_FIFO_CNT   -- rx_fifo_cnt_i pass-through
 *
 *   Error bits [4:2] in STATUS are sticky: set by one-cycle pulses on the
 *   corresponding _err_i ports, cleared by writing ERR_CLR[0]=1 (one cycle after
 *   the AXI write completes -- PULSE register update latency).
 *   err_clr_o is asserted for the same one cycle so the downstream UART can
 *   clear its own error state.
 *
 *   baud_div_o and config_o are driven from the RW registers; the caller is
 *   responsible for wiring them to the baud generator and UART configuration.
 */
`ifndef AXIL_UART_ADAPTER_SV
`define AXIL_UART_ADAPTER_SV

`default_nettype none

module axil_uart_adapter #(
  parameter int BAUD_DIV_DEFAULT = 434 // 50 MHz / 115200
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  axi4lite_if.slave   s_axil,
  // Status inputs from UART
  input  logic        tx_busy_i,
  input  logic        rx_busy_i,
  input  logic        overrun_err_i,
  input  logic        frame_err_i,
  input  logic        parity_err_i,
  input  logic [7:0]  tx_fifo_cnt_i,
  input  logic [7:0]  rx_fifo_cnt_i,
  // Configuration outputs
  output logic [31:0] baud_div_o,
  output logic [4:0]  config_o,
  output logic        err_clr_o
);

  import axi_pkg::*;

  localparam int NUM_REGS = 7;

  // reg0=RO, reg1=RW, reg2=RW, reg3=PULSE, reg4=RO, reg5=RO, reg6=RO
  localparam [NUM_REGS*2-1:0] REG_TYPES =
    {2'(AXIL_RO), 2'(AXIL_RO), 2'(AXIL_RO), 2'(AXIL_PULSE),
     2'(AXIL_RW), 2'(AXIL_RW), 2'(AXIL_RO)};

  // BAUD_DIV reset value packed into reg1's slot [63:32]
  localparam logic [31:0]           BAUD_RESET = 32'(BAUD_DIV_DEFAULT);
  localparam [NUM_REGS*32-1:0] RESET_VALS =
    {32'h0, 32'h0, 32'h0, 32'h0, 32'h0, BAUD_RESET, 32'h0};

  // --------------------------------------------------------------------------
  // Sticky error bits: set by pulses, cleared by ERR_CLR write
  // --------------------------------------------------------------------------
  logic overrun_r, frame_r, parity_r;

  // --------------------------------------------------------------------------
  // Register file interface
  // --------------------------------------------------------------------------
  logic [NUM_REGS*32-1:0] hw_rdata_w;
  logic [NUM_REGS*32-1:0] hw_wdata_w;
  logic [NUM_REGS-1:0]    hw_we_w;

  assign hw_rdata_w[31:0]    = 32'h5541_5254; // "UART"
  assign hw_rdata_w[63:32]   = 32'h0;          // BAUD_DIV: RW, hw_rdata_i ignored
  assign hw_rdata_w[95:64]   = 32'h0;          // CONFIG:   RW, hw_rdata_i ignored
  assign hw_rdata_w[127:96]  = 32'h0;          // ERR_CLR:  PULSE, hw_rdata_i ignored
  assign hw_rdata_w[159:128] = {27'h0, parity_r, frame_r, overrun_r, rx_busy_i, tx_busy_i};
  assign hw_rdata_w[191:160] = {24'h0, tx_fifo_cnt_i};
  assign hw_rdata_w[223:192] = {24'h0, rx_fifo_cnt_i};

  axil_regfile #(
    .NUM_REGS  (NUM_REGS),
    .REG_TYPES (REG_TYPES),
    .RESET_VALS(RESET_VALS)
  ) u_regfile (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .s_axil     (s_axil),
    .hw_rdata_i (hw_rdata_w),
    .hw_wdata_o (hw_wdata_w),
    .hw_we_o    (hw_we_w)
  );

  // --------------------------------------------------------------------------
  // ERR_CLR decode: 1-cycle delay matches PULSE register FF update latency
  // --------------------------------------------------------------------------
  logic errclr_we_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) errclr_we_r <= 1'b0;
    else         errclr_we_r <= hw_we_w[3];
  end

  assign err_clr_o = errclr_we_r & hw_wdata_w[3*32 + 0]; // ERR_CLR[0]

  // --------------------------------------------------------------------------
  // Sticky error accumulation: OR-set from pulses, synchronously cleared
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      overrun_r <= 1'b0;
      frame_r   <= 1'b0;
      parity_r  <= 1'b0;
    end else if (err_clr_o) begin
      overrun_r <= 1'b0;
      frame_r   <= 1'b0;
      parity_r  <= 1'b0;
    end else begin
      if (overrun_err_i) overrun_r <= 1'b1;
      if (frame_err_i)   frame_r   <= 1'b1;
      if (parity_err_i)  parity_r  <= 1'b1;
    end
  end

  // --------------------------------------------------------------------------
  // Configuration outputs from RW registers
  // --------------------------------------------------------------------------
  assign baud_div_o = hw_wdata_w[1*32 +: 32]; // BAUD_DIV
  assign config_o   = hw_wdata_w[2*32 +: 5];  // CONFIG[4:0]

endmodule

`endif // AXIL_UART_ADAPTER_SV
