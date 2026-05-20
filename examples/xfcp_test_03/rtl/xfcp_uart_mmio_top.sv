/**
 * @file  xfcp_uart_mmio_top.sv
 * @brief Top-level: XFCP-over-UART s xfcp_fabric_endpoint a 6 AXI-Lite periferiami.
 * @param CLOCK_FREQ_HZ          Frekvencia systemu v Hz (default 50 MHz, QMTech EP4CE55).
 * @param UART_DEFAULT_BAUD_DIV  Predvolena hodnota baud prescalera (434 = 50 MHz/115200).
 * @details
 *   xfcp_test_02 upgrade: xfcp_axil_bridge + manualne dekoder nahradeny
 *   xfcp_fabric_endpoint s NUM_SLAVES=6. Adresovy dekoder je interny
 *   (SLAVE_BASE + SLAVE_MASK parametre), eliminuje 200+ riadkov manualneho
 *   mux/demux kodu.
 *
 *   Address map (SLAVE_BASE / SLAVE_MASK, stride 0x10000):
 *     Slot 0 @ 0xFF000000 : axil_sys_ctrl    (ID "SYSC")
 *     Slot 1 @ 0xFF010000 : axil_uart_adapter (ID "UART")
 *     Slot 2 @ 0xFF020000 : axil_regs / LED   (ID "OUT_")  6-bit onboard
 *     Slot 3 @ 0xFF030000 : axil_regs / LED   (ID "OUT_")  8-bit J10
 *     Slot 4 @ 0xFF040000 : axil_regs / LED   (ID "OUT_")  8-bit J11
 *     Slot 5 @ 0xFF050000 : axil_seven_seg    (ID "SEG7")
 *
 *   XFCP protokol: SOP=0xFE, READ=0x10, WRITE=0x11.
 *   AXIS_TLAST=0 z axis_uart_rx: parser odvodzuje koniec paketu z COUNT.
 *   LITTLE_ENDIAN=0: data MSB-first na drate, bez byte-swapu.
 */
`ifndef XFCP_UART_MMIO_TOP_SV
`define XFCP_UART_MMIO_TOP_SV

`default_nettype none

import axi_pkg::*;
import uart_pkg::*;
import xfcp_pkg::*;

module xfcp_uart_mmio_top #(
  parameter int CLOCK_FREQ_HZ         = 50_000_000,
  parameter int UART_DEFAULT_BAUD_DIV = 434
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       uart_rx_i,
  output logic       uart_tx_o,
  output logic [5:0] led_00_o,
  output logic [7:0] led_01_o,
  output logic [7:0] led_02_o,
  output logic [7:0] onboard_seg_o,
  output logic [2:0] onboard_dig_o
);

  localparam int NUM_SLAVES = 6;

  // --------------------------------------------------------------------------
  // AXI-Stream: UART RX/TX <-> xfcp_fabric_endpoint
  // uart_rx_raw_s: direct UART RX output (no buffering).
  // xfcp_rx_s: parser input, fed through u_rx_fifo elastic buffer.
  // --------------------------------------------------------------------------
  axi4s_if #(.DATA_WIDTH(8)) uart_rx_raw_s (.TCLK(clk_i), .TRESETn(rst_ni));
  axi4s_if #(.DATA_WIDTH(8)) xfcp_rx_s     (.TCLK(clk_i), .TRESETn(rst_ni));
  axi4s_if #(.DATA_WIDTH(8)) xfcp_tx_s     (.TCLK(clk_i), .TRESETn(rst_ni));

  // --------------------------------------------------------------------------
  // AXI-Lite: endpoint masters -> 6 slave periferias
  // --------------------------------------------------------------------------
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32))
      axil_s [NUM_SLAVES] (.ACLK(clk_i), .ARESETn(rst_ni));

  // --------------------------------------------------------------------------
  // UART konfiguracny most (axil_uart_adapter -> axis_uart_rx/tx)
  // --------------------------------------------------------------------------
  logic [31:0]  baud_div_w;
  logic [4:0]   config_w;
  logic         err_clr_w;
  uart_conf_t   uart_cfg_w;
  uart_status_t rx_status_w;
  uart_status_t tx_status_w;

  always_comb begin
    uart_cfg_w.reserved = 27'h0;
    uart_cfg_w.stop2    = config_w[4];
    uart_cfg_w.parity   = config_w[2] ? {~config_w[3], config_w[3]} : 2'b00;
    uart_cfg_w.dbits    = config_w[1:0];
  end

  // --------------------------------------------------------------------------
  // XFCP Fabric Endpoint (NUM_SLAVES=6, interny adresovy dekoder)
  // --------------------------------------------------------------------------
  xfcp_fabric_endpoint #(
    .NUM_SLAVES     (NUM_SLAVES),
    .AXI_ADDR_WIDTH (32),
    .AXI_DATA_WIDTH (32),
    .LITTLE_ENDIAN  (1'b0),
    .ID_STR         ("XFCP-UART-FAB  "),
    .SLAVE_BASE     ('{
      32'hFF00_0000,   // Slot 0: SYSC
      32'hFF01_0000,   // Slot 1: UART
      32'hFF02_0000,   // Slot 2: LED0
      32'hFF03_0000,   // Slot 3: LED1
      32'hFF04_0000,   // Slot 4: LED2
      32'hFF05_0000    // Slot 5: SEG7
    }),
    .SLAVE_MASK     ('{
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000,
      32'hFFFF_0000
    })
  ) u_endpoint (
    .clk      (clk_i),
    .rst_n    (rst_ni),
    .xfcp_in  (xfcp_rx_s.slave),
    .xfcp_out (xfcp_tx_s.master),
    .m_axil   (axil_s)
  );

  // --------------------------------------------------------------------------
  // UART RX wrapper (serial -> AXIS -> uart_rx_raw_s)
  // AXIS_TLAST=0: UART je byte stream, parser pouziva COUNT, nie TLAST.
  // --------------------------------------------------------------------------
  axis_uart_rx #(
    .AXIS_TLAST(1'b0)
  ) u_uart_rx (
    .m_axis     (uart_rx_raw_s.master),
    .rxd_i      (uart_rx_i),
    .prescale_i (baud_div_w[15:0]),
    .cfg_i      (uart_cfg_w),
    .status_o   (rx_status_w),
    .err_clear_i(err_clr_w)
  );

  // --------------------------------------------------------------------------
  // RX elastic buffer: 8-byte FIFO between UART RX and parser.
  // Prevents byte loss when parser has s_axis_tready=0 (S_DECODE or dfifo full).
  // UART sends one byte every ~87 us; even a 1-entry FIFO would suffice, but
  // 8 entries give margin for any future tready=0 windows.
  // --------------------------------------------------------------------------
  xfcp_fifo #(
    .DATA_WIDTH(8),
    .DEPTH     (8)
  ) u_rx_fifo (
    .clk    (clk_i),
    .rst_n  (rst_ni),
    .flush  (1'b0),
    .w_data (uart_rx_raw_s.TDATA),
    .w_valid(uart_rx_raw_s.TVALID),
    .w_ready(uart_rx_raw_s.TREADY),
    .r_data (xfcp_rx_s.TDATA),
    .r_valid(xfcp_rx_s.TVALID),
    .r_ready(xfcp_rx_s.TREADY)
  );

  assign xfcp_rx_s.TKEEP = '1;
  assign xfcp_rx_s.TLAST = 1'b0;
  assign xfcp_rx_s.TUSER = '0;
  assign xfcp_rx_s.TID   = '0;
  assign xfcp_rx_s.TDEST = '0;

  // --------------------------------------------------------------------------
  // UART TX wrapper (xfcp_tx_s -> AXIS -> serial)
  // --------------------------------------------------------------------------
  axis_uart_tx u_uart_tx (
    .s_axis         (xfcp_tx_s.slave),
    .txd_o          (uart_tx_o),
    .prescale_i     (baud_div_w[15:0]),
    .cfg_i          (uart_cfg_w),
    .status_o       (tx_status_w),
    .tx_done_pulse_o()
  );

  // --------------------------------------------------------------------------
  // Slot 0: System Control (SYSC) — axil_s[0]
  // --------------------------------------------------------------------------
  axil_sys_ctrl #(
    .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ)
  ) u_sys_ctrl (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .s_axil        (axil_s[0].slave),
    .pll_locked_i  (1'b1),
    .ic_timeout_i  (1'b0),
    .fault_addr_i  (32'h0),
    .fault_status_i(32'h0),
    .sw_reset_o    (),
    .clear_faults_o()
  );

  // --------------------------------------------------------------------------
  // Slot 1: UART diagnostic adapter — axil_s[1]
  // --------------------------------------------------------------------------
  axil_uart_adapter #(
    .BAUD_DIV_DEFAULT(UART_DEFAULT_BAUD_DIV)
  ) u_uart_adapter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .s_axil       (axil_s[1].slave),
    .tx_busy_i    (tx_status_w.tx_busy),
    .rx_busy_i    (rx_status_w.rx_busy),
    .overrun_err_i(rx_status_w.overrun_err),
    .frame_err_i  (rx_status_w.frame_err),
    .parity_err_i (rx_status_w.parity_err),
    .tx_fifo_cnt_i(8'h0),
    .rx_fifo_cnt_i(8'h0),
    .baud_div_o   (baud_div_w),
    .config_o     (config_w),
    .err_clr_o    (err_clr_w)
  );

  // --------------------------------------------------------------------------
  // Slot 2: LED onboard 6-bit — axil_s[2]
  // --------------------------------------------------------------------------
  logic [31:0] led_data_00_w;

  axil_regs u_led_regs_00 (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .s_axil(axil_s[2].slave),
    .data_o(led_data_00_w)
  );

  assign led_00_o = led_data_00_w[5:0];

  // --------------------------------------------------------------------------
  // Slot 3: LED PMOD J10 8-bit — axil_s[3]
  // --------------------------------------------------------------------------
  logic [31:0] led_data_01_w;

  axil_regs u_led_regs_01 (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .s_axil(axil_s[3].slave),
    .data_o(led_data_01_w)
  );

  assign led_01_o = led_data_01_w[7:0];

  // --------------------------------------------------------------------------
  // Slot 4: LED PMOD J11 8-bit — axil_s[4]
  // --------------------------------------------------------------------------
  logic [31:0] led_data_02_w;

  axil_regs u_led_regs_02 (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .s_axil(axil_s[4].slave),
    .data_o(led_data_02_w)
  );

  assign led_02_o = led_data_02_w[7:0];

  // --------------------------------------------------------------------------
  // Slot 5: 7-seg display adapter — axil_s[5]
  // --------------------------------------------------------------------------
  axil_seven_seg_adapter #(
    .CLOCK_FREQ_HZ   (CLOCK_FREQ_HZ),
    .DIGIT_REFRESH_HZ(250),
    .COMMON_ANODE    (1'b1)
  ) u_seven_seg (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .s_axil(axil_s[5].slave),
    .dig_o (onboard_dig_o),
    .seg_o (onboard_seg_o)
  );

endmodule

`endif // XFCP_UART_MMIO_TOP_SV
