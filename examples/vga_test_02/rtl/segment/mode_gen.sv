`default_nettype none

// Automatický generátor VGA módu: každé CHANGE_PERIOD_MS ms inkrementuje
// mód 0-7, zobrazuje ho na seven-seg a posiela do picture_gen ako mode_i.
module mode_gen #(
    parameter int CLOCK_FREQ_HZ    = 50_000_000,
    parameter int NUM_DIGITS       = 3,
    parameter int CHANGE_PERIOD_MS = 2000
)(
    input  logic clk_i,
    input  logic rst_ni,

    output logic [2:0]              mode_o,
    output logic [NUM_DIGITS*4-1:0] digits_o,
    output logic [NUM_DIGITS-1:0]   dots_o
);

    localparam int CHANGE_CYCLES = CLOCK_FREQ_HZ / 1000 * CHANGE_PERIOD_MS;
    localparam int CNT_W = $clog2(CHANGE_CYCLES);

    logic [CNT_W-1:0] prescaler;
    logic [2:0]       mode_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            prescaler <= '0;
            mode_q    <= '0;
        end else if (prescaler == CNT_W'(CHANGE_CYCLES - 1)) begin
            prescaler <= '0;
            mode_q    <= mode_q + 1'b1;
        end else begin
            prescaler <= prescaler + 1'b1;
        end
    end

    assign mode_o = mode_q;

    // Rightmost digit zobrazuje aktuálny mód (0-7), ostatné sú 0.
    always_comb begin
        digits_o      = '0;
        digits_o[3:0] = 4'(mode_q);
    end

    assign dots_o = '0;

endmodule

`default_nettype wire
