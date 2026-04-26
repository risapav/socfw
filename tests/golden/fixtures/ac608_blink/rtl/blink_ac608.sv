module blink_ac608 #(
    parameter CLK_FREQ = 50000000
) (
    input  logic clk,
    output logic [4:0] leds_o
);

localparam COUNT_MAX = CLK_FREQ / 2;
logic [25:0] counter;

always_ff @(posedge clk) begin
    if (counter == COUNT_MAX - 1) begin
        counter <= 0;
        leds_o <= ~leds_o;
    end else begin
        counter <= counter + 1;
    end
end

endmodule
