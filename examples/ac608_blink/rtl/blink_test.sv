`default_nettype none

module blink_test #(
    parameter int CLK_FREQ = 50_000_000
) (
    input  wire        SYS_CLK,
    output logic [4:0] ONB_LEDS
);

    localparam int HALF = CLK_FREQ / 2;

    logic [24:0] cnt;

    always_ff @(posedge SYS_CLK) begin
        if (cnt == HALF - 1) begin
            cnt     <= '0;
            ONB_LEDS <= ONB_LEDS + 1;
        end else begin
            cnt <= cnt + 1;
        end
    end

endmodule
