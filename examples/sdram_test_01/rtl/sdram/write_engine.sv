/**
 * @file write_engine.sv  (v170)
 * @brief AXI Write Datapath — refaktorovaný s axi_gearbox.
 *
 * Gearbox FSM (GS_IDLE/PHASE0/PHASE1) je teraz v axi_gearbox.sv.
 * write_engine obsahuje len AXI channel logiku špecifickú pre zápisy:
 *   - B channel (write response)
 *   - Data FIFO (sync_fifo pre 16-bit dáta synchronizované s cmd_fifo)
 *   - PHY write data výstup (registrovaný podľa wr_issue)
 */

`ifndef WRITE_ENGINE_SV
`define WRITE_ENGINE_SV

`default_nettype none

import sdram_pkg::*;

module write_engine #(
  parameter int ID_WIDTH        = AXI_ID_WIDTH,
  parameter int DATA_FIFO_DEPTH = 16
)(
  input  wire  clk,
  input  wire  rstn,

  // AXI Write Address Channel
  input  wire [ID_WIDTH-1:0]   s_axi_awid,
  input  wire [31:0]           s_axi_awaddr,
  input  wire [7:0]            s_axi_awlen,
  input  wire                  s_axi_awvalid,
  output logic                 s_axi_awready,

  // AXI Write Data Channel
  input  wire [AXI_DATA_WIDTH-1:0] s_axi_wdata,
  input  wire                      s_axi_wlast,
  input  wire                      s_axi_wvalid,
  output logic                     s_axi_wready,

  // AXI Write Response Channel
  output logic [ID_WIDTH-1:0]  s_axi_bid,
  output logic [1:0]           s_axi_bresp,
  output logic                 s_axi_bvalid,
  input  wire                  s_axi_bready,

  // Command Interface → cmd_fifo
  output sdram_cmd_t            m_cmd,
  output logic                  m_valid,
  input  wire                   m_ready,

  // Spätný signál od schedulera
  input  wire                   wr_issue,

  // PHY Write Data
  output logic [DATA_WIDTH-1:0] phy_wdata,
  output logic                  phy_wvalid,
  input  wire                   phy_wready
);

  // ==========================================================================
  // axi_gearbox inštancia (WRITE_MODE=1)
  // ==========================================================================
  logic [AXI_DATA_WIDTH-1:0] gb_data_latch;
  logic                      gb_last_latch;
  logic                      gb_phase1_done;
  logic                      gb_is_phase1;
  logic                      gb_is_idle;

  axi_gearbox #(
    .ID_WIDTH   (ID_WIDTH),
    .WRITE_MODE (1)
  ) i_gearbox (
    .clk           (clk),          .rstn          (rstn),
    .s_addr        (s_axi_awaddr), .s_len         (s_axi_awlen),
    .s_id          (s_axi_awid),   .s_avalid      (s_axi_awvalid),
    .s_aready      (s_axi_awready),
    .s_data        (s_axi_wdata),  .s_wlast       (s_axi_wlast),
    .s_valid       (s_axi_wvalid), .s_ready       (s_axi_wready),
    .m_cmd         (m_cmd),        .m_valid       (m_valid),
    .m_ready       (m_ready),
    .phase1_done   (gb_phase1_done),
    .is_phase1     (gb_is_phase1),
    .is_idle       (gb_is_idle),
    .data_latch_out(gb_data_latch),
    .last_latch_out(gb_last_latch)
  );

  // ==========================================================================
  // Data FIFO — sync_fifo pre 16-bit dáta
  // Push: pri každom m_valid && m_ready handshake
  // Pop:  pri wr_issue pulze od schedulera
  // ==========================================================================
  logic [DATA_WIDTH-1:0] df_s_data;
  logic                  df_s_valid;

  // Fáza 0: low word [15:0], Fáza 1: high word [31:16]
  assign df_s_data  = gb_is_phase1
                      ? gb_data_latch[AXI_DATA_WIDTH-1:DATA_WIDTH]
                      : gb_data_latch[DATA_WIDTH-1:0];
  assign df_s_valid = m_valid && m_ready;

  logic [DATA_WIDTH-1:0] df_m_data;
  logic                  df_m_valid;

  sync_fifo #(
    .WIDTH (DATA_WIDTH),
    .DEPTH (DATA_FIFO_DEPTH)
  ) i_data_fifo (
    .clk(clk),        .rstn(rstn),
    .s_data(df_s_data), .s_valid(df_s_valid), .s_ready(),
    .m_data(df_m_data), .m_valid(df_m_valid), .m_ready(wr_issue),
    .count(), .almost_full(), .almost_empty()
  );

  // PHY výstup — registrovaný pre zarovnanie s PHY command registrom
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      phy_wdata  <= '0;
      phy_wvalid <= 1'b0;
    end else begin
      phy_wvalid <= wr_issue;
      if (wr_issue)
        phy_wdata <= df_m_data;
    end
  end

  // ==========================================================================
  // B channel — write response
  // Vydáme po poslednom beate burstu (gb_phase1_done && gb_last_latch)
  // ==========================================================================
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= 2'b00;
      s_axi_bid    <= '0;
    end else begin
      if (gb_phase1_done && gb_last_latch) begin
        s_axi_bvalid <= 1'b1;
        s_axi_bid    <= m_cmd.id;  // id z gearboxu
        s_axi_bresp  <= 2'b00;
      end else if (s_axi_bready)
        s_axi_bvalid <= 1'b0;
    end
  end

endmodule
`endif // WRITE_ENGINE_SV
