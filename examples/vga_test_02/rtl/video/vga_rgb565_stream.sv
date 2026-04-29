`ifndef VGA_RGB565_STREAM_SV
`define VGA_RGB565_STREAM_SV

`timescale 1ns/1ns
`default_nettype none

import video_pkg::*;

module vga_rgb565_stream #(
    parameter int H_ACTIVE = 640,
    parameter int H_FP     = 16,
    parameter int H_SYNC   = 96,
    parameter int H_BP     = 48,

    parameter int V_ACTIVE = 480,
    parameter int V_FP     = 10,
    parameter int V_SYNC   = 2,
    parameter int V_BP     = 33,

    parameter bit HSYNC_POL = 1'b0,
    parameter bit VSYNC_POL = 1'b0,

    parameter rgb565_t DEFAULT_COLOR = BLACK,

    parameter int X_WIDTH = $clog2(H_ACTIVE),
    parameter int Y_WIDTH = $clog2(V_ACTIVE)
)(
    input  wire logic clk_i,
    input  wire logic rst_ni,

    input  rgb565_t   s_axis_data_i,
    input  wire logic s_axis_valid_i,
    output logic      s_axis_ready_o,
    input  wire logic s_axis_sof_i,
    input  wire logic s_axis_eol_i,
    input  wire logic s_axis_eof_i,

    output logic [4:0] vga_r_o,
    output logic [5:0] vga_g_o,
    output logic [4:0] vga_b_o,
    output logic       vga_hs_o,
    output logic       vga_vs_o,

    output logic       active_video_o,
    output logic       frame_start_o,
    output logic       line_start_o,

    output logic [X_WIDTH-1:0] pixel_x_o,
    output logic [Y_WIDTH-1:0] pixel_y_o,

    output logic       underflow_o,
    output logic       sync_error_o
);

    localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    localparam int H_CNT_WIDTH = $clog2(H_TOTAL);
    localparam int V_CNT_WIDTH = $clog2(V_TOTAL);

    logic [H_CNT_WIDTH-1:0] h_cnt_q;
    logic [V_CNT_WIDTH-1:0] v_cnt_q;

    logic active_video;
    logic hsync;
    logic vsync;

    logic first_active_pixel;
    logic last_active_x;
    logic last_active_y;
    logic last_active_pixel;

    rgb565_t selected_pixel;

    assign active_video = (h_cnt_q < H_ACTIVE) && (v_cnt_q < V_ACTIVE);

    assign first_active_pixel = active_video && (h_cnt_q == 0) && (v_cnt_q == 0);
    assign last_active_x      = active_video && (h_cnt_q == H_ACTIVE - 1);
    assign last_active_y      = active_video && (v_cnt_q == V_ACTIVE - 1);
    assign last_active_pixel  = last_active_x && last_active_y;

    assign hsync =
        ((h_cnt_q >= H_ACTIVE + H_FP) &&
         (h_cnt_q <  H_ACTIVE + H_FP + H_SYNC)) ? HSYNC_POL : ~HSYNC_POL;

    assign vsync =
        ((v_cnt_q >= V_ACTIVE + V_FP) &&
         (v_cnt_q <  V_ACTIVE + V_FP + V_SYNC)) ? VSYNC_POL : ~VSYNC_POL;

    assign s_axis_ready_o = active_video;

    assign selected_pixel =
        (active_video && s_axis_valid_i) ? s_axis_data_i : DEFAULT_COLOR;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            h_cnt_q <= '0;
            v_cnt_q <= '0;
        end else begin
            if (h_cnt_q == H_TOTAL - 1) begin
                h_cnt_q <= '0;

                if (v_cnt_q == V_TOTAL - 1)
                    v_cnt_q <= '0;
                else
                    v_cnt_q <= v_cnt_q + 1'b1;
            end else begin
                h_cnt_q <= h_cnt_q + 1'b1;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            vga_r_o        <= '0;
            vga_g_o        <= '0;
            vga_b_o        <= '0;
            vga_hs_o       <= ~HSYNC_POL;
            vga_vs_o       <= ~VSYNC_POL;

            active_video_o <= 1'b0;
            frame_start_o  <= 1'b0;
            line_start_o   <= 1'b0;

            pixel_x_o      <= '0;
            pixel_y_o      <= '0;

            underflow_o    <= 1'b0;
            sync_error_o   <= 1'b0;
        end else begin
            vga_r_o <= selected_pixel.red;
            vga_g_o <= selected_pixel.grn;
            vga_b_o <= selected_pixel.blu;

            vga_hs_o <= hsync;
            vga_vs_o <= vsync;

            active_video_o <= active_video;
            frame_start_o  <= first_active_pixel;
            line_start_o   <= active_video && (h_cnt_q == 0);

            if (active_video) begin
                pixel_x_o <= h_cnt_q[X_WIDTH-1:0];
                pixel_y_o <= v_cnt_q[Y_WIDTH-1:0];
            end

            underflow_o <= active_video && !s_axis_valid_i;

            sync_error_o <= 1'b0;

            if (active_video && s_axis_valid_i) begin
                if (first_active_pixel && !s_axis_sof_i)
                    sync_error_o <= 1'b1;

                if (!first_active_pixel && s_axis_sof_i)
                    sync_error_o <= 1'b1;

                if (last_active_x != s_axis_eol_i)
                    sync_error_o <= 1'b1;

                if (last_active_pixel != s_axis_eof_i)
                    sync_error_o <= 1'b1;
            end
        end
    end

endmodule

`endif
