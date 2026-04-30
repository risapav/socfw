/**
 * @file seven_seg_mux_packed.sv
 * @brief Wrapper pre seven_seg_mux s podporou zbalených (packed) portov.
 * @details Tento modul preberá dáta ako jeden široký vektor, čo uľahčuje
 *          portovanie modulu v prostrediach, ktoré nepodporujú polia v portoch.
 */

`ifndef SEVEN_SEG_MUX_PACKED_SV
`define SEVEN_SEG_MUX_PACKED_SV

`default_nettype none

module seven_seg_mux_packed #(
  parameter int CLOCK_FREQ_HZ    = 50_000_000,
  parameter int NUM_DIGITS       = 6,
  parameter int DIGIT_REFRESH_HZ = 250,
  parameter bit COMMON_ANODE     = 1'b1
)(
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [NUM_DIGITS*4-1:0] digits_i,   // packed: digit[0] = bits[3:0], digit[N-1] = bits[N*4-1:(N-1)*4]
  input  logic [NUM_DIGITS-1:0]   dots_i,

  output logic [NUM_DIGITS-1:0]   digit_sel_o,
  output logic [7:0]              segment_sel_o,
  output logic [$clog2(NUM_DIGITS)-1:0] current_digit_o
);

  // Unpacked polia pre interné prepojenie s jadrom
  logic [3:0] digits_unpacked [NUM_DIGITS];
  logic       dots_unpacked   [NUM_DIGITS];

  // Rozbalenie vektora pomocou generate bloku
  genvar i;
  generate
    for (i = 0; i < NUM_DIGITS; i = i + 1) begin : g_unpack
      assign digits_unpacked[i] = digits_i[i*4 +: 4];
      assign dots_unpacked[i]   = dots_i[i];
    end
  endgenerate

  // Inštancia jadra multiplexora
  seven_seg_mux #(
    .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ),
    .NUM_DIGITS(NUM_DIGITS),
    .DIGIT_REFRESH_HZ(DIGIT_REFRESH_HZ),
    .COMMON_ANODE(COMMON_ANODE)
  ) u_core (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .digits_i(digits_unpacked),
    .dots_i(dots_unpacked),
    .digit_sel_o(digit_sel_o),
    .segment_sel_o(segment_sel_o),
    .current_digit_o(current_digit_o)
  );

endmodule

`endif
