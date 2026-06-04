/**
 * @file ethernet_test_03_top.sv
 * @brief Top-level UDP echo module for QMTech EP4CE55 + RTL8211EG (GMII 1 Gbps).
 * @details Dual-clock CDC architecture:
 *   SYS domain  (sys_clk_i 50 MHz) : PHY reset extender, LED debug
 *   RX domain   (eth_rx_clk_i)     : gmii_rx_mac -> parsers -> udp_echo_app
 *                                     -> udp_ipv4_tx_builder -> async FIFO write
 *   TX domain   (eth_tx_clk_i)     : TX controller FSM -> gmii_tx_mac
 *   CDC         :  pkt_fifo  async_fifo #(.DATA_WIDTH(9),  .DEPTH(2048))
 *                  meta_fifo async_fifo #(.DATA_WIDTH(96), .DEPTH(32))
 *
 *   PHY reset: eth_phyrstb_o held low for ~335 ms after rst_ni, then released.
 *   MDIO/MDC:  stub only (strapped high through pull-ups on board).
 *   GTX CLK:   eth_gtx_clk_o tied to eth_tx_clk_i (125 MHz PLL output).
 *
 * @param LOCAL_MAC      FPGA MAC address
 * @param LOCAL_IP       FPGA IPv4 address (big-endian, e.g. 192.168.0.2 = C0A80002)
 * @param UDP_PORT       Listened UDP destination port
 * @param SYS_CLK_HZ     sys_clk_i frequency in Hz
 * @param EXPECT_PREAMBLE 1 = require GMII preamble/SFD before data
 */

`ifndef ETHERNET_TEST_03_TOP_SV
`define ETHERNET_TEST_03_TOP_SV

`default_nettype none

import eth_pkg::*;

module ethernet_test_03_top #(
  parameter logic [47:0] LOCAL_MAC      = 48'h000A3501FEC0,
  parameter logic [31:0] LOCAL_IP       = 32'hC0A80002,
  parameter logic [15:0] UDP_PORT       = 16'd8080,
  parameter int          SYS_CLK_HZ    = 50_000_000,
  parameter bit          EXPECT_PREAMBLE = 1'b1
)(
  input  wire logic        sys_clk_i,
  input  wire logic        eth_rx_clk_i,
  input  wire logic        eth_tx_clk_i,
  input  wire logic        rst_ni,

  input  wire logic [7:0]  eth_rxd_i,
  input  wire logic        eth_rxdv_i,
  input  wire logic        eth_rxer_i,

  output      logic [7:0]  eth_txd_o,
  output      logic        eth_txen_o,
  output      logic        eth_txer_o,
  output      logic        eth_gtx_clk_o,

  output      logic        eth_mdc_o,
  inout  wire logic        eth_mdio_io,
  output      logic        eth_phyrstb_o,

  output      logic [5:0]  led_o,

  // Debug bus for J10/J11 logic analyzer (ETH_RXC domain, raw signals)
  output      logic [7:0]  dbg_mac_data_o,
  output      logic [7:0]  dbg_ctrl_o,
  output      logic        uart_tap_tx_o,
  input  wire logic [3:0]  btn_i
);

  // Combined reset: rst_ni AND btn_i[3] (ONB_BTN[3]=btn5, active-low).
  wire rst_w = rst_ni & btn_i[3];

  // ===========================================================================
  // SYS CLOCK DOMAIN — PHY reset extender
  // Counter saturates at all-ones (~335 ms at 50 MHz).
  // ===========================================================================
  localparam int PHY_RST_W = 24;

  logic [PHY_RST_W-1:0] phy_rst_cnt_q;
  logic                 phy_rst_done_w;

  always_ff @(posedge sys_clk_i or negedge rst_w) begin
    if (!rst_w) phy_rst_cnt_q <= '0;
    else if (phy_rst_cnt_q != '1) phy_rst_cnt_q <= phy_rst_cnt_q + 1'b1;
  end

  assign phy_rst_done_w = &phy_rst_cnt_q;
  assign eth_phyrstb_o  = phy_rst_done_w;

  // MDIO/MDC stub (PHY strapped via pull-ups; MDIO master added later)
  assign eth_mdc_o   = 1'b0;
  assign eth_mdio_io = 1'bz;

  // GTX CLK forwarding: altddio_out routes GTxCLK through dedicated IOE path (same as
  // TxD output FFs). invert_output="ON" shifts GTxCLK rising edge to falling edge of
  // outclock (+T/2 = +4 ns at 125 MHz) so PHY sees TxD stable for 4 ns before sampling.
  // tGSUR spec = 2 ns min (Table 58 RTL8211EG), 4 ns margin satisfies requirement.
  // Simulation/svlint: direct assign (SYNTHESIS not defined by linter/verilator).
`ifdef SYNTHESIS
  altddio_out #(
    .extend_oe_disable    ("OFF"),
    .intended_device_family("Cyclone IV E"),
    .invert_output        ("ON"),
    .lpm_type             ("altddio_out"),
    .oe_reg               ("UNREGISTERED"),
    .power_up_high        ("OFF"),
    .width                (1)
  ) u_gtxclk_fwd (
    .aclr      (1'b0),
    .aset      (1'b0),
    .sclr      (1'b0),
    .sset      (1'b0),
    .datain_h  (1'b1),
    .datain_l  (1'b0),
    .oe        (1'b1),
    .outclocken(1'b1),
    .outclock  (eth_tx_clk_i),
    .dataout   (eth_gtx_clk_o),
    .oe_out    ()
  );
`else
  assign eth_gtx_clk_o = eth_tx_clk_i;
`endif

  // ===========================================================================
  // RX CLOCK DOMAIN
  // ===========================================================================

  // Layer debug signals (ETH_RXC domain)
  logic mac_frame_done_w;
  logic eth_hdr_valid_w;
  logic ipv4_hdr_valid_w;

  // MAC debug pulse signals (ETH_RXC domain, 1-cycle)
  logic mac_hdr_done_w;
  logic mac_accept_pulse_w;
  logic mac_drop_pulse_w;

  // Parser debug capture (ETH_RXC domain, held after byte 13)
  logic [47:0] dbg_dst_mac_w;
  logic        dbg_mac_accept_w;

  // MAC -> L2
  logic [7:0]  mac_tdata;
  logic        mac_tvalid, mac_tready, mac_tlast, mac_tuser;

  // L2 -> L3
  logic [7:0]  eth_tdata;
  logic        eth_tvalid, eth_tready, eth_tlast;
  logic [47:0] eth_src_mac, eth_dst_mac;

  // L3 -> L4
  logic [7:0]  ip_tdata;
  logic        ip_tvalid, ip_tready, ip_tlast;
  logic [31:0] ip_src, ip_dst;

  // UDP parser -> echo app
  logic [7:0]  udp_tdata;
  logic        udp_tvalid, udp_tready, udp_tlast;
  logic [15:0] udp_src_port_pre, udp_dst_port_pre, udp_payload_len_pre;
  logic        udp_hdr_pre_valid;

  // Meta assembler -> echo app
  logic                      rx_meta_valid, rx_meta_ready;
  udp_packet_meta_t rx_meta;

  // Echo app -> TX builder
  logic                      tx_meta_valid, tx_meta_ready;
  udp_packet_meta_t tx_meta;
  logic [7:0]  echo_tdata;
  logic        echo_tvalid, echo_tready, echo_tlast;

  // TX builder -> pkt FIFO
  logic [7:0]  txb_tdata;
  logic        txb_tvalid, txb_tready, txb_tlast;

  // --- GMII RX MAC ---
  gmii_rx_mac #(
    .EXPECT_PREAMBLE(EXPECT_PREAMBLE)
  ) u_mac (
    .clk_i        (eth_rx_clk_i),
    .rst_ni       (rst_w),
    .gmii_rxd_i   (eth_rxd_i),
    .gmii_rx_dv_i (eth_rxdv_i),
    .gmii_rx_er_i (eth_rxer_i),
    .m_axis_tdata (mac_tdata),
    .m_axis_tvalid(mac_tvalid),
    .m_axis_tready(mac_tready),
    .m_axis_tlast (mac_tlast),
    .m_axis_tuser (mac_tuser),
    .frame_done_o (mac_frame_done_w)
  );

  // --- Ethernet Header Parser (L2) ---
  eth_header_parser u_eth (
    .clk_i             (eth_rx_clk_i),
    .rst_ni            (rst_w),
    .local_mac_i       (LOCAL_MAC),
    .accept_broadcast_i(1'b1),
    .promiscuous_i     (1'b1),  // L2: accept all; L3+L4 still strict
    .s_axis_tdata      (mac_tdata),
    .s_axis_tvalid     (mac_tvalid),
    .s_axis_tready     (mac_tready),
    .s_axis_tlast      (mac_tlast),
    .s_axis_tuser      (mac_tuser),
    .m_axis_tdata      (eth_tdata),
    .m_axis_tvalid     (eth_tvalid),
    .m_axis_tready     (eth_tready),
    .m_axis_tlast      (eth_tlast),
    .m_axis_tuser      (),
    .rx_dst_mac_o      (eth_dst_mac),
    .rx_src_mac_o      (eth_src_mac),
    .rx_ethertype_o    (),
    .hdr_valid_o       (eth_hdr_valid_w),
    .drop_o            (),
    .hdr_done_pulse_o  (mac_hdr_done_w),
    .hdr_accept_pulse_o(mac_accept_pulse_w),
    .hdr_drop_pulse_o  (mac_drop_pulse_w),
    .dbg_dst_mac_o     (dbg_dst_mac_w),
    .dbg_mac_accept_o  (dbg_mac_accept_w)
  );

  // --- IPv4 Header Parser (L3) ---
  ipv4_header_parser u_ip (
    .clk_i        (eth_rx_clk_i),
    .rst_ni       (rst_w),
    .local_ip_i   (LOCAL_IP),
    .promiscuous_i(1'b1),  // L3: accept all; L4 still strict
    .s_axis_tdata (eth_tdata),
    .s_axis_tvalid(eth_tvalid),
    .s_axis_tready(eth_tready),
    .s_axis_tlast (eth_tlast),
    .m_axis_tdata (ip_tdata),
    .m_axis_tvalid(ip_tvalid),
    .m_axis_tready(ip_tready),
    .m_axis_tlast (ip_tlast),
    .src_ip_o     (ip_src),
    .dst_ip_o     (ip_dst),
    .protocol_o   (),
    .hdr_valid_o  (ipv4_hdr_valid_w)
  );

  // --- UDP Header Parser (L4) ---
  udp_header_parser #(.DROP_NONZERO_CHECKSUM(1'b0)) u_udp (
    .clk_i                   (eth_rx_clk_i),
    .rst_ni                  (rst_w),
    .local_port_i            (UDP_PORT),
    .promiscuous_i           (1'b1),  // L4: accept all; isolate upstream
    .s_axis_tdata            (ip_tdata),
    .s_axis_tvalid           (ip_tvalid),
    .s_axis_tready           (ip_tready),
    .s_axis_tlast            (ip_tlast),
    .s_axis_tuser            (1'b0),
    .m_axis_tdata            (udp_tdata),
    .m_axis_tvalid           (udp_tvalid),
    .m_axis_tready           (udp_tready),
    .m_axis_tlast            (udp_tlast),
    .m_axis_tuser            (),
    .src_port_o              (),
    .dst_port_o              (),
    .udp_len_o               (),
    .payload_len_o           (),
    .hdr_valid_o             (),
    .hdr_pre_valid_o         (udp_hdr_pre_valid),
    .src_port_pre_o          (udp_src_port_pre),
    .dst_port_pre_o          (udp_dst_port_pre),
    .payload_len_pre_o       (udp_payload_len_pre),
    .drop_o                  (),
    .udp_checksum_zero_o     (),
    .udp_checksum_unchecked_o()
  );

  // --- RX Metadata Assembler ---
  udp_rx_meta_assembler u_meta (
    .clk_i              (eth_rx_clk_i),
    .rst_ni             (rst_w),
    .eth_src_mac_i      (eth_src_mac),
    .eth_dst_mac_i      (eth_dst_mac),
    .ip_src_i           (ip_src),
    .ip_dst_i           (ip_dst),
    .udp_src_port_i     (udp_src_port_pre),
    .udp_dst_port_i     (udp_dst_port_pre),
    .udp_payload_len_i  (udp_payload_len_pre),
    .udp_hdr_pre_valid_i(udp_hdr_pre_valid),
    .rx_meta_valid_o    (rx_meta_valid),
    .rx_meta_ready_i    (rx_meta_ready),
    .rx_meta_o          (rx_meta)
  );

  // --- UDP Echo Application ---
  udp_echo_app u_echo (
    .clk_i          (eth_rx_clk_i),
    .rst_ni         (rst_w),
    .rx_meta_valid_i(rx_meta_valid),
    .rx_meta_ready_o(rx_meta_ready),
    .rx_meta_i      (rx_meta),
    .s_axis_tdata   (udp_tdata),
    .s_axis_tvalid  (udp_tvalid),
    .s_axis_tready  (udp_tready),
    .s_axis_tlast   (udp_tlast),
    .tx_meta_valid_o(tx_meta_valid),
    .tx_meta_ready_i(tx_meta_ready),
    .tx_meta_o      (tx_meta),
    .m_axis_tdata   (echo_tdata),
    .m_axis_tvalid  (echo_tvalid),
    .m_axis_tready  (echo_tready),
    .m_axis_tlast   (echo_tlast)
  );

  // --- UDP/IPv4 TX Builder ---
  udp_ipv4_tx_builder u_txb (
    .clk_i          (eth_rx_clk_i),
    .rst_ni         (rst_w),
    .tx_meta_valid_i(tx_meta_valid),
    .tx_meta_ready_o(tx_meta_ready),
    .tx_meta_i      (tx_meta),
    .s_axis_tdata   (echo_tdata),
    .s_axis_tvalid  (echo_tvalid),
    .s_axis_tready  (echo_tready),
    .s_axis_tlast   (echo_tlast),
    .m_axis_tdata   (txb_tdata),
    .m_axis_tvalid  (txb_tvalid),
    .m_axis_tready  (txb_tready),
    .m_axis_tlast   (txb_tlast),
    .ipv4_total_len_o()
  );

  // ===========================================================================
  // CDC: packet FIFO  ({tlast, tdata}, 9-bit, 2048 entries)
  // Written RX-domain as tx_builder emits bytes; read TX-domain by controller.
  // ===========================================================================
  logic       pkt_wr_ready;
  logic [8:0] pkt_rd_data;
  logic       pkt_rd_valid, pkt_rd_ready;

  // Gate packet start on meta_fifo having space; mid-packet only needs pkt_fifo.
  // Prevents pkt_fifo from holding a full packet with no matching meta entry.
  // txb_fire_w is the true AXI-S handshake: byte is consumed only when both
  // builder and FIFO agree.
  logic txb_started_q;
  logic txb_fire_w;
  // One-register skid buffer between TX builder and pkt_fifo.
  // Breaks the hdr_cnt_q -> hdr_q mux -> M9K porta_datain_reg routing path
  // (was 8.325 ns at 125 MHz, leaving only +0.001 ns slack at 85 C slow corner).
  // Credit: accept new txb byte only when skid slot is free OR FIFO drains it.
  logic [8:0] pkt_wr_skid_q;
  logic       pkt_wr_skid_v_q;
  logic       pkt_wr_credit_w;

  assign pkt_wr_credit_w = !pkt_wr_skid_v_q || pkt_wr_ready;
  assign txb_tready      = pkt_wr_credit_w && (txb_started_q || meta_wr_ready);
  assign txb_fire_w      = txb_tvalid && txb_tready;

  always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
    if (!rst_w) begin
      txb_started_q  <= 1'b0;
      pkt_wr_skid_q  <= 9'h000;
      pkt_wr_skid_v_q <= 1'b0;
    end else begin
      if (txb_fire_w && txb_tlast) txb_started_q <= 1'b0;
      else if (txb_fire_w)         txb_started_q <= 1'b1;
      if (pkt_wr_credit_w) begin
        pkt_wr_skid_q   <= {txb_tlast, txb_tdata};
        pkt_wr_skid_v_q <= txb_fire_w;
      end
    end
  end

  async_fifo #(
    .DATA_WIDTH(9),
    .DEPTH     (2048)
  ) u_pkt_fifo (
    .wr_clk_i  (eth_rx_clk_i),
    .wr_rst_ni (rst_w),
    .wr_data_i (pkt_wr_skid_q),
    .wr_valid_i(pkt_wr_skid_v_q),
    .wr_ready_o(pkt_wr_ready),
    .rd_clk_i  (eth_tx_clk_i),
    .rd_rst_ni (rst_w),
    .rd_data_o (pkt_rd_data),
    .rd_valid_o(pkt_rd_valid),
    .rd_ready_i(pkt_rd_ready)
  );

  // ===========================================================================
  // CDC: meta FIFO  ({dst_mac, src_mac}, 96-bit, 4 entries)
  // Written after the last packet byte is accepted into pkt_fifo.
  // ===========================================================================
  logic [47:0] meta_latch_dst_q, meta_latch_src_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
    if (!rst_w) begin
      meta_latch_dst_q <= '0;
      meta_latch_src_q <= '0;
    end else if (tx_meta_valid && tx_meta_ready) begin
      meta_latch_dst_q <= tx_meta.dst_mac;
      meta_latch_src_q <= tx_meta.src_mac;
    end
  end

  // Registered stage before meta FIFO write -- cuts FF->RAM critical path.
  // commit_pending_q separates last-byte detection from FIFO write, removing
  // the txb_tlast enable path to meta_wr_data_q and ensuring meta is written
  // even if meta_wr_ready is low at the moment of the last packet byte.
  logic [95:0] meta_wr_data_q;
  logic        meta_wr_valid_q;
  logic        meta_wr_ready;
  logic        commit_pending_q;

  always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
    if (!rst_w) begin
      meta_wr_data_q   <= '0;
      meta_wr_valid_q  <= 1'b0;
      commit_pending_q <= 1'b0;
    end else begin
      meta_wr_valid_q <= 1'b0;
      if (commit_pending_q && meta_wr_ready) begin
        meta_wr_valid_q  <= 1'b1;
        commit_pending_q <= 1'b0;
      end
      // Last byte accepted into pkt_fifo: latch meta and mark commit pending.
      // This overrides the clear above if both conditions fire simultaneously.
      if (txb_fire_w && txb_tlast) begin
        meta_wr_data_q   <= {meta_latch_dst_q, meta_latch_src_q};
        commit_pending_q <= 1'b1;
      end
    end
  end

  logic [95:0] meta_rd_data;
  logic        meta_rd_valid, meta_rd_ready;

  async_fifo #(
    .DATA_WIDTH(96),
    .DEPTH     (32)
  ) u_meta_fifo (
    .wr_clk_i  (eth_rx_clk_i),
    .wr_rst_ni (rst_w),
    .wr_data_i (meta_wr_data_q),
    .wr_valid_i(meta_wr_valid_q),
    .wr_ready_o(meta_wr_ready),
    .rd_clk_i  (eth_tx_clk_i),
    .rd_rst_ni (rst_w),
    .rd_data_o (meta_rd_data),
    .rd_valid_o(meta_rd_valid),
    .rd_ready_i(meta_rd_ready)
  );

  // ===========================================================================
  // TX CLOCK DOMAIN — TX controller FSM + gmii_tx_mac
  // Beacon: if idle >~1 s with no echo pending, transmit a 2-byte broadcast
  // frame (src=LOCAL_MAC, dst=FF:FF:FF:FF:FF:FF, payload 0xBE 0xAC).
  // If beacon appears in pcap -> GMII TX physical path works.
  // If beacon invisible      -> GTxCLK/PHY/PCB issue.
  // ===========================================================================
  typedef enum logic [1:0] {
    TXC_IDLE  = 2'd0,
    TXC_START = 2'd1,
    TXC_DATA  = 2'd2
  } txc_state_e;

  txc_state_e txc_state_q;
  logic [47:0] txc_dst_mac_q, txc_src_mac_q;
  logic        txmac_s_tready, tx_mac_busy_w;
  logic        bcn_mode_q;  // 1 = current TX is a diagnostic beacon
  logic        bcn_byte_q;  // 0 = first byte (0xBE), 1 = second byte (0xAC)

  // Beacon idle counter: 2^27 cycles = ~1.07 s at 125 MHz
  logic [26:0] bcn_cnt_q;
  logic        bcn_pending_q;
  logic        bcn_fire_w;
  assign bcn_fire_w = (txc_state_q == TXC_IDLE) && bcn_pending_q &&
                      !meta_rd_valid && !tx_mac_busy_w;

  always_ff @(posedge eth_tx_clk_i or negedge rst_w) begin
    if (!rst_w) begin
      bcn_cnt_q     <= '0;
      bcn_pending_q <= 1'b0;
    end else if (bcn_fire_w) begin
      bcn_cnt_q     <= '0;
      bcn_pending_q <= 1'b0;
    end else if (txc_state_q == TXC_IDLE && !meta_rd_valid) begin
      if (&bcn_cnt_q) begin
        bcn_cnt_q     <= '0;
        bcn_pending_q <= 1'b1;
      end else begin
        bcn_cnt_q <= bcn_cnt_q + 1'b1;
      end
    end else begin
      bcn_cnt_q <= '0;
    end
  end

  always_ff @(posedge eth_tx_clk_i or negedge rst_w) begin
    if (!rst_w) begin
      txc_state_q   <= TXC_IDLE;
      txc_dst_mac_q <= '0;
      txc_src_mac_q <= '0;
      bcn_mode_q    <= 1'b0;
      bcn_byte_q    <= 1'b0;
    end else begin
      case (txc_state_q)
        TXC_IDLE: begin
          bcn_byte_q <= 1'b0;
          if (meta_rd_valid && pkt_rd_valid && !tx_mac_busy_w) begin
            txc_dst_mac_q <= meta_rd_data[95:48];
            txc_src_mac_q <= meta_rd_data[47:0];
            bcn_mode_q    <= 1'b0;
            txc_state_q   <= TXC_START;
          end else if (bcn_fire_w) begin
            txc_dst_mac_q <= 48'hFFFF_FFFF_FFFF;
            txc_src_mac_q <= LOCAL_MAC;
            bcn_mode_q    <= 1'b1;
            txc_state_q   <= TXC_START;
          end
        end
        TXC_START: begin
          txc_state_q <= TXC_DATA;
        end
        TXC_DATA: begin
          if (bcn_mode_q) begin
            if (txmac_s_tready) begin
              bcn_byte_q <= ~bcn_byte_q;
              if (bcn_byte_q) txc_state_q <= TXC_IDLE;
            end
          end else begin
            if (pkt_rd_valid && txmac_s_tready && pkt_rd_data[8])
              txc_state_q <= TXC_IDLE;
          end
        end
        default: txc_state_q <= TXC_IDLE;
      endcase
    end
  end

  assign meta_rd_ready = (txc_state_q == TXC_IDLE) && meta_rd_valid && pkt_rd_valid && !tx_mac_busy_w;
  assign pkt_rd_ready  = (txc_state_q == TXC_DATA) && txmac_s_tready && !bcn_mode_q;

  logic [7:0] txmac_s_tdata;
  logic       txmac_s_tvalid, txmac_s_tlast;
  always_comb begin
    if (bcn_mode_q) begin
      txmac_s_tdata  = bcn_byte_q ? 8'hAC : 8'hBE;
      txmac_s_tvalid = (txc_state_q == TXC_DATA);
      txmac_s_tlast  = (txc_state_q == TXC_DATA) && bcn_byte_q;
    end else begin
      txmac_s_tdata  = pkt_rd_data[7:0];
      txmac_s_tlast  = pkt_rd_data[8];
      txmac_s_tvalid = pkt_rd_valid && (txc_state_q == TXC_DATA);
    end
  end

  // --- GMII TX MAC ---
  gmii_tx_mac u_tx_mac (
    .clk_i         (eth_tx_clk_i),
    .rst_ni        (rst_w),
    .tx_dst_mac_i  (txc_dst_mac_q),
    .tx_src_mac_i  (txc_src_mac_q),
    .tx_ethertype_i(16'h0800),
    .tx_start_i    (txc_state_q == TXC_START),
    .tx_busy_o     (tx_mac_busy_w),
    .tx_done_o     (),
    .s_axis_tdata  (txmac_s_tdata),
    .s_axis_tvalid (txmac_s_tvalid),
    .s_axis_tready (txmac_s_tready),
    .s_axis_tlast  (txmac_s_tlast),
    .gmii_txd_o    (eth_txd_o),
    .gmii_tx_en_o  (eth_txen_o),
    .gmii_tx_er_o  (eth_txer_o)
  );

  // ===========================================================================
  // UART stream tap: captures first 20 bytes of each RX frame -> J11[0] (M2)
  // ===========================================================================
  eth_stream_tap #(
    .CAPTURE_BYTES(20),
    .SYS_CLK_HZ  (SYS_CLK_HZ),
    .BAUD_RATE   (115200)
  ) u_tap (
    .eth_rx_clk_i   (eth_rx_clk_i),
    .sys_clk_i      (sys_clk_i),
    .rst_ni         (rst_w),
    .s_axis_tdata_i (mac_tdata),
    .s_axis_tvalid_i(mac_tvalid),
    .s_axis_tlast_i (mac_tlast),
    .uart_tx_o      (uart_tap_tx_o)
  );

  // ===========================================================================
  // LED diagnostics (sys_clk domain; async signals synchronized inside module)
  // ===========================================================================
  eth_debug_leds #(
    .SYS_CLK_HZ    (SYS_CLK_HZ),
    .ETH_CLK_HZ    (125_000_000),
    .ACTIVITY_MS   (150),
    .LED_ACTIVE_LOW(1'b1),
    .CLK_TEST      (1'b0),
    .LAYER_DEBUG   (1'b0),
    .MAC_DEBUG     (1'b0)
  ) u_leds (
    .sys_clk_i           (sys_clk_i),
    .eth_rx_clk_i        (eth_rx_clk_i),
    .eth_tx_clk_i        (eth_tx_clk_i),
    .rst_ni              (rst_w),
    .phy_reset_done_i    (phy_rst_done_w),
    .rx_dv_i             (eth_rxdv_i),
    .udp_accept_i        (rx_meta_valid),
    .tx_active_i         (tx_mac_busy_w),
    .tx_en_i             (eth_txen_o),
    .layer_frame_done_i  (mac_frame_done_w),
    .layer_eth_hdr_i     (eth_hdr_valid_w),
    .layer_ipv4_hdr_i    (ipv4_hdr_valid_w),
    .mac_hdr_done_i      (mac_hdr_done_w),
    .mac_accept_i        (mac_accept_pulse_w),
    .mac_drop_i          (mac_drop_pulse_w),
    .led_o               (led_o)
  );

  // ===========================================================================
  // Sticky (latched) debug signals — set once on first event, cleared by rst_w.
  // Persist after test so user can read LEDs while FPGA is idle.
  // ===========================================================================
  logic latch_rx_meta_q;     // UDP meta assembled (parsers working)
  logic latch_tx_meta_q;     // echo_app entered ST_TX_META (full RX done)
  logic latch_txb_fire_q;    // TX builder fired at least one byte
  logic latch_meta_wr_q;     // meta FIFO write committed
  logic latch_udp_tvalid_q;  // udp_parser emitted >= 1 payload byte
  logic latch_udp_tlast_q;   // udp_parser fired tlast (full payload delivered)
  logic latch_mac_accept_q;  // L2 accepted >= 1 frame
  logic latch_mac_drop_q;    // L2 dropped >= 1 frame
  logic latch_ipv4_acc_q;    // L3 entered ST_PAYLOAD >= once

  always_ff @(posedge eth_rx_clk_i or negedge rst_w) begin
    if (!rst_w) begin
      latch_rx_meta_q    <= 1'b0;
      latch_tx_meta_q    <= 1'b0;
      latch_txb_fire_q   <= 1'b0;
      latch_meta_wr_q    <= 1'b0;
      latch_udp_tvalid_q <= 1'b0;
      latch_udp_tlast_q  <= 1'b0;
      latch_mac_accept_q <= 1'b0;
      latch_mac_drop_q   <= 1'b0;
      latch_ipv4_acc_q   <= 1'b0;
    end else begin
      if (rx_meta_valid)            latch_rx_meta_q    <= 1'b1;
      if (tx_meta_valid)            latch_tx_meta_q    <= 1'b1;
      if (txb_fire_w)               latch_txb_fire_q   <= 1'b1;
      if (meta_wr_valid_q)          latch_meta_wr_q    <= 1'b1;
      if (udp_tvalid && udp_tready) latch_udp_tvalid_q <= 1'b1;
      if (udp_tvalid && udp_tlast)  latch_udp_tlast_q  <= 1'b1;
      if (mac_accept_pulse_w)       latch_mac_accept_q <= 1'b1;
      if (mac_drop_pulse_w)         latch_mac_drop_q   <= 1'b1;
      if (ipv4_hdr_valid_w)         latch_ipv4_acc_q   <= 1'b1;
    end
  end

  // TX-domain sticky: did gmii_tx_mac ever become busy (actually transmit)?
  logic latch_tx_busy_q;
  always_ff @(posedge eth_tx_clk_i or negedge rst_w) begin
    if (!rst_w) latch_tx_busy_q <= 1'b0;
    else if (tx_mac_busy_w) latch_tx_busy_q <= 1'b1;
  end

  // ===========================================================================
  // Debug bus J10/J11
  // J10 (dbg_mac_data_o[7:0]): txb_tdata when txb_tvalid, else pkt_rd_data,
  //   idle: {latch_mac_drop_q, latch_mac_accept_q, latch_ipv4_acc_q,
  //          dbg_mac_accept_w, dbg_dst_mac_w[15:12]}
  //   idle[7] = latch_mac_drop_q   L2 dropped >= 1 frame
  //   idle[6] = latch_mac_accept_q L2 accepted >= 1 frame
  //   idle[5] = latch_ipv4_acc_q   L3 entered ST_PAYLOAD >= once
  //   idle[4] = dbg_mac_accept_w   was first-frame accepted at L2?
  //   idle[3:0] = dbg_dst_mac_w[47:44]  top nibble of first-frame MAC byte0
  //     (FPGA_MAC 0x00 -> nibble=0x0=0000, broadcast 0xff -> 1111, unknown=other)
  // J11 (dbg_ctrl_o[7:0]) — STICKY bits persist after test:
  //   [7] = latch_tx_busy_q   (sticky: gmii_tx_mac ever became busy = GMII TX fired)
  //   [6] = latch_meta_wr_q   (sticky: meta FIFO was ever written -> TX triggered)
  //   [5] = latch_txb_fire_q  (sticky: TX builder ever fired a byte)
  //   [4] = latch_tx_meta_q   (sticky: echo_app ever completed RX -> entered TX_META)
  //   [3] = latch_rx_meta_q   (sticky: UDP meta ever assembled -> parsers working)
  //   [2] = latch_udp_tvalid_q (sticky: udp_parser emitted >= 1 payload byte)
  //   [1] = latch_udp_tlast_q  (sticky: udp_parser fired tlast)
  //   [0] = tx_meta_valid      (live: echo_app in ST_TX_META right now)
  //
  // J10 idle decode (when txb inactive, pkt_rd inactive):
  //   bit7=s,bit6=s -> L2 NEVER accepted or dropped anything (GMII RX dead?)
  //   bit7=n,bit6=s -> L2 dropped frames but accepted none (MAC filter broken)
  //   bit7=x,bit6=n,bit5=s -> L2 accepted but L3 NEVER entered payload (IP filter broken)
  //   bit7=x,bit6=n,bit5=n -> L3 OK; if J11[3]=0 -> UDP/meta filter broken
  // ===========================================================================
  assign dbg_mac_data_o = txb_tvalid   ? txb_tdata         :
                          pkt_rd_valid ? pkt_rd_data[7:0]  :
                          {latch_mac_drop_q, latch_mac_accept_q, latch_ipv4_acc_q,
                           dbg_mac_accept_w, dbg_dst_mac_w[47:44]};
  assign dbg_ctrl_o = {
    latch_tx_busy_q,    // bit7
    latch_meta_wr_q,    // bit6
    latch_txb_fire_q,   // bit5
    latch_tx_meta_q,    // bit4
    latch_rx_meta_q,    // bit3
    latch_udp_tvalid_q, // bit2 - sticky: udp_parser emitted payload byte
    latch_udp_tlast_q,  // bit1 - sticky: udp_parser fired tlast
    tx_meta_valid       // bit0 - live: echo_app in ST_TX_META now
  };

endmodule

`endif // ETHERNET_TEST_03_TOP_SV
