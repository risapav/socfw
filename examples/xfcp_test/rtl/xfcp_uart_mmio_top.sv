/**
 * @file  xfcp_uart_mmio_top.sv
 * @brief Top-level: XFCP-over-UART bridge with 4 AXI-Lite peripherals.
 * @param CLOCK_FREQ_HZ          System clock in Hz (default 50 MHz, QMTech EP4CE55).
 * @param UART_DEFAULT_BAUD_DIV  Reset value for baud prescaler (default 434 = 50 MHz/115200).
 * @details
 *   Integrates xfcp_axil_bridge with four AXI-Lite peripherals through an
 *   inline 1-to-4 AXI-Lite address decoder.
 *
 *   Address map (AWADDR[17:16] = slot index):
 *     Slot 0 @ 0xFF000000 : axil_sys_ctrl    (ID "SYSC")
 *     Slot 1 @ 0xFF010000 : axil_uart_adapter (ID "UART")
 *     Slot 2 @ 0xFF020000 : axil_regs / LED   (ID "OUT_")
 *     Slot 3 @ 0xFF030000 : axil_seven_seg    (ID "SEG7")
 *
 *   XFCP protocol (xfcp_axil_bridge): SOP=0xFE, READ=0x10, WRITE=0x11.
 *   axis_uart_rx is instantiated with AXIS_TLAST=0: UART is a byte stream;
 *   xfcp_rx_parser derives packet end from the COUNT header field, not TLAST.
 *   LITTLE_ENDIAN=0: data is sent/received MSB-first; no byte-swap in engine.
 *   baud_div_o and config_o from axil_uart_adapter control both UART cores.
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
  output logic [5:0] led_o,
  output logic [7:0] onboard_seg_o,
  output logic [2:0] onboard_dig_o
);

  // --------------------------------------------------------------------------
  // AXI-Stream: UART RX -> XFCP bridge -> UART TX
  // axis_uart_rx uses AXIS_TLAST=0 so xfcp_rx_parser never sees a mid-packet
  // TLAST; the parser derives packet end from the COUNT field instead.
  // --------------------------------------------------------------------------
  axi4s_if #(.DATA_WIDTH(8)) xfcp_rx_s (.TCLK(clk_i), .TRESETn(rst_ni));
  axi4s_if #(.DATA_WIDTH(8)) xfcp_tx_s (.TCLK(clk_i), .TRESETn(rst_ni));

  // --------------------------------------------------------------------------
  // AXI-Lite: bridge master + 4 peripheral slaves
  // --------------------------------------------------------------------------
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_m
      (.ACLK(clk_i), .ARESETn(rst_ni));
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_sysc
      (.ACLK(clk_i), .ARESETn(rst_ni));
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_uart_s
      (.ACLK(clk_i), .ARESETn(rst_ni));
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_led
      (.ACLK(clk_i), .ARESETn(rst_ni));
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_seg
      (.ACLK(clk_i), .ARESETn(rst_ni));

  // --------------------------------------------------------------------------
  // UART configuration bridge (axil_uart_adapter -> axis_uart_rx/tx)
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
  // XFCP bridge (xfcp_axil_bridge: new protocol SOP=0xFE, WRITE=0x11)
  // LITTLE_ENDIAN=0: data MSB-first on wire, no byte-swap in engine.
  // --------------------------------------------------------------------------
  xfcp_axil_bridge #(
    .LITTLE_ENDIAN  (1'b0),
    .AXI_ADDR_WIDTH (32),
    .AXI_DATA_WIDTH (32),
    .ID_STR         ("XFCP-UART-MMIO  ")
  ) u_bridge (
    .clk     (clk_i),
    .rst_n   (rst_ni),
    .m_axil  (axil_m.master),
    .xfcp_in (xfcp_rx_s.slave),
    .xfcp_out(xfcp_tx_s.master)
  );

  // --------------------------------------------------------------------------
  // UART RX wrapper (serial line -> AXI-Stream bytes -> xfcp_rx_s)
  // AXIS_TLAST=0: UART is a byte stream; xfcp_rx_parser uses COUNT, not TLAST.
  // --------------------------------------------------------------------------
  axis_uart_rx #(
    .AXIS_TLAST(1'b0)
  ) u_uart_rx (
    .m_axis     (xfcp_rx_s.master),
    .rxd_i      (uart_rx_i),
    .prescale_i (baud_div_w[15:0]),
    .cfg_i      (uart_cfg_w),
    .status_o   (rx_status_w),
    .err_clear_i(err_clr_w)
  );

  // --------------------------------------------------------------------------
  // UART TX wrapper (xfcp_tx_s -> AXI-Stream bytes -> serial line)
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
  // AXI-Lite 1-to-4 decoder  (slot = addr[17:16])
  // --------------------------------------------------------------------------
  logic [1:0] aw_slot_w, ar_slot_w, wr_slot_r, rd_slot_r;

  assign aw_slot_w = axil_m.AWADDR[17:16];
  assign ar_slot_w = axil_m.ARADDR[17:16];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_slot_r <= 2'h0;
      rd_slot_r <= 2'h0;
    end else begin
      if (axil_m.AWVALID && axil_m.AWREADY) wr_slot_r <= aw_slot_w;
      if (axil_m.ARVALID && axil_m.ARREADY) rd_slot_r <= ar_slot_w;
    end
  end

  // Broadcast address/prot to all slaves; gate valid signals by slot
  assign axil_sysc.AWADDR    = axil_m.AWADDR;
  assign axil_sysc.AWPROT    = axil_m.AWPROT;
  assign axil_uart_s.AWADDR  = axil_m.AWADDR;
  assign axil_uart_s.AWPROT  = axil_m.AWPROT;
  assign axil_led.AWADDR     = axil_m.AWADDR;
  assign axil_led.AWPROT     = axil_m.AWPROT;
  assign axil_seg.AWADDR     = axil_m.AWADDR;
  assign axil_seg.AWPROT     = axil_m.AWPROT;

  assign axil_sysc.WDATA     = axil_m.WDATA;
  assign axil_sysc.WSTRB     = axil_m.WSTRB;
  assign axil_uart_s.WDATA   = axil_m.WDATA;
  assign axil_uart_s.WSTRB   = axil_m.WSTRB;
  assign axil_led.WDATA      = axil_m.WDATA;
  assign axil_led.WSTRB      = axil_m.WSTRB;
  assign axil_seg.WDATA      = axil_m.WDATA;
  assign axil_seg.WSTRB      = axil_m.WSTRB;

  assign axil_sysc.ARADDR    = axil_m.ARADDR;
  assign axil_sysc.ARPROT    = axil_m.ARPROT;
  assign axil_uart_s.ARADDR  = axil_m.ARADDR;
  assign axil_uart_s.ARPROT  = axil_m.ARPROT;
  assign axil_led.ARADDR     = axil_m.ARADDR;
  assign axil_led.ARPROT     = axil_m.ARPROT;
  assign axil_seg.ARADDR     = axil_m.ARADDR;
  assign axil_seg.ARPROT     = axil_m.ARPROT;

  // AW valid: gated by slot (combinatorial decode)
  assign axil_sysc.AWVALID   = axil_m.AWVALID & (aw_slot_w == 2'h0);
  assign axil_uart_s.AWVALID = axil_m.AWVALID & (aw_slot_w == 2'h1);
  assign axil_led.AWVALID    = axil_m.AWVALID & (aw_slot_w == 2'h2);
  assign axil_seg.AWVALID    = axil_m.AWVALID & (aw_slot_w == 2'h3);

  // W valid: follows AW slot (axil_xfcp_mod sends AW+W simultaneously)
  assign axil_sysc.WVALID    = axil_m.WVALID & (aw_slot_w == 2'h0);
  assign axil_uart_s.WVALID  = axil_m.WVALID & (aw_slot_w == 2'h1);
  assign axil_led.WVALID     = axil_m.WVALID & (aw_slot_w == 2'h2);
  assign axil_seg.WVALID     = axil_m.WVALID & (aw_slot_w == 2'h3);

  // B ready: gated by registered write slot
  assign axil_sysc.BREADY    = axil_m.BREADY & (wr_slot_r == 2'h0);
  assign axil_uart_s.BREADY  = axil_m.BREADY & (wr_slot_r == 2'h1);
  assign axil_led.BREADY     = axil_m.BREADY & (wr_slot_r == 2'h2);
  assign axil_seg.BREADY     = axil_m.BREADY & (wr_slot_r == 2'h3);

  // AR valid: gated by slot
  assign axil_sysc.ARVALID   = axil_m.ARVALID & (ar_slot_w == 2'h0);
  assign axil_uart_s.ARVALID = axil_m.ARVALID & (ar_slot_w == 2'h1);
  assign axil_led.ARVALID    = axil_m.ARVALID & (ar_slot_w == 2'h2);
  assign axil_seg.ARVALID    = axil_m.ARVALID & (ar_slot_w == 2'h3);

  // R ready: gated by registered read slot
  assign axil_sysc.RREADY    = axil_m.RREADY & (rd_slot_r == 2'h0);
  assign axil_uart_s.RREADY  = axil_m.RREADY & (rd_slot_r == 2'h1);
  assign axil_led.RREADY     = axil_m.RREADY & (rd_slot_r == 2'h2);
  assign axil_seg.RREADY     = axil_m.RREADY & (rd_slot_r == 2'h3);

  // AW ready: mux from selected slave
  always_comb begin
    case (aw_slot_w)
      2'h0:    axil_m.AWREADY = axil_sysc.AWREADY;
      2'h1:    axil_m.AWREADY = axil_uart_s.AWREADY;
      2'h2:    axil_m.AWREADY = axil_led.AWREADY;
      default: axil_m.AWREADY = axil_seg.AWREADY;
    endcase
  end

  // W ready: mux from selected slave
  always_comb begin
    case (aw_slot_w)
      2'h0:    axil_m.WREADY = axil_sysc.WREADY;
      2'h1:    axil_m.WREADY = axil_uart_s.WREADY;
      2'h2:    axil_m.WREADY = axil_led.WREADY;
      default: axil_m.WREADY = axil_seg.WREADY;
    endcase
  end

  // B: mux from registered write slot slave
  always_comb begin
    case (wr_slot_r)
      2'h0:    begin axil_m.BVALID = axil_sysc.BVALID;   axil_m.BRESP = axil_sysc.BRESP;   end
      2'h1:    begin axil_m.BVALID = axil_uart_s.BVALID; axil_m.BRESP = axil_uart_s.BRESP; end
      2'h2:    begin axil_m.BVALID = axil_led.BVALID;    axil_m.BRESP = axil_led.BRESP;    end
      default: begin axil_m.BVALID = axil_seg.BVALID;    axil_m.BRESP = axil_seg.BRESP;    end
    endcase
  end

  // AR ready: mux from selected slave
  always_comb begin
    case (ar_slot_w)
      2'h0:    axil_m.ARREADY = axil_sysc.ARREADY;
      2'h1:    axil_m.ARREADY = axil_uart_s.ARREADY;
      2'h2:    axil_m.ARREADY = axil_led.ARREADY;
      default: axil_m.ARREADY = axil_seg.ARREADY;
    endcase
  end

  // R: mux from registered read slot slave
  always_comb begin
    case (rd_slot_r)
      2'h0: begin
        axil_m.RVALID = axil_sysc.RVALID;
        axil_m.RDATA  = axil_sysc.RDATA;
        axil_m.RRESP  = axil_sysc.RRESP;
      end
      2'h1: begin
        axil_m.RVALID = axil_uart_s.RVALID;
        axil_m.RDATA  = axil_uart_s.RDATA;
        axil_m.RRESP  = axil_uart_s.RRESP;
      end
      2'h2: begin
        axil_m.RVALID = axil_led.RVALID;
        axil_m.RDATA  = axil_led.RDATA;
        axil_m.RRESP  = axil_led.RRESP;
      end
      default: begin
        axil_m.RVALID = axil_seg.RVALID;
        axil_m.RDATA  = axil_seg.RDATA;
        axil_m.RRESP  = axil_seg.RRESP;
      end
    endcase
  end

  // --------------------------------------------------------------------------
  // Slot 0: System Control (SYSC)
  // --------------------------------------------------------------------------
  axil_sys_ctrl #(
    .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ)
  ) u_sys_ctrl (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .s_axil        (axil_sysc.slave),
    .pll_locked_i  (1'b1),
    .ic_timeout_i  (1'b0),
    .fault_addr_i  (32'h0),
    .fault_status_i(32'h0),
    .sw_reset_o    (),
    .clear_faults_o()
  );

  // --------------------------------------------------------------------------
  // Slot 1: UART diagnostic adapter (UART)
  // --------------------------------------------------------------------------
  axil_uart_adapter #(
    .BAUD_DIV_DEFAULT(UART_DEFAULT_BAUD_DIV)
  ) u_uart_adapter (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .s_axil       (axil_uart_s.slave),
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
  // Slot 2: LED output register (OUT_)
  // --------------------------------------------------------------------------
  logic [31:0] led_data_w;

  axil_regs u_led_regs (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .s_axil(axil_led.slave),
    .data_o(led_data_w)
  );

  assign led_o = led_data_w[5:0];

  // --------------------------------------------------------------------------
  // Slot 3: 7-segment display adapter (SEG7)
  // --------------------------------------------------------------------------
  axil_seven_seg_adapter #(
    .CLOCK_FREQ_HZ   (CLOCK_FREQ_HZ),
    .DIGIT_REFRESH_HZ(250),
    .COMMON_ANODE    (1'b1)
  ) u_seven_seg (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .s_axil(axil_seg.slave),
    .dig_o (onboard_dig_o),
    .seg_o (onboard_seg_o)
  );

endmodule

`endif // XFCP_UART_MMIO_TOP_SV
