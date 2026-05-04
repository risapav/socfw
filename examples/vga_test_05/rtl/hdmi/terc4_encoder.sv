`default_nettype none

import hdmi_pkg::*;

// TERC4 encoder: maps a 4-bit nibble to a 10-bit TMDS data-island symbol.
// Table from HDMI 1.3 spec, section 5.4.3.
// Output is registered for timing closure at higher pixel clocks.
module terc4_encoder (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic [3:0] nibble_i,
  output tmds_word_t tmds_o
);

  tmds_word_t lut;

  always_comb begin
    unique case (nibble_i)
      4'h0: lut = 10'b1010011100;
      4'h1: lut = 10'b1001100011;
      4'h2: lut = 10'b1011100100;
      4'h3: lut = 10'b1011100010;
      4'h4: lut = 10'b0101110001;
      4'h5: lut = 10'b0100011110;
      4'h6: lut = 10'b0110001110;
      4'h7: lut = 10'b0100111100;
      4'h8: lut = 10'b1011001100;
      4'h9: lut = 10'b0100111001;
      4'ha: lut = 10'b0110011100;
      4'hb: lut = 10'b1011000110;
      4'hc: lut = 10'b1010001110;
      4'hd: lut = 10'b1001110001;
      4'he: lut = 10'b0101100011;
      4'hf: lut = 10'b1011000011;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) tmds_o <= 10'b1010011100;
    else         tmds_o <= lut;
  end

endmodule
