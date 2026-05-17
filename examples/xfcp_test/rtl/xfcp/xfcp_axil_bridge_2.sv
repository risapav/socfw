/**
 * @file xfcp_axil_bridge.sv
 * @version 1.2.0
 *
 * @brief XFCP ↔ AXI-Lite bridge top-level modul.
 *
 * @details
 * Tento modul prepája tri hlavné komponenty XFCP datapathu:
 *
 *   1. RX Parser       – dekóduje XFCP request paket
 *   2. AXI Engine      – vykonáva AXI-Lite transakcie
 *   3. TX Packetizer   – vytvára XFCP response paket
 *
 * Datapath pipeline:
 *
 *     XFCP RX Stream
 *            │
 *            ▼
 *      xfcp_rx_parser
 *            │
 *            ▼
 *      xfcp_axi_engine
 *            │
 *            ▼
 *      xfcp_tx_packetizer
 *            │
 *            ▼
 *     XFCP TX Stream
 *
 * Parser extrahuje hlavičku a payload,
 * engine vykoná AXI operáciu a
 * packetizer odošle odpoveď.
 */

`ifndef XFCP_AXIL_BRIDGE
`define XFCP_AXIL_BRIDGE

`default_nettype none

import axi_pkg::*;
import xfcp_pkg::*;

module xfcp_axil_bridge #(

  // ------------------------------------------------------------
  // Konfiguračné parametre
  // ------------------------------------------------------------

  parameter bit LITTLE_ENDIAN = 1'b1,

  parameter int AXI_ADDR_WIDTH = 32,
  parameter int AXI_DATA_WIDTH = 32,

  // Identifikačný string pre XFCP ID command
  parameter logic [127:0] ID_STR = "XFCP-AXIL-BRIDGE"

) (
  // ------------------------------------------------------------
  // Clock / Reset
  // ------------------------------------------------------------

  input  wire clk,
  input  wire rst_n,

  // ------------------------------------------------------------
  // XFCP AXI-Stream vstup
  // ------------------------------------------------------------

  axi4s_if.slave xfcp_in,

  // ------------------------------------------------------------
  // XFCP AXI-Stream výstup
  // ------------------------------------------------------------

  axi4s_if.master xfcp_out,

  // ------------------------------------------------------------
  // AXI-Lite master interface
  // ------------------------------------------------------------

  axi4lite_if.master m_axil

);

  // ============================================================
  // Interné prepojovacie signály
  // ============================================================

  //----------------------------------------------------------------
  // Request header (Parser → Engine)
  //----------------------------------------------------------------

  xfcp_req_hdr_t req_hdr;

  logic req_valid;
  logic req_ready;

  //----------------------------------------------------------------
  // Write datapath (Parser → Engine)
  //----------------------------------------------------------------

  logic [AXI_DATA_WIDTH-1:0] wdata;
  logic                      wdata_valid;
  logic                      wdata_ready;

  //----------------------------------------------------------------
  // Read datapath (Engine → Packetizer)
  //----------------------------------------------------------------

  logic [AXI_DATA_WIDTH-1:0] rdata;
  logic                      rdata_valid;
  logic                      rdata_ready;

  //----------------------------------------------------------------
  // Response control (Engine → Packetizer)
  //----------------------------------------------------------------

  logic resp_start;
  logic [7:0] resp_type;

  logic resp_done_engine;

  //----------------------------------------------------------------
  // Packetizer status
  //----------------------------------------------------------------

  logic packetizer_idle;

  // ============================================================
  // 1. XFCP RX Parser
  // ============================================================

  /**
   * Parser rozoberá XFCP request paket.
   *
   * Výstupy:
   *   • req_hdr     – dekódovaná hlavička
   *   • wdata       – payload dáta
   */

  xfcp_rx_parser #(
    .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
    .FIFO_DEPTH     (16)
  )
  i_rx_parser (

    .clk   (clk),
    .rst_n (rst_n),

    // AXI-Stream vstup
    .s_axis_tdata  (xfcp_in.TDATA),
    .s_axis_tvalid (xfcp_in.TVALID),
    .s_axis_tready (xfcp_in.TREADY),
    .s_axis_tlast  (xfcp_in.TLAST),

    // Request interface
    .req_hdr   (req_hdr),
    .req_valid (req_valid),
    .req_ready (req_ready),

    // Payload interface
    .write_data       (wdata),
    .write_data_valid (wdata_valid),
    .write_data_ready (wdata_ready),

    // Routing passthrough (nevyužité v tomto bridge)
    .pass_valid (),
    .pass_data  (),
    .pass_last  (),
    .pass_ready (1'b0),

    // Diagnostika
    .error_protocol ()

  );

  // ============================================================
  // 2. AXI Transaction Engine
  // ============================================================

  /**
   * Engine vykonáva AXI-Lite operácie:
   *
   *   READ
   *   WRITE
   *   ID
   *
   * Podľa requestu z parsera.
   */

  xfcp_axi_engine #(
    .LITTLE_ENDIAN  (LITTLE_ENDIAN),
    .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
  )
  i_axi_engine (

    .clk   (clk),
    .rst_n (rst_n),

    // AXI-Lite master interface
    .m_axil (m_axil),

    //----------------------------------------------------------
    // Request interface
    //----------------------------------------------------------

    .req_hdr   (req_hdr),
    .req_valid (req_valid),
    .req_ready (req_ready),

    //----------------------------------------------------------
    // Write payload
    //----------------------------------------------------------

    .write_data       (wdata),
    .write_data_valid (wdata_valid),
    .write_data_ready (wdata_ready),

    //----------------------------------------------------------
    // Read payload
    //----------------------------------------------------------

    .read_data        (rdata),
    .read_data_valid  (rdata_valid),
    .read_data_ready  (rdata_ready),

    //----------------------------------------------------------
    // Response control
    //----------------------------------------------------------

    .resp_start (resp_start),
    .resp_type  (resp_type),

    .resp_done (resp_done_engine),

    //----------------------------------------------------------
    // Synchronizácia s packetizerom
    //----------------------------------------------------------

    .packetizer_idle_i (packetizer_idle),

    //----------------------------------------------------------
    // Diagnostika
    //----------------------------------------------------------

    .error_timeout ()

  );

  // ============================================================
  // 3. XFCP TX Packetizer
  // ============================================================

  /**
   * Packetizer serializuje AXI read dáta
   * do XFCP response paketu.
   */

  xfcp_tx_packetizer #(
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
    .XFCP_ID_STR    (ID_STR)
  )
  i_tx_packetizer (

    .clk   (clk),
    .rst_n (rst_n),

    //----------------------------------------------------------
    // AXI-Stream výstup
    //----------------------------------------------------------

    .m_axis_tdata  (xfcp_out.TDATA),
    .m_axis_tvalid (xfcp_out.TVALID),
    .m_axis_tready (xfcp_out.TREADY),
    .m_axis_tlast  (xfcp_out.TLAST),

    //----------------------------------------------------------
    // Response control
    //----------------------------------------------------------

    .resp_start (resp_start),
    .resp_type  (resp_type),

    //----------------------------------------------------------
    // Read payload
    //----------------------------------------------------------

    .read_data        (rdata),
    .read_data_valid  (rdata_valid),
    .read_data_ready  (rdata_ready),

    //----------------------------------------------------------
    // Synchronizácia
    //----------------------------------------------------------

    .resp_done_i     (resp_done_engine),
    .packetizer_idle (packetizer_idle),

    //----------------------------------------------------------
    // Packet complete pulse
    //----------------------------------------------------------

    .resp_done_o ()

  );

endmodule : xfcp_axil_bridge

`endif
