// @file  ddio_out_sim.sv
// @brief Behavioral model of Altera ALTDDIO_OUT for ModelSim simulation.
//
// @details
//   Replaces the Quartus megafunction ddio_out.v (which instantiates altddio_out
//   from altera_mf) for simulation targets that do not have the Altera sim library.
//
//   OE_REG = UNREGISTERED: no extra pipeline register on the output enable.
//   Data path: datain_h / datain_l are registered at posedge outclock.
//     - posedge half-period (outclock=1): dataout = registered datain_h
//     - negedge half-period (outclock=0): dataout = registered datain_l
//
//   This matches the Cyclone IV E ALTDDIO_OUT behaviour used in
//   tmds_phy_ddr_aligned.sv.  Port widths are identical to the Quartus wrapper.

`default_nettype none

module ddio_out (
  input  [0:0] datain_h,
  input  [0:0] datain_l,
  input        outclock,
  output [0:0] dataout
);

  logic h_reg = 1'b0;
  logic l_reg = 1'b0;

  always_ff @(posedge outclock) begin
    h_reg <= datain_h[0];
    l_reg <= datain_l[0];
  end

  assign dataout[0] = outclock ? h_reg : l_reg;

endmodule
