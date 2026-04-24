`default_nettype none

module soc_top;

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

endmodule

`default_nettype wire
