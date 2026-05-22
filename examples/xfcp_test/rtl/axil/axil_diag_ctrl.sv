/**
 * @file  axil_diag_ctrl.sv
 * @brief AXI-Lite diagnostic counter peripheral (DIAG) pre xfcp_test_03.
 * @param (none beyond AXIL)
 * @details
 *   Register map (byte offset, all 32-bit):
 *     0x00  RO    COMPONENT_ID   -- constant 0x44494147 ("DIAG")
 *     0x04  RO    RX_BYTE_COUNT  -- UART RX bytes into FIFO
 *     0x08  RO    RX_SOP_COUNT   -- good SOPs received by parser (S_IDLE->S_HDR)
 *     0x0C  RO    RX_HDR_COUNT   -- headers decoded (hfifo_push in parser)
 *     0x10  RO    RX_DROP_COUNT  -- parser drop events (go_drop, not S_DROP re-entry)
 *     0x14  RO    FAB_REQ_COUNT  -- valid requests dispatched to engine
 *     0x18  RO    FAB_RESP_COUNT -- responses started by packetizer
 *     0x1C  RO    TX_BYTE_COUNT  -- UART TX bytes sent
 *     0x20  RO    TX_PKT_COUNT   -- TX packets started (tx_busy rising edge)
 *     0x24  PULSE DIAG_RESET    -- write any value to clear all counters
 *
 *   All counters are 32-bit saturating (stop at 0xFFFFFFFF, no wrap).
 *   A DIAG_RESET write clears all counters in one cycle.
 *   Pulse inputs are 1-cycle combinational signals from the XFCP datapath.
 */
`ifndef AXIL_DIAG_CTRL_SV
`define AXIL_DIAG_CTRL_SV

`default_nettype none

module axil_diag_ctrl (
  input  logic       clk_i,
  input  logic       rst_ni,
  axi4lite_if.slave  s_axil,

  // 1-cycle pulse inputs from XFCP datapath
  input  logic       rx_byte_i,     // byte into RX FIFO
  input  logic       rx_sop_i,      // good SOP parsed
  input  logic       rx_hdr_i,      // header decoded (hfifo_push)
  input  logic       rx_drop_i,     // drop event
  input  logic       fab_req_i,     // valid engine dispatch
  input  logic       fab_resp_i,    // response started
  input  logic       tx_byte_i,     // TX byte sent
  input  logic       tx_pkt_i       // TX packet started
);

  import axi_pkg::*;

  localparam int NUM_REGS = 10;

  // REG_TYPES: reg0=RO, reg1-8=RO, reg9=PULSE. Packed LSB→MSB = reg0→reg9.
  localparam [NUM_REGS*2-1:0] REG_TYPES =
    {2'(AXIL_PULSE),   // reg9 = DIAG_RESET
     2'(AXIL_RO),      // reg8 = TX_PKT_COUNT
     2'(AXIL_RO),      // reg7 = TX_BYTE_COUNT
     2'(AXIL_RO),      // reg6 = FAB_RESP_COUNT
     2'(AXIL_RO),      // reg5 = FAB_REQ_COUNT
     2'(AXIL_RO),      // reg4 = RX_DROP_COUNT
     2'(AXIL_RO),      // reg3 = RX_HDR_COUNT
     2'(AXIL_RO),      // reg2 = RX_SOP_COUNT
     2'(AXIL_RO),      // reg1 = RX_BYTE_COUNT
     2'(AXIL_RO)};     // reg0 = COMPONENT_ID

  logic [NUM_REGS*32-1:0] hw_rdata_w;
  logic [NUM_REGS*32-1:0] hw_wdata_w;
  logic [NUM_REGS-1:0]    hw_we_w;

  // --------------------------------------------------------------------------
  // Saturating 32-bit counters
  // --------------------------------------------------------------------------
  logic [31:0] rx_byte_cnt_r;
  logic [31:0] rx_sop_cnt_r;
  logic [31:0] rx_hdr_cnt_r;
  logic [31:0] rx_drop_cnt_r;
  logic [31:0] fab_req_cnt_r;
  logic [31:0] fab_resp_cnt_r;
  logic [31:0] tx_byte_cnt_r;
  logic [31:0] tx_pkt_cnt_r;

  // diag_reset_w is a 1-cycle synchronous clear (from SW write to DIAG_RESET register).
  // Must NOT be combined with the async rst_ni condition — Quartus would infer a latch.
  wire diag_reset_w = hw_we_w[9];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_byte_cnt_r  <= '0;
      rx_sop_cnt_r   <= '0;
      rx_hdr_cnt_r   <= '0;
      rx_drop_cnt_r  <= '0;
      fab_req_cnt_r  <= '0;
      fab_resp_cnt_r <= '0;
      tx_byte_cnt_r  <= '0;
      tx_pkt_cnt_r   <= '0;
    end else if (diag_reset_w) begin
      rx_byte_cnt_r  <= '0;
      rx_sop_cnt_r   <= '0;
      rx_hdr_cnt_r   <= '0;
      rx_drop_cnt_r  <= '0;
      fab_req_cnt_r  <= '0;
      fab_resp_cnt_r <= '0;
      tx_byte_cnt_r  <= '0;
      tx_pkt_cnt_r   <= '0;
    end else begin
      if (rx_byte_i  && rx_byte_cnt_r  != 32'hFFFF_FFFF) rx_byte_cnt_r  <= rx_byte_cnt_r  + 32'h1;
      if (rx_sop_i   && rx_sop_cnt_r   != 32'hFFFF_FFFF) rx_sop_cnt_r   <= rx_sop_cnt_r   + 32'h1;
      if (rx_hdr_i   && rx_hdr_cnt_r   != 32'hFFFF_FFFF) rx_hdr_cnt_r   <= rx_hdr_cnt_r   + 32'h1;
      if (rx_drop_i  && rx_drop_cnt_r  != 32'hFFFF_FFFF) rx_drop_cnt_r  <= rx_drop_cnt_r  + 32'h1;
      if (fab_req_i  && fab_req_cnt_r  != 32'hFFFF_FFFF) fab_req_cnt_r  <= fab_req_cnt_r  + 32'h1;
      if (fab_resp_i && fab_resp_cnt_r != 32'hFFFF_FFFF) fab_resp_cnt_r <= fab_resp_cnt_r + 32'h1;
      if (tx_byte_i  && tx_byte_cnt_r  != 32'hFFFF_FFFF) tx_byte_cnt_r  <= tx_byte_cnt_r  + 32'h1;
      if (tx_pkt_i   && tx_pkt_cnt_r   != 32'hFFFF_FFFF) tx_pkt_cnt_r   <= tx_pkt_cnt_r   + 32'h1;
    end
  end

  // --------------------------------------------------------------------------
  // Register file connections
  // --------------------------------------------------------------------------
  assign hw_rdata_w[31:0]    = 32'h4449_4147; // "DIAG"
  assign hw_rdata_w[63:32]   = rx_byte_cnt_r;
  assign hw_rdata_w[95:64]   = rx_sop_cnt_r;
  assign hw_rdata_w[127:96]  = rx_hdr_cnt_r;
  assign hw_rdata_w[159:128] = rx_drop_cnt_r;
  assign hw_rdata_w[191:160] = fab_req_cnt_r;
  assign hw_rdata_w[223:192] = fab_resp_cnt_r;
  assign hw_rdata_w[255:224] = tx_byte_cnt_r;
  assign hw_rdata_w[287:256] = tx_pkt_cnt_r;
  assign hw_rdata_w[319:288] = 32'h0;          // DIAG_RESET: PULSE, hw_rdata unused

  axil_regfile #(
    .NUM_REGS  (NUM_REGS),
    .REG_TYPES (REG_TYPES),
    .RESET_VALS('0)
  ) u_regfile (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .s_axil     (s_axil),
    .hw_rdata_i (hw_rdata_w),
    .hw_wdata_o (hw_wdata_w),
    .hw_we_o    (hw_we_w)
  );

endmodule

`endif // AXIL_DIAG_CTRL_SV
