`default_nettype none

module simple_bus_to_wishbone_bridge (
  input  wire        clk,
  input  wire        reset_n,

  input  wire [31:0] sb_addr,
  input  wire [31:0] sb_wdata,
  input  wire [3:0]  sb_be,
  input  wire        sb_we,
  input  wire        sb_valid,
  output wire [31:0] sb_rdata,
  output wire        sb_ready,

  output wire [31:0] wb_adr,
  output wire [31:0] wb_dat_w,
  input  wire [31:0] wb_dat_r,
  output wire [3:0]  wb_sel,
  output wire        wb_we,
  output wire        wb_cyc,
  output wire        wb_stb,
  input  wire        wb_ack
);

  assign wb_adr   = sb_addr;
  assign wb_dat_w = sb_wdata;
  assign wb_sel   = sb_be;
  assign wb_we    = sb_we;
  assign wb_cyc   = sb_valid;
  assign wb_stb   = sb_valid;

  assign sb_rdata = wb_dat_r;
  assign sb_ready = wb_ack;

endmodule

`default_nettype wire
