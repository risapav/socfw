/**
 * @file        mdio_com.sv
 * @brief       MDIO komunikacny interface.
 * @details     Modul pre seriovu komunikaciu s PHY cez rozhranie MDIO a MDC.
 */

`ifndef MDIO_COM_SV
`define MDIO_COM_SV

`default_nettype none

module mdio_com (
  input  wire         mdc_i,
  inout  wire         mdio_io,
  input  wire         rst_ni,
  input  wire  [23:0] mdio_data_i,
  input  wire         start_i,
  output logic        tr_end_o
);

  logic [5:0] cyc_count_q;
  logic       reg_mdio_q;

  assign mdio_io = reg_mdio_q ? 1'bz : 1'b0;

  always_ff @(posedge mdc_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cyc_count_q <= 6'b111111;
    end else begin
      if (!start_i) begin
        cyc_count_q <= 6'd0;
      end else if (cyc_count_q < 6'b111111) begin
        cyc_count_q <= cyc_count_q + 1'b1;
      end
    end
  end

  always_ff @(negedge mdc_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tr_end_o   <= 1'b0;
      reg_mdio_q <= 1'b1;
    end else begin
      case (cyc_count_q)
        6'd0:  begin tr_end_o <= 1'b0; reg_mdio_q <= 1'b1; end
        6'd1:  reg_mdio_q <= 1'b0; // Start
        6'd2:  reg_mdio_q <= 1'b1;
        6'd3:  reg_mdio_q <= 1'b0; // OP CODE 01 = write
        6'd4:  reg_mdio_q <= 1'b1;
        6'd5:  reg_mdio_q <= 1'b0; // PHY ADDRESS
        6'd6:  reg_mdio_q <= 1'b0;
        6'd7:  reg_mdio_q <= 1'b0;
        6'd8:  reg_mdio_q <= 1'b0;
        6'd9:  reg_mdio_q <= 1'b1;
        6'd10: reg_mdio_q <= mdio_data_i[20]; // Reg address
        6'd11: reg_mdio_q <= mdio_data_i[19];
        6'd12: reg_mdio_q <= mdio_data_i[18];
        6'd13: reg_mdio_q <= mdio_data_i[17];
        6'd14: reg_mdio_q <= mdio_data_i[16];
        6'd15: reg_mdio_q <= 1'b1; // Turn around
        6'd16: reg_mdio_q <= 1'b0;
        6'd17: reg_mdio_q <= mdio_data_i[15]; // Reg data
        6'd18: reg_mdio_q <= mdio_data_i[14];
        6'd19: reg_mdio_q <= mdio_data_i[13];
        6'd20: reg_mdio_q <= mdio_data_i[12];
        6'd21: reg_mdio_q <= mdio_data_i[11];
        6'd22: reg_mdio_q <= mdio_data_i[10];
        6'd23: reg_mdio_q <= mdio_data_i[9];
        6'd24: reg_mdio_q <= mdio_data_i[8];
        6'd25: reg_mdio_q <= mdio_data_i[7];
        6'd26: reg_mdio_q <= mdio_data_i[6];
        6'd27: reg_mdio_q <= mdio_data_i[5];
        6'd28: reg_mdio_q <= mdio_data_i[4];
        6'd29: reg_mdio_q <= mdio_data_i[3];
        6'd30: reg_mdio_q <= mdio_data_i[2];
        6'd31: reg_mdio_q <= mdio_data_i[1];
        6'd32: reg_mdio_q <= mdio_data_i[0];
        6'd33: begin reg_mdio_q <= 1'b1; tr_end_o <= 1'b1; end
        default: begin reg_mdio_q <= 1'b1; tr_end_o <= 1'b0; end
      endcase
    end
  end

endmodule

`endif // MDIO_COM_SV
