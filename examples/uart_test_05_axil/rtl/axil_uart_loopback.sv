/**
 * @file    axil_uart_loopback.sv
 * @brief   AXI-Lite UART loopback master: polls STATUS, reads RX_DATA, writes TX_DATA.
 * @details
 *  Continuously polls uart_axil STATUS register (UART_REG_STATUS[6] = rx_valid).
 *  When data is available:
 *    1. Reads  RX_DATA (UART_REG_RX_DATA)  -- pops the RX FIFO.
 *    2. Writes TX_DATA (UART_REG_TX_DATA)  -- pushes byte to TX FIFO.
 *
 *  AXI-Lite outputs are combinatorial (always_comb driven from state_r).
 *  State transitions are registered (always_ff).  This ensures that the slave
 *  sees ARVALID=1 in the same cycle that ARREADY is checked, so the AR
 *  handshake completes in 1 cycle and RVALID appears in the next cycle.
 *
 *  Latency per byte: ~7 clock cycles (2 STATUS read + 2 RX_DATA read + 3 TX write).
 *  At 125 MHz this is <<1 us -- far faster than the 8.7 us UART bit period.
 *
 *  Status pulses (1-cycle wide):
 *    rx_active_o  -- byte popped from RX FIFO (on ST_R_RX -> ST_WR_TX transition)
 *    tx_active_o  -- byte pushed to TX FIFO   (on ST_WAIT_B BVALID acceptance)
 */

`ifndef AXIL_UART_LOOPBACK_SV
`define AXIL_UART_LOOPBACK_SV

`default_nettype none

import axi_pkg::*;
import uart_pkg::*;

module axil_uart_loopback (
  input  wire clk_i,
  input  wire rst_ni,

  axi4lite_if.master m_axil,

  output logic rx_active_o,
  output logic tx_active_o
);

  typedef enum logic [2:0] {
    ST_AR_STAT,  // assert AR for STATUS register
    ST_R_STAT,   // wait for R response; check rx_valid
    ST_AR_RX,    // assert AR for RX_DATA (pops FIFO)
    ST_R_RX,     // wait for R response; capture byte
    ST_WR_TX,    // assert AW+W for TX_DATA
    ST_WAIT_B    // wait for B response
  } state_e;

  state_e     state_r;
  logic [7:0] rx_byte_r;
  logic       aw_done_r, w_done_r;

  // --------------------------------------------------------------------------
  // AXI-Lite combinatorial outputs (no registered delay on handshake signals)
  // --------------------------------------------------------------------------
  always_comb begin
    m_axil.AWVALID = 1'b0;
    m_axil.AWADDR  = '0;
    m_axil.AWPROT  = 3'h0;
    m_axil.WVALID  = 1'b0;
    m_axil.WDATA   = '0;
    m_axil.WSTRB   = 4'h0;
    m_axil.BREADY  = 1'b0;
    m_axil.ARVALID = 1'b0;
    m_axil.ARADDR  = '0;
    m_axil.ARPROT  = 3'h0;
    m_axil.RREADY  = 1'b0;

    case (state_r)
      ST_AR_STAT: begin
        m_axil.ARVALID = 1'b1;
        m_axil.ARADDR  = UART_REG_STATUS;
      end
      ST_R_STAT: begin
        m_axil.RREADY  = 1'b1;
      end
      ST_AR_RX: begin
        m_axil.ARVALID = 1'b1;
        m_axil.ARADDR  = UART_REG_RX_DATA;
      end
      ST_R_RX: begin
        m_axil.RREADY  = 1'b1;
      end
      ST_WR_TX: begin
        m_axil.AWVALID = ~aw_done_r;
        m_axil.AWADDR  = UART_REG_TX_DATA;
        m_axil.WVALID  = ~w_done_r;
        m_axil.WDATA   = {24'h0, rx_byte_r};
        m_axil.WSTRB   = 4'h1;
        m_axil.BREADY  = 1'b1;
      end
      ST_WAIT_B: begin
        m_axil.BREADY  = 1'b1;
      end
      default: ;
    endcase
  end

  // --------------------------------------------------------------------------
  // State machine
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_r     <= ST_AR_STAT;
      rx_byte_r   <= 8'h0;
      aw_done_r   <= 1'b0;
      w_done_r    <= 1'b0;
      rx_active_o <= 1'b0;
      tx_active_o <= 1'b0;
    end else begin
      rx_active_o <= 1'b0;
      tx_active_o <= 1'b0;

      case (state_r)

        ST_AR_STAT:
          if (m_axil.ARREADY)
            state_r <= ST_R_STAT;

        ST_R_STAT:
          if (m_axil.RVALID)
            state_r <= m_axil.RDATA[6] ? ST_AR_RX : ST_AR_STAT;

        ST_AR_RX:
          if (m_axil.ARREADY)
            state_r <= ST_R_RX;

        ST_R_RX:
          if (m_axil.RVALID) begin
            rx_byte_r   <= m_axil.RDATA[7:0];
            rx_active_o <= 1'b1;
            aw_done_r   <= 1'b0;
            w_done_r    <= 1'b0;
            state_r     <= ST_WR_TX;
          end

        ST_WR_TX: begin
          if (m_axil.AWREADY && !aw_done_r) aw_done_r <= 1'b1;
          if (m_axil.WREADY  && !w_done_r)  w_done_r  <= 1'b1;
          if ((aw_done_r || m_axil.AWREADY) &&
              (w_done_r  || m_axil.WREADY))
            state_r <= ST_WAIT_B;
        end

        ST_WAIT_B:
          if (m_axil.BVALID) begin
            tx_active_o <= 1'b1;
            state_r     <= ST_AR_STAT;
          end

        default: state_r <= ST_AR_STAT;

      endcase
    end
  end

endmodule

`default_nettype wire

`endif // AXIL_UART_LOOPBACK_SV
