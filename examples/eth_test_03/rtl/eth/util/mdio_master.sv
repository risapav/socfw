/**
 * @file mdio_master.sv
 * @brief MDIO Clause 22 Master for PHY configuration.
 * @details Implements 32-bit frame generation for Clause 22 PHY management.
 */

`ifndef MDIO_MASTER_SV
`define MDIO_MASTER_SV

`default_nettype none

module mdio_master (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  output      logic        mdc_o,
  inout  wire              mdio_io,

  input  wire logic        start_i,
  input  wire logic [4:0]  phy_addr_i,
  input  wire logic [4:0]  reg_addr_i,
  input  wire logic [15:0] data_i,
  input  wire logic        write_i,
  output      logic [15:0] data_o,
  output      logic        done_o
);

  // Divider pre MDC (napr. 50MHz / 20 = 2.5MHz)
  logic [4:0] div_cnt;
  logic       mdc_en;

  // FSM a interné registre
  typedef enum logic [3:0] {
    ST_IDLE, ST_PRE, ST_START, ST_OP, ST_ADDR, ST_TA, ST_DATA, ST_DONE
  } state_e;
  state_e state_q;

  logic [5:0]  bit_cnt;
  logic [31:0] shift_reg;
  logic        mdio_out;
  logic        mdio_oe;

  assign mdio_io = mdio_oe ? mdio_out : 1'bz;

  // MDC generátor
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_cnt <= '0;
      mdc_en  <= 1'b0;
    end else if (state_q != ST_IDLE) begin
      div_cnt <= div_cnt + 1'b1;
      mdc_en  <= (div_cnt == 5'd19); // Toggle každých 20 cyklov
    end else begin
      div_cnt <= '0;
      mdc_en  <= 1'b0;
    end
  end
  assign mdc_o = (state_q != ST_IDLE) ? (div_cnt > 5'd9) : 1'b0;

  // FSM spracovania rámca
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      bit_cnt <= '0;
    end else if (mdc_en) begin
      case (state_q)
        ST_IDLE: if (start_i) begin
          state_q   <= ST_PRE;
          shift_reg <= 32'hFFFF_FFFF;
          bit_cnt   <= 6'd31;
        end
        ST_PRE: begin
          if (bit_cnt == 0) begin
            state_q   <= ST_START;
            shift_reg <= {2'b01, (write_i ? 2'b01 : 2'b10), phy_addr_i, reg_addr_i};
            bit_cnt   <= 6'd13;
          end else bit_cnt <= bit_cnt - 1'b1;
        end
        // ... ďalšie stavy pre ST_START, ST_OP, ST_ADDR, ST_TA, ST_DATA ...
        ST_DONE: state_q <= ST_IDLE;
      endcase
    end
  end

  // Výstupná logika (tri-state)
  assign mdio_oe  = (state_q != ST_TA || !write_i); // Read počas TA je vysoká impedancia
  assign mdio_out = shift_reg[31];
  assign done_o   = (state_q == ST_DONE);

endmodule

`endif // MDIO_MASTER_SV
