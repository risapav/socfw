/**
 * @file  axil_diag_ctrl.sv
 * @brief AXI-Lite diagnostic counter peripheral (DIAG) pre xfcp_test_03.
 * @param (none beyond AXIL)
 * @details
 *   Register map (byte offset, all 32-bit):
 *     0x00  RO    COMPONENT_ID  -- constant 0x44494147 ("DIAG")
 *     0x04  RO    RX_SEEN       -- all UART RX bytes (TVALID before FIFO)
 *     0x08  RO    RX_ACCEPT     -- bytes accepted into FIFO (TVALID && TREADY)
 *     0x0C  RO    RX_LOST       -- bytes dropped at FIFO (TVALID && !TREADY)
 *     0x10  RO    RX_FRAME      -- frame error pulses
 *     0x14  RO    RX_OVERRUN    -- overrun error pulses
 *     0x18  RO    RX_SOP        -- good SOPs (parser S_IDLE->S_HDR)
 *     0x1C  RO    RX_HDR        -- headers decoded (hfifo_push)
 *     0x20  RO    RX_BAD_HDR    -- S_DECODE decode errors
 *     0x24  RO    RX_RECOVERY   -- sop_recovery events
 *     0x28  RO    RX_DROP       -- parser drop events
 *     0x2C  RO    FAB_REQ       -- valid requests dispatched to engine
 *     0x30  RO    FAB_RESP      -- responses started by packetizer
 *     0x34  RO    TX_BYTE       -- UART TX bytes sent
 *     0x38  RO    TX_PKT        -- TX packets started
 *     0x3C  PULSE DIAG_RESET   -- clears all live + shadow counters
 *     0x40  PULSE DIAG_SNAPSHOT -- copies live counters to shadow (reads return shadow)
 *
 *   All counters are 32-bit saturating. Reads at 0x04..0x38 return SHADOW values
 *   (snapshot), not live counters. Workflow:
 *     1. DIAG_RESET  -- clears live + shadow
 *     2. run N transactions
 *     3. DIAG_SNAPSHOT -- freezes live into shadow (note: snapshot write itself
 *                          is one extra XFCP transaction included in snapshot)
 *     4. Read counters  -- returns shadow; live counters continue running
 */
`ifndef AXIL_DIAG_CTRL_SV
`define AXIL_DIAG_CTRL_SV

`default_nettype none

module axil_diag_ctrl (
  input  logic       clk_i,
  input  logic       rst_ni,
  axi4lite_if.slave  s_axil,

  // 1-cycle pulse inputs from XFCP datapath
  input  logic       rx_seen_i,     // uart_rx_raw_s.TVALID (all UART RX bytes)
  input  logic       rx_accept_i,   // TVALID && TREADY (accepted into FIFO)
  input  logic       rx_lost_i,     // TVALID && !TREADY (dropped at FIFO input)
  input  logic       rx_frame_i,    // frame error pulse from UART core
  input  logic       rx_overrun_i,  // overrun error pulse from UART core
  input  logic       rx_sop_i,      // good SOP (parser S_IDLE -> S_HDR)
  input  logic       rx_hdr_i,      // header decoded (hfifo_push)
  input  logic       rx_bad_hdr_i,  // S_DECODE decode error (bad opcode/count)
  input  logic       rx_recovery_i, // sop_recovery (SOP in unexpected state)
  input  logic       rx_drop_i,     // parser drop event
  input  logic       fab_req_i,     // valid request dispatched to engine
  input  logic       fab_resp_i,    // response started by packetizer
  input  logic       tx_byte_i,     // UART TX byte sent
  input  logic       tx_pkt_i       // TX packet started
);

  import axi_pkg::*;

  localparam int NUM_REGS = 17;

  // REG_TYPES packed [NUM_REGS*2-1:0], MSB=reg16, LSB=reg0.
  localparam [NUM_REGS*2-1:0] REG_TYPES =
    {2'(AXIL_PULSE),   // reg16 = DIAG_SNAPSHOT
     2'(AXIL_PULSE),   // reg15 = DIAG_RESET
     2'(AXIL_RO),      // reg14 = TX_PKT
     2'(AXIL_RO),      // reg13 = TX_BYTE
     2'(AXIL_RO),      // reg12 = FAB_RESP
     2'(AXIL_RO),      // reg11 = FAB_REQ
     2'(AXIL_RO),      // reg10 = RX_DROP
     2'(AXIL_RO),      // reg9  = RX_RECOVERY
     2'(AXIL_RO),      // reg8  = RX_BAD_HDR
     2'(AXIL_RO),      // reg7  = RX_HDR
     2'(AXIL_RO),      // reg6  = RX_SOP
     2'(AXIL_RO),      // reg5  = RX_OVERRUN
     2'(AXIL_RO),      // reg4  = RX_FRAME
     2'(AXIL_RO),      // reg3  = RX_LOST
     2'(AXIL_RO),      // reg2  = RX_ACCEPT
     2'(AXIL_RO),      // reg1  = RX_SEEN
     2'(AXIL_RO)};     // reg0  = COMPONENT_ID

  logic [NUM_REGS*32-1:0] hw_rdata_w;
  logic [NUM_REGS*32-1:0] hw_wdata_w;
  logic [NUM_REGS-1:0]    hw_we_w;

  wire diag_reset_w = hw_we_w[15];
  wire diag_snap_w  = hw_we_w[16];

  // --------------------------------------------------------------------------
  // Saturating 32-bit live counters
  // --------------------------------------------------------------------------
  logic [31:0] rx_seen_cnt_r,    rx_accept_cnt_r,  rx_lost_cnt_r;
  logic [31:0] rx_frame_cnt_r,   rx_overrun_cnt_r;
  logic [31:0] rx_sop_cnt_r,     rx_hdr_cnt_r;
  logic [31:0] rx_bad_hdr_cnt_r, rx_recovery_cnt_r, rx_drop_cnt_r;
  logic [31:0] fab_req_cnt_r,    fab_resp_cnt_r;
  logic [31:0] tx_byte_cnt_r,    tx_pkt_cnt_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_seen_cnt_r    <= '0; rx_accept_cnt_r  <= '0; rx_lost_cnt_r    <= '0;
      rx_frame_cnt_r   <= '0; rx_overrun_cnt_r <= '0;
      rx_sop_cnt_r     <= '0; rx_hdr_cnt_r     <= '0;
      rx_bad_hdr_cnt_r <= '0; rx_recovery_cnt_r <= '0; rx_drop_cnt_r  <= '0;
      fab_req_cnt_r    <= '0; fab_resp_cnt_r   <= '0;
      tx_byte_cnt_r    <= '0; tx_pkt_cnt_r     <= '0;
    end else if (diag_reset_w) begin
      rx_seen_cnt_r    <= '0; rx_accept_cnt_r  <= '0; rx_lost_cnt_r    <= '0;
      rx_frame_cnt_r   <= '0; rx_overrun_cnt_r <= '0;
      rx_sop_cnt_r     <= '0; rx_hdr_cnt_r     <= '0;
      rx_bad_hdr_cnt_r <= '0; rx_recovery_cnt_r <= '0; rx_drop_cnt_r  <= '0;
      fab_req_cnt_r    <= '0; fab_resp_cnt_r   <= '0;
      tx_byte_cnt_r    <= '0; tx_pkt_cnt_r     <= '0;
    end else begin
      if (rx_seen_i    && rx_seen_cnt_r    != 32'hFFFF_FFFF) rx_seen_cnt_r    <= rx_seen_cnt_r    + 32'h1;
      if (rx_accept_i  && rx_accept_cnt_r  != 32'hFFFF_FFFF) rx_accept_cnt_r  <= rx_accept_cnt_r  + 32'h1;
      if (rx_lost_i    && rx_lost_cnt_r    != 32'hFFFF_FFFF) rx_lost_cnt_r    <= rx_lost_cnt_r    + 32'h1;
      if (rx_frame_i   && rx_frame_cnt_r   != 32'hFFFF_FFFF) rx_frame_cnt_r   <= rx_frame_cnt_r   + 32'h1;
      if (rx_overrun_i && rx_overrun_cnt_r != 32'hFFFF_FFFF) rx_overrun_cnt_r <= rx_overrun_cnt_r + 32'h1;
      if (rx_sop_i     && rx_sop_cnt_r     != 32'hFFFF_FFFF) rx_sop_cnt_r     <= rx_sop_cnt_r     + 32'h1;
      if (rx_hdr_i     && rx_hdr_cnt_r     != 32'hFFFF_FFFF) rx_hdr_cnt_r     <= rx_hdr_cnt_r     + 32'h1;
      if (rx_bad_hdr_i && rx_bad_hdr_cnt_r != 32'hFFFF_FFFF) rx_bad_hdr_cnt_r <= rx_bad_hdr_cnt_r + 32'h1;
      if (rx_recovery_i && rx_recovery_cnt_r != 32'hFFFF_FFFF) rx_recovery_cnt_r <= rx_recovery_cnt_r + 32'h1;
      if (rx_drop_i    && rx_drop_cnt_r    != 32'hFFFF_FFFF) rx_drop_cnt_r    <= rx_drop_cnt_r    + 32'h1;
      if (fab_req_i    && fab_req_cnt_r    != 32'hFFFF_FFFF) fab_req_cnt_r    <= fab_req_cnt_r    + 32'h1;
      if (fab_resp_i   && fab_resp_cnt_r   != 32'hFFFF_FFFF) fab_resp_cnt_r   <= fab_resp_cnt_r   + 32'h1;
      if (tx_byte_i    && tx_byte_cnt_r    != 32'hFFFF_FFFF) tx_byte_cnt_r    <= tx_byte_cnt_r    + 32'h1;
      if (tx_pkt_i     && tx_pkt_cnt_r     != 32'hFFFF_FFFF) tx_pkt_cnt_r     <= tx_pkt_cnt_r     + 32'h1;
    end
  end

  // --------------------------------------------------------------------------
  // Shadow registers: frozen on DIAG_SNAPSHOT, cleared on DIAG_RESET
  // Reads at 0x04..0x38 return shadow values (not live counters).
  // --------------------------------------------------------------------------
  logic [31:0] rx_seen_snap_r,    rx_accept_snap_r,  rx_lost_snap_r;
  logic [31:0] rx_frame_snap_r,   rx_overrun_snap_r;
  logic [31:0] rx_sop_snap_r,     rx_hdr_snap_r;
  logic [31:0] rx_bad_hdr_snap_r, rx_recovery_snap_r, rx_drop_snap_r;
  logic [31:0] fab_req_snap_r,    fab_resp_snap_r;
  logic [31:0] tx_byte_snap_r,    tx_pkt_snap_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_seen_snap_r    <= '0; rx_accept_snap_r  <= '0; rx_lost_snap_r    <= '0;
      rx_frame_snap_r   <= '0; rx_overrun_snap_r <= '0;
      rx_sop_snap_r     <= '0; rx_hdr_snap_r     <= '0;
      rx_bad_hdr_snap_r <= '0; rx_recovery_snap_r <= '0; rx_drop_snap_r  <= '0;
      fab_req_snap_r    <= '0; fab_resp_snap_r   <= '0;
      tx_byte_snap_r    <= '0; tx_pkt_snap_r     <= '0;
    end else if (diag_reset_w) begin
      rx_seen_snap_r    <= '0; rx_accept_snap_r  <= '0; rx_lost_snap_r    <= '0;
      rx_frame_snap_r   <= '0; rx_overrun_snap_r <= '0;
      rx_sop_snap_r     <= '0; rx_hdr_snap_r     <= '0;
      rx_bad_hdr_snap_r <= '0; rx_recovery_snap_r <= '0; rx_drop_snap_r  <= '0;
      fab_req_snap_r    <= '0; fab_resp_snap_r   <= '0;
      tx_byte_snap_r    <= '0; tx_pkt_snap_r     <= '0;
    end else if (diag_snap_w) begin
      rx_seen_snap_r    <= rx_seen_cnt_r;    rx_accept_snap_r  <= rx_accept_cnt_r;
      rx_lost_snap_r    <= rx_lost_cnt_r;    rx_frame_snap_r   <= rx_frame_cnt_r;
      rx_overrun_snap_r <= rx_overrun_cnt_r; rx_sop_snap_r     <= rx_sop_cnt_r;
      rx_hdr_snap_r     <= rx_hdr_cnt_r;    rx_bad_hdr_snap_r <= rx_bad_hdr_cnt_r;
      rx_recovery_snap_r <= rx_recovery_cnt_r; rx_drop_snap_r  <= rx_drop_cnt_r;
      fab_req_snap_r    <= fab_req_cnt_r;    fab_resp_snap_r   <= fab_resp_cnt_r;
      tx_byte_snap_r    <= tx_byte_cnt_r;    tx_pkt_snap_r     <= tx_pkt_cnt_r;
    end
  end

  // --------------------------------------------------------------------------
  // Register file connections: counter reads return SHADOW values
  // --------------------------------------------------------------------------
  assign hw_rdata_w[31:0]    = 32'h4449_4147; // "DIAG"
  assign hw_rdata_w[63:32]   = rx_seen_snap_r;
  assign hw_rdata_w[95:64]   = rx_accept_snap_r;
  assign hw_rdata_w[127:96]  = rx_lost_snap_r;
  assign hw_rdata_w[159:128] = rx_frame_snap_r;
  assign hw_rdata_w[191:160] = rx_overrun_snap_r;
  assign hw_rdata_w[223:192] = rx_sop_snap_r;
  assign hw_rdata_w[255:224] = rx_hdr_snap_r;
  assign hw_rdata_w[287:256] = rx_bad_hdr_snap_r;
  assign hw_rdata_w[319:288] = rx_recovery_snap_r;
  assign hw_rdata_w[351:320] = rx_drop_snap_r;
  assign hw_rdata_w[383:352] = fab_req_snap_r;
  assign hw_rdata_w[415:384] = fab_resp_snap_r;
  assign hw_rdata_w[447:416] = tx_byte_snap_r;
  assign hw_rdata_w[479:448] = tx_pkt_snap_r;
  assign hw_rdata_w[511:480] = 32'h0; // DIAG_RESET: PULSE, ignored
  assign hw_rdata_w[543:512] = 32'h0; // DIAG_SNAPSHOT: PULSE, ignored

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
