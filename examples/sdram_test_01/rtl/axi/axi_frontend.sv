/**
 * @file axi_frontend.sv  (v170)
 * @brief AXI Read Address frontend — refaktorovaný s axi_gearbox.
 *
 * Gearbox FSM je teraz v axi_gearbox.sv.
 * axi_frontend je tenký wrapper — len prepája AR channel na gearbox.
 */

`ifndef AXI_FRONTEND_SV
`define AXI_FRONTEND_SV

`default_nettype none

import sdram_pkg::*;

module axi_frontend #(
  parameter int ID_WIDTH = AXI_ID_WIDTH
)(
  input  wire                 clk,
  input  wire                 rstn,

  input  wire [ID_WIDTH-1:0]  s_axi_arid,
  input  wire [31:0]          s_axi_araddr,
  input  wire [7:0]           s_axi_arlen,
  input  wire                 s_axi_arvalid,
  output logic                s_axi_arready,

  output sdram_cmd_t          m_cmd,
  output logic                m_cmd_valid,
  input  wire                 m_cmd_ready
);

  axi_gearbox #(
    .ID_WIDTH   (ID_WIDTH),
    .WRITE_MODE (0)   // read mode
  ) i_gearbox (
    .clk           (clk),            .rstn          (rstn),
    .s_addr        (s_axi_araddr),   .s_len         (s_axi_arlen),
    .s_id          (s_axi_arid),     .s_avalid      (s_axi_arvalid),
    .s_aready      (s_axi_arready),
    // Write data porty — nepoužité v read mode
    .s_data        ('0),             .s_wlast       (1'b0),
    .s_valid       (1'b0),           .s_ready       (),
    // Command output
    .m_cmd         (m_cmd),          .m_valid       (m_cmd_valid),
    .m_ready       (m_cmd_ready),
    // Status — nepoužité v axi_frontend
    .phase1_done   (),
    .is_phase1     (),
    .is_idle       (),
    // Data latch — nepoužité v read mode
    .data_latch_out(),
    .last_latch_out()
  );

endmodule
`endif
