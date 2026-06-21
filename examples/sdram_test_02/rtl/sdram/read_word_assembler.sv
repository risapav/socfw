/**
 * @file read_word_assembler.sv
 * @brief Assembles two consecutive 16-bit SDRAM halfwords into one 32-bit word.
 * @param SDRAM_DATA_WIDTH Width of each halfword from the PHY (default 16).
 * @param WORD_DATA_WIDTH  Width of the assembled output word (default 32).
 * @details
 *   hw_first=1: first (low) halfword — stored internally.
 *   hw_first=0: second (high) halfword — combined and emitted.
 *   Assembly: word_data = {hw_data, stored_low} = {high, low}.
 *   Example: low=16'hA5C3, high=16'h1234 -> word=32'h1234_A5C3.
 *   word_valid pulses for exactly one clk cycle after the second halfword.
 */
`ifndef READ_WORD_ASSEMBLER_SV
`define READ_WORD_ASSEMBLER_SV

`default_nettype none

module read_word_assembler #(
  parameter int SDRAM_DATA_WIDTH = 16,
  parameter int WORD_DATA_WIDTH  = 32
)(
  input  logic                        clk,
  input  logic                        rstn,

  input  logic                        hw_valid,
  input  logic [SDRAM_DATA_WIDTH-1:0] hw_data,
  input  logic                        hw_first,

  output logic                        word_valid,
  output logic [WORD_DATA_WIDTH-1:0]  word_data
);

  logic [SDRAM_DATA_WIDTH-1:0] low_word_r;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      word_valid <= 1'b0;
      word_data  <= '0;
      low_word_r <= '0;
    end else begin
      word_valid <= 1'b0;
      if (hw_valid) begin
        if (hw_first) begin
          low_word_r <= hw_data;
        end else begin
          word_valid <= 1'b1;
          word_data  <= {hw_data, low_word_r};
        end
      end
    end
  end

endmodule

`default_nettype wire
`endif // READ_WORD_ASSEMBLER_SV
