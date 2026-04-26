`default_nettype none

module blink_test #(
  parameter integer CLK_FREQ = 50000000
)(
  input  wire       clk_i,
  input  wire       rst_ni,
  output reg  [5:0] leds_o
);

  reg [31:0] counter;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      counter <= 0;
      leds_o <= 0;
    end else begin
      counter <= counter + 1'b1;
      leds_o <= counter[25:20];
    end
  end

endmodule

`default_nettype wire
