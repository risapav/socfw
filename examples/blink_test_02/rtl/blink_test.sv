// =============================================================================
// MODULE: blink_test
// FILE:   src/soc/static/blink_test.sv
// BRIEF:  Minimal LED blink - verifies clock and LED pins
// =============================================================================
`default_nettype none

module blink_test #(
    parameter int CLK_FREQ = 50_000_000
) (
    input  wire       clk,
    input  wire       rstn,
    output wire [5:0] leds
);
    // blink ~1.5 Hz
    localparam int CNT_MAX = CLK_FREQ / 3;
    reg [$clog2(CNT_MAX)-1:0] cnt;
    reg blink;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cnt   <= '0;
            blink <= 1'b0;
        end else if (cnt == CNT_MAX - 1) begin
            cnt   <= '0;
            blink <= ~blink;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

    assign leds = {6{blink}};

endmodule : blink_test

`default_nettype wire
