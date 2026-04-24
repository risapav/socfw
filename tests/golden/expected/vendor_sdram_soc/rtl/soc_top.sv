// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  input  wire SYS_CLK,
  input  wire RESET_N,
  output wire [12:0] ZS_ADDR,
  output wire [1:0] ZS_BA,
  inout  wire [15:0] ZS_DQ,
  output wire [1:0] ZS_DQM,
  output wire ZS_CS_N,
  output wire ZS_WE_N,
  output wire ZS_RAS_N,
  output wire ZS_CAS_N,
  output wire ZS_CKE,
  output wire ZS_CLK
);


  // Interface instances
  bus_if if_cpu0_main (); // master endpoint on main  bus_if if_ram_main (); // slave endpoint on main  bus_if if_bridge_sdram0_main (); // slave endpoint on main  bus_if if_error_main (); // error slave for main  wishbone_if if_sdram0_wb (); // Wishbone side for bridge_sdram0


  // Bus fabrics
  simple_bus_fabric #(
    .NSLAVES(2),
    .BASE_ADDR("{ 32'h80000000, 32'h00000000 }"),
    .ADDR_MASK("{ 32'h00FFFFFF, 32'h00007FFF }")
  ) u_fabric_main (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N)
    ,.m_bus(if_cpu0_main.slave)
    ,.s_bus[0](if_ram_main.master)
    ,.s_bus[1](if_bridge_sdram0_main.master)
    ,.err_bus(if_error_main.master)
  ); // simple_bus fabric 'main'
  // Module instances
  simple_bus_to_wishbone_bridge u_bridge_sdram0 (
    .sbus(if_bridge_sdram0_main.slave),
    .m_wb(if_sdram0_wb.master)
  ); // simple_bus -> wishbone bridge  simple_bus_error_slave u_error_main (
    .bus(if_error_main.slave)
  ); // error slave for main  dummy_cpu u_cpu0 (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N),
    .bus(if_cpu0_main.master)
  ); // dummy_cpu  soc_ram #(
    .RAM_BYTES(32768),
    .INIT_FILE("")
  ) u_ram (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N),
    .bus(if_ram_main.slave)
  ); // RAM @ 0x00000000  sdram_ctrl u_sdram0 (
    .clk(SYS_CLK),
    .reset_n(RESET_N),
    .zs_addr(ZS_ADDR),
    .zs_ba(ZS_BA),
    .zs_dq(ZS_DQ),
    .zs_dqm(ZS_DQM),
    .zs_cs_n(ZS_CS_N),
    .zs_we_n(ZS_WE_N),
    .zs_ras_n(ZS_RAS_N),
    .zs_cas_n(ZS_CAS_N),
    .zs_cke(ZS_CKE),
    .zs_clk(ZS_CLK),
    .wb(if_sdram0_wb.slave)
  );


  // socfw compatibility bridge scaffold
  // NOTE: temporary Phase-1/Phase-2 insertion until full bridge RTL planning is implemented.
  simple_bus_to_wishbone_bridge u_bridge_sdram0 (
    .clk(1'b0),
    .reset_n(1'b1),
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

endmodule : soc_top
`default_nettype wire
