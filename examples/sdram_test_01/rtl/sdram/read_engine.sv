/**
 * @file read_engine.sv  (v160)
 * @brief AXI Read Datapath s Gearboxom a skid bufferom (16-bit SDRAM -> 32-bit AXI).
 *
 * Zmeny oproti v150:
 *  - 1-entry skid buffer na AXI R vystupe:
 *    ak RREADY=0 a pride dalsi beat, ulozi sa do skid registra
 *    pri RREADY=1 sa drainuje: output -> user, skid -> output
 *  - Gearbox a output rozdelene do samostatnych always_ff blokov
 *  - Zname obmedzenie: overflow ak RREADY=0 dlhsie nez je medzibeat interval
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

  localparam int PIPE_LEN   = CAS_LATENCY + 2;
  localparam int META_WIDTH = ID_WIDTH + 1;

  // ==========================================================================
  // Gearbox: phase tracking + low word capture
  // ==========================================================================
  logic [15:0] low_word_reg;
  logic        read_phase;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      read_phase   <= 1'b0;
      low_word_reg <= '0;
    end else if (phy_rdata_valid) begin
      read_phase <= ~read_phase;
      if (read_phase == 1'b0)
        low_word_reg <= phy_rdata;
    end
  end

  // CMD phase toggle: 0=phase0 CMD_RD, 1=phase1 CMD_RD.
  // Push do meta FIFO len pri phase1 (1 push na AXI beat).
  logic read_cmd_phase;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) read_cmd_phase <= 1'b0;
    else if (read_issue) read_cmd_phase <= ~read_cmd_phase;
  end

  // ==========================================================================
  // Meta FIFO: {id, last} pre kazdy AXI beat
  // Push: read_issue && read_cmd_phase  (= phase1 CMD_RD, 1x na beat)
  // Pop:  phy_rdata_valid && read_phase==1  (= druhy halfword assemblovany)
  // ==========================================================================
  logic [META_WIDTH-1:0] meta_s_data;
  logic [META_WIDTH-1:0] meta_m_data;
  logic                  meta_m_valid;
  logic                  meta_pop;

  assign meta_s_data = {issue_id, issue_last};
  assign meta_pop    = phy_rdata_valid && (read_phase == 1'b1);

  localparam int META_FIFO_DEPTH = (PIPE_LEN > 8) ? PIPE_LEN : 8;

  sync_fifo #(
    .WIDTH (META_WIDTH),
    .DEPTH (META_FIFO_DEPTH)
  ) i_meta_fifo (
    .clk         (clk),
    .rstn        (rstn),
    .s_data      (meta_s_data),
    .s_valid     (read_issue && read_cmd_phase),
    .s_ready     (),
    .m_data      (meta_m_data),
    .m_valid     (meta_m_valid),
    .m_ready     (meta_pop),
    .count       (),
    .almost_full (),
    .almost_empty()
  );

  // ==========================================================================
  // Assembled beat (kombinacne) — platne ked read_phase==1 && phy_rdata_valid
  // ==========================================================================
  logic [31:0]         beat_rdata_w;
  logic [ID_WIDTH-1:0] beat_rid_w;
  logic                beat_rlast_w;
  logic                beat_valid_w;

  assign beat_rdata_w = {phy_rdata, low_word_reg};
  assign beat_rid_w   = meta_m_data[ID_WIDTH:1];
  assign beat_rlast_w = meta_m_data[0];
  assign beat_valid_w = phy_rdata_valid && (read_phase == 1'b1);

  // ==========================================================================
  // AXI R output register + 1-entry skid buffer
  //
  // Routing logika:
  //   beat_valid && (output volny alebo sa prave konsumuje) -> priamo do output
  //   beat_valid && output busy (rvalid=1, rready=0)        -> do skid
  //   rready && rvalid && skid_valid (bez noveho beatu)     -> drain skid -> output
  //   rready && rvalid && !skid_valid                       -> rvalid = 0
  // ==========================================================================
  logic [31:0]         skid_rdata;
  logic [ID_WIDTH-1:0] skid_rid;
  logic                skid_rlast;
  logic                skid_valid;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
      s_axi_rid    <= '0;
      s_axi_rlast  <= 1'b0;
      skid_valid   <= 1'b0;
      skid_rdata   <= '0;
      skid_rid     <= '0;
      skid_rlast   <= 1'b0;
    end else begin
      if (beat_valid_w) begin
        if (!s_axi_rvalid || s_axi_rready) begin
          // Output volny alebo sa prave konsumuje -> novy beat do output
          s_axi_rdata  <= beat_rdata_w;
          s_axi_rid    <= beat_rid_w;
          s_axi_rlast  <= beat_rlast_w;
          s_axi_rvalid <= 1'b1;
        end else begin
          // Output busy (rvalid=1, rready=0) -> uloz do skid
          skid_rdata <= beat_rdata_w;
          skid_rid   <= beat_rid_w;
          skid_rlast <= beat_rlast_w;
          skid_valid <= 1'b1;
        end
      end else begin
        // Ziadny novy beat: spracuj consume + drain
        if (s_axi_rready && s_axi_rvalid) begin
          if (skid_valid) begin
            s_axi_rdata  <= skid_rdata;
            s_axi_rid    <= skid_rid;
            s_axi_rlast  <= skid_rlast;
            s_axi_rvalid <= 1'b1;
            skid_valid   <= 1'b0;
          end else begin
            s_axi_rvalid <= 1'b0;
          end
        end
      end
    end
  end

endmodule
`endif
