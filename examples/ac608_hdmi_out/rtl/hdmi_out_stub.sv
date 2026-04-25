`default_nettype none

// Stub HDMI output module — replace with actual DVI/TMDS encoder
module hdmi_out (
    input  wire        PIXEL_CLK,
    output logic [3:0] TMDS_P,
    output logic [3:0] TMDS_N
);

    assign TMDS_P = 4'b0000;
    assign TMDS_N = 4'b1111;

endmodule
