// Stub: Quartus-generated SDRAM controller module placeholder
module sdram_ctrl (
  input  wire        clk,
  input  wire        reset_n,
  // Wishbone slave
  input  wire [31:0] wb_adr_i,
  input  wire [31:0] wb_dat_i,
  output wire [31:0] wb_dat_o,
  input  wire        wb_we_i,
  input  wire        wb_stb_i,
  input  wire        wb_cyc_i,
  output wire        wb_ack_o
);
  assign wb_dat_o = 32'hDEAD_BEEF;
  assign wb_ack_o = wb_stb_i & wb_cyc_i;
endmodule
