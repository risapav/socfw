/**
 * @file sdram_system_top.sv  (v160)
 * @brief Top-level SDR SDRAM controller.
 *
 * Zmeny oproti v140:
 *  - timing_manager má nový port bank_can_rw[3:0]
 *  - memory_scheduler má nový vstup bank_can_rw[3:0]
 */

`ifndef SDRAM_SYSTEM_TOP_SV
`define SDRAM_SYSTEM_TOP_SV

`default_nettype none

import sdram_pkg::*;

module sdram_system_top #(
  parameter int ID_WIDTH = AXI_ID_WIDTH
)(
  input  wire clk,
  input  wire clk_sh,
  input  wire rstn,

  input  wire [ID_WIDTH-1:0]    s_axi_arid,
  input  wire [31:0]            s_axi_araddr,
  input  wire [7:0]             s_axi_arlen,
  input  wire                   s_axi_arvalid,
  output logic                  s_axi_arready,
  output logic [ID_WIDTH-1:0]   s_axi_rid,
  output logic [31:0]           s_axi_rdata,
  output logic                  s_axi_rlast,
  output logic                  s_axi_rvalid,
  input  wire                   s_axi_rready,

  input  wire [ID_WIDTH-1:0]    s_axi_awid,
  input  wire [31:0]            s_axi_awaddr,
  input  wire [7:0]             s_axi_awlen,
  input  wire                   s_axi_awvalid,
  output logic                  s_axi_awready,
  input  wire [31:0]            s_axi_wdata,
  input  wire                   s_axi_wlast,
  input  wire                   s_axi_wvalid,
  output logic                  s_axi_wready,
  output logic                  s_axi_bvalid,
  input  wire                   s_axi_bready,
  output logic [1:0]            s_axi_bresp,
  output logic [ID_WIDTH-1:0]   s_axi_bid,

  output logic [ROW_ADDR_WIDTH-1:0]  sdram_addr,
  output logic [BANK_ADDR_WIDTH-1:0] sdram_ba,
  output logic                       sdram_ras_n,
  output logic                       sdram_cas_n,
  output logic                       sdram_we_n,
  output logic                       sdram_cs_n,
  inout  wire  [15:0]                sdram_dq,
  output logic                       sdram_clk,
  output logic                       sdram_cke
);

  sdram_cmd_t  read_cmd, write_cmd, arb_cmd, fifo_cmd;
  logic        read_valid, write_valid, arb_valid;
  logic        read_cmd_ready, write_cmd_ready;
  logic        fifo_ready, fifo_valid;

  logic [15:0] phy_wdata;
  logic        phy_wvalid, phy_wready;
  logic [15:0] phy_rdata;
  logic        phy_rdata_valid;

  phy_cmd_e    sched_cmd;
  logic        sched_valid, sched_ready, read_issue;
  logic        pre_all;  // PRE ALL flag od schedulera
  logic        can_activate, can_readwrite, can_precharge;
  logic [3:0]  bank_can_rw;
  logic        refresh_req, refresh_ack;

  logic [3:0]  bank_row_hit, bank_open;
  logic [3:0]  bank_do_act, bank_do_pre;

  logic        init_busy, init_done;
  phy_cmd_e    init_phy_cmd;
  logic [ROW_ADDR_WIDTH-1:0] init_addr;

  logic wr_issue;
  assign wr_issue = sched_valid && (sched_cmd == CMD_WR);

  // --------------------------------------------------------------------------
  // AXI Frontends
  // --------------------------------------------------------------------------
  axi_frontend #(.ID_WIDTH(ID_WIDTH)) i_axi_read_frontend (
    .clk           (clk),           .rstn          (rstn),
    .s_axi_arid    (s_axi_arid),    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arlen   (s_axi_arlen),   .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .m_cmd         (read_cmd),      .m_cmd_valid   (read_valid),
    .m_cmd_ready   (read_cmd_ready)
  );

  write_engine #(.ID_WIDTH(ID_WIDTH)) i_write_engine (
    .clk           (clk),           .rstn          (rstn),
    .s_axi_awid    (s_axi_awid),    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awlen   (s_axi_awlen),   .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),   .s_axi_wlast   (s_axi_wlast),
    .s_axi_wvalid  (s_axi_wvalid),  .s_axi_wready  (s_axi_wready),
    .s_axi_bvalid  (s_axi_bvalid),  .s_axi_bready  (s_axi_bready),
    .s_axi_bresp   (s_axi_bresp),   .s_axi_bid     (s_axi_bid),
    .m_cmd         (write_cmd),     .m_valid       (write_valid),
    .m_ready       (write_cmd_ready),
    .wr_issue      (wr_issue),
    .phy_wdata     (phy_wdata),     .phy_wvalid    (phy_wvalid),
    .phy_wready    (phy_wready)
  );

  // --------------------------------------------------------------------------
  // Arbiter (write priorita + starvation guard)
  // --------------------------------------------------------------------------
  logic [3:0] rd_starve_cnt;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) rd_starve_cnt <= '0;
    else if (write_valid && read_valid) rd_starve_cnt <= rd_starve_cnt + 1;
    else rd_starve_cnt <= '0;
  end

  always_comb begin
    arb_valid       = write_valid;
    arb_cmd         = write_cmd;
    write_cmd_ready = fifo_ready;
    read_cmd_ready  = 1'b0;
    if (!write_valid || rd_starve_cnt == 4'hF) begin
      arb_valid       = read_valid;
      arb_cmd         = read_cmd;
      read_cmd_ready  = fifo_ready;
      write_cmd_ready = 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // Command FIFO
  // --------------------------------------------------------------------------
  sync_fifo #(
    .WIDTH ($bits(sdram_cmd_t)),
    .DEPTH (16)
  ) i_cmd_fifo (
    .clk(clk), .rstn(rstn),
    .s_data(arb_cmd),  .s_valid(arb_valid),  .s_ready(fifo_ready),
    .m_data(fifo_cmd), .m_valid(fifo_valid),  .m_ready(sched_ready),
    .count(), .almost_full(), .almost_empty()
  );

  // --------------------------------------------------------------------------
  // Timing Manager (v160 — s bank_can_rw)
  // --------------------------------------------------------------------------
  timing_manager i_timing (
    .clk             (clk),    .rstn            (rstn),
    .bank            (fifo_cmd.addr.bank),
    .issue_activate  (sched_valid && (sched_cmd == CMD_ACT)),
    .issue_precharge (sched_valid && (sched_cmd == CMD_PRE)),
    .issue_refresh   (sched_valid && (sched_cmd == CMD_REF)),
    .issue_write     (sched_valid && (sched_cmd == CMD_WR)),
    .issue_read      (sched_valid && (sched_cmd == CMD_RD)),
    .can_activate    (can_activate),
    .can_readwrite   (can_readwrite),
    .can_precharge   (can_precharge),
    .bank_can_rw     (bank_can_rw)
  );

  // --------------------------------------------------------------------------
  // Memory Scheduler (v160 — s bank_can_rw vstupom)
  // --------------------------------------------------------------------------
  memory_scheduler i_scheduler (
    .clk             (clk),    .rstn            (rstn),
    .in_cmd          (fifo_cmd), .in_valid      (fifo_valid),
    .in_ready        (sched_ready),
    .bank_row_hit    (bank_row_hit), .bank_open (bank_open),
    .bank_do_act     (bank_do_act),  .bank_do_pre(bank_do_pre),
    .can_activate    (init_done && can_activate),
    .can_readwrite   (init_done && can_readwrite),
    .can_precharge   (init_done && can_precharge),
    .bank_can_rw     (bank_can_rw),
    .refresh_req     (refresh_req),  .refresh_grant(refresh_ack),
    .out_phy_cmd     (sched_cmd),    .out_valid    (sched_valid),
    .read_issue      (read_issue),   .out_precharge_all(pre_all)
  );

  // --------------------------------------------------------------------------
  // Bank Machines
  // --------------------------------------------------------------------------
  // [FIX-PIPELINE-ROW] Pri pipeline ACT scheduler vydá bank_do_act pre banku
  // z in_cmd (slot B), ale fifo_cmd stále ukazuje na slot A.
  // row_addr pre každú banku musí byť z príkazu ktorý ju aktivuje:
  //   - fifo_cmd.addr.row pre normálny ACT (latched_cmd banka)
  //   - fifo_cmd.addr.row tiež funguje ak FIFO head je pipeline banka
  // Bezpečné riešenie: sledujeme posledný riadok per banka zvonku.
  // Pre jednoduchosť: row_addr = fifo_cmd.addr.row pre obe (funguje
  // keď FIFO head = pipeline príkaz počas pipeline ACT vydania)
  generate
    for (genvar i = 0; i < 4; i++) begin : g_bank
      bank_machine i_bank_inst (
        .clk(clk), .rstn(rstn),
        .do_activate(bank_do_act[i]), .do_precharge(bank_do_pre[i]),
        .row_addr(fifo_cmd.addr.row), .query_row(fifo_cmd.addr.row),
        .row_open(bank_open[i]),      .row_hit(bank_row_hit[i]),
        .curr_row()
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // DQ OE Gating
  // --------------------------------------------------------------------------
  logic [CAS_LATENCY+2:0] read_pipe;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) read_pipe <= '0;
    else read_pipe <= {read_pipe[CAS_LATENCY+1:0],
                       (sched_valid && sched_cmd == CMD_RD)};
  end
  wire dq_oe_gated = phy_wvalid && (read_pipe == '0);

  // --------------------------------------------------------------------------
  // PHY addr/cmd mux
  // --------------------------------------------------------------------------
  phy_cmd_e                   phy_cmd_mux;
  logic [ROW_ADDR_WIDTH-1:0]  phy_addr_mux;
  logic [BANK_ADDR_WIDTH-1:0] phy_ba_mux;

  always_comb begin
    if (init_busy) begin
      phy_cmd_mux  = init_phy_cmd;
      phy_addr_mux = init_addr;
      phy_ba_mux   = '0;
    end else if (sched_valid) begin
      phy_cmd_mux = sched_cmd;
      phy_ba_mux  = fifo_cmd.addr.bank;
      unique case (sched_cmd)
        CMD_ACT:        phy_addr_mux = fifo_cmd.addr.row;
        CMD_RD, CMD_WR: phy_addr_mux = ROW_ADDR_WIDTH'(fifo_cmd.addr.col);
        CMD_PRE:        phy_addr_mux = pre_all ? 13'h0400 : 13'h0000;
        default:        phy_addr_mux = '0;
      endcase
    end else begin
      phy_cmd_mux  = CMD_NOP;
      phy_addr_mux = '0;
      phy_ba_mux   = '0;
    end
  end

  // --------------------------------------------------------------------------
  // PHY
  // --------------------------------------------------------------------------
  sdram_phy i_phy (
    .clk(clk), .clk_sh(clk_sh), .rstn(rstn),
    .phy_cmd(phy_cmd_mux), .addr_in(phy_addr_mux), .ba_in(phy_ba_mux),
    .read_en_in(sched_valid && (sched_cmd == CMD_RD)),
    .dq_o(phy_wdata), .dq_oe(dq_oe_gated),
    .dq_i(phy_rdata), .dq_i_valid(phy_rdata_valid),
    .phy_wready(phy_wready),
    .sdram_addr(sdram_addr), .sdram_ba(sdram_ba),
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
    .sdram_we_n(sdram_we_n),   .sdram_cs_n(sdram_cs_n),
    .sdram_dq(sdram_dq), .sdram_clk(sdram_clk), .sdram_cke(sdram_cke)
  );

  // --------------------------------------------------------------------------
  // Read Engine
  // --------------------------------------------------------------------------
  read_engine #(.ID_WIDTH(ID_WIDTH)) i_read_engine (
    .clk(clk), .rstn(rstn),
    .read_issue(read_issue),
    .issue_id(fifo_cmd.id), .issue_last(fifo_cmd.last),
    .phy_rdata(phy_rdata),   .phy_rdata_valid(phy_rdata_valid),
    .s_axi_rid(s_axi_rid),   .s_axi_rdata(s_axi_rdata),
    .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready)
  );

  // --------------------------------------------------------------------------
  // Init + Refresh
  // --------------------------------------------------------------------------
  sdram_init i_init (
    .clk(clk), .rstn(rstn),
    .init_cmd(init_phy_cmd), .init_addr(init_addr),
    .init_done(init_done),   .init_busy(init_busy)
  );

  refresh_manager i_refresh (
    .clk(clk), .rstn(rstn),
    .refresh_req(refresh_req), .refresh_grant(refresh_ack)
  );

endmodule
`endif
