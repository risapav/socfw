/**
 * @file read_engine.sv  (v140)
 * @brief AXI Read Datapath s Gearboxom (16-bit SDRAM → 32-bit AXI).
 *
 * Zmeny oproti v130:
 *  - Meta pipeline (id/last) nahradená sync_fifo inštanciou
 *  - PIPE_LEN = CAS_LATENCY + 2 (zarovnané s PHY latenciou)
 */

`ifndef READ_ENGINE_SV
`define READ_ENGINE_SV

`default_nettype none

import sdram_pkg::*;

module read_engine #(
  parameter int ID_WIDTH = AXI_ID_WIDTH
)(
  input  wire                   clk,
  input  wire                   rstn,

  input  wire                   read_issue,
  input  wire [ID_WIDTH-1:0]    issue_id,
  input  wire                   issue_last,

  input  wire [15:0]            phy_rdata,
  input  wire                   phy_rdata_valid,

  output logic [ID_WIDTH-1:0]   s_axi_rid,
  output logic [31:0]           s_axi_rdata,
  output logic                  s_axi_rlast,
  output logic                  s_axi_rvalid,
  input  wire                   s_axi_rready
);

  // PHY latencia = CAS_LATENCY + 2 clk cyklov
  localparam int PIPE_LEN   = CAS_LATENCY + 2;
  localparam int META_WIDTH = ID_WIDTH + 1;  // id + last

  // ==========================================================================
  // Gearbox registre — deklarácie pred sync_fifo (Questa vlog-2730)
  // ==========================================================================
  logic [15:0] low_word_reg;
  logic        read_phase;

  // ==========================================================================
  // Meta pipeline — sync_fifo pre (id, last)
  // Push: pri každom read_issue pulze
  // Pop:  pri druhej fáze gearboxu (read_phase==1 && phy_rdata_valid)
  // ==========================================================================
  logic [META_WIDTH-1:0] meta_s_data;
  logic [META_WIDTH-1:0] meta_m_data;
  logic                  meta_m_valid;
  logic                  meta_pop;

  assign meta_s_data = {issue_id, issue_last};
  assign meta_pop    = phy_rdata_valid && (read_phase == 1'b1);

  // Meta FIFO depth: must hold all in-flight reads
  // Pipeline scenario: up to 4 banks × 2 phases = 8 concurrent reads
  // DEPTH must be >= max outstanding read_issue pulses
  localparam int META_FIFO_DEPTH = (PIPE_LEN > 8) ? PIPE_LEN : 8;

  sync_fifo #(
    .WIDTH (META_WIDTH),
    .DEPTH (META_FIFO_DEPTH)
  ) i_meta_fifo (
    .clk          (clk),
    .rstn         (rstn),
    .s_data       (meta_s_data),
    .s_valid      (read_issue && issue_last),
    .s_ready      (),
    .m_data       (meta_m_data),
    .m_valid      (meta_m_valid),
    .m_ready      (meta_pop),
    .count        (),
    .almost_full  (),
    .almost_empty ()
  );

  // ==========================================================================
  // Gearbox: 2x 16-bit → 1x 32-bit AXI
  // ==========================================================================

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      read_phase   <= 1'b0;
      low_word_reg <= '0;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
      s_axi_rid    <= '0;
      s_axi_rlast  <= 1'b0;
    end else begin
      if (s_axi_rready) s_axi_rvalid <= 1'b0;

      if (phy_rdata_valid) begin
        if (read_phase == 1'b0) begin
          low_word_reg <= phy_rdata;
          read_phase   <= 1'b1;
        end else begin
          s_axi_rdata  <= {phy_rdata, low_word_reg};
          s_axi_rid    <= meta_m_data[ID_WIDTH:1];
          s_axi_rlast  <= meta_m_data[0];
          s_axi_rvalid <= 1'b1;
          read_phase   <= 1'b0;
        end
      end
    end
  end

endmodule
`endif
