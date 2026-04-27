`default_nettype none

module soc_top (
  input wire RESET_N,
  input wire SYS_CLK,
  output wire [12:0] ZS_ADDR,
  output wire [1:0] ZS_BA,
  output wire ZS_CAS_N,
  output wire ZS_CKE,
  output wire ZS_CLK,
  output wire ZS_CS_N,
  output wire [15:0] ZS_DQ,
  output wire [1:0] ZS_DQM,
  output wire ZS_RAS_N,
  output wire ZS_WE_N
);

  wire reset_n;

  assign reset_n = RESET_N;

  sdram_ctrl sdram0 (
    .clk(SYS_CLK),
    .reset_n(reset_n),
    .zs_addr(ZS_ADDR),
    .zs_ba(ZS_BA),
    .zs_cas_n(ZS_CAS_N),
    .zs_cke(ZS_CKE),
    .zs_clk(ZS_CLK),
    .zs_cs_n(ZS_CS_N),
    .zs_dq(ZS_DQ),
    .zs_dqm(ZS_DQM),
    .zs_ras_n(ZS_RAS_N),
    .zs_we_n(ZS_WE_N)
  );

  simple_bus_to_wishbone_bridge u_bridge_sdram0 (
    .clk(SYS_CLK),
    .reset_n(reset_n),
    .sb_addr(32'h0),
    .sb_wdata(32'h0),
    .sb_be(4'h0),
    .sb_we(1'b0),
    .sb_valid(1'b0),
    .sb_rdata(),
    .sb_ready(),
    .wb_adr(),
    .wb_dat_w(),
    .wb_dat_r(32'h0),
    .wb_sel(),
    .wb_we(),
    .wb_cyc(),
    .wb_stb(),
    .wb_ack(1'b0)
  );

endmodule

`default_nettype wire
