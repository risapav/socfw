`default_nettype none

module blink_test #(
  parameter integer CLK_FREQ = 50000000
)(
  input  wire       SYS_CLK,
  output reg  [5:0] ONB_LEDS
);

  reg [31:0] counter;

  always @(posedge SYS_CLK) begin
    counter <= counter + 1'b1;
    ONB_LEDS <= counter[25:20];
  end

endmodule

`default_nettype wire
