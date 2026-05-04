/**
 * @file picture_gen_stream.sv
 * @brief Testovací generátor obrazových vzorov.
 * @param H_RES Horizontálne rozlíšenie.
 * @param V_RES Vertikálne rozlíšenie.
 * @details Implementuje rôzne módy (gradienty, pruhy, mriežky) s animáciou.
 */

`ifndef PICTURE_GEN_STREAM_SV
`define PICTURE_GEN_STREAM_SV

`timescale 1ns/1ns

`default_nettype none

import video_pkg::*;

module picture_gen_stream #(
    parameter int H_RES = 640,
    parameter int V_RES = 480,
    parameter int MAX_MODES = 8,

    parameter int MODE_WIDTH = $clog2(MAX_MODES),
    parameter int X_WIDTH    = $clog2(H_RES),
    parameter int Y_WIDTH    = $clog2(V_RES)
)(
    input  wire logic clk_i,
    input  wire logic rst_ni,

    input  wire logic enable_i,
    input  wire logic start_i,
    input  wire logic stop_i,
    input  wire logic continuous_i,

    input  wire logic [MODE_WIDTH-1:0] mode_i,

    output rgb565_t m_axis_data_o,
    output logic    m_axis_valid_o,
    input  wire logic m_axis_ready_i,

    output logic m_axis_sof_o,
    output logic m_axis_eol_o,
    output logic m_axis_eof_o,

    output logic    busy_o,

    output logic [X_WIDTH-1:0] x_o,
    output logic [Y_WIDTH-1:0] y_o
);

    localparam int CHECKER_SIZE_SMALL = 3;
    localparam int CHECKER_SIZE_LARGE = 5;
    localparam int ANIM_WIDTH         = 8;

    typedef enum logic [MODE_WIDTH-1:0] {
        MODE_CHECKER_SMALL,
        MODE_CHECKER_LARGE,
        MODE_H_GRADIENT,
        MODE_V_GRADIENT,
        MODE_COLOR_BARS,
        MODE_CROSSHAIR,
        MODE_DIAG_SCROLL,
        MODE_MOVING_BAR
    } mode_e;

    logic [X_WIDTH-1:0] x_q;
    logic [Y_WIDTH-1:0] y_q;

    logic [ANIM_WIDTH-1:0] scroll_offset_q;
    logic [MODE_WIDTH-1:0] mode_q;

    rgb565_t data_next;

    logic handshake;
    logic last_x;
    logic last_y;
    logic last_pixel;

    assign handshake  = m_axis_valid_o && m_axis_ready_i;
    assign last_x     = x_q == H_RES - 1;
    assign last_y     = y_q == V_RES - 1;
    assign last_pixel = last_x && last_y;

    assign x_o = x_q;
    assign y_o = y_q;

    // Sequential logic for coordinate generation and animation
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            x_q             <= '0;
            y_q             <= '0;
            m_axis_valid_o  <= 1'b0;
            busy_o          <= 1'b0;
            mode_q          <= '0;
            scroll_offset_q <= '0;
        end else begin
            if (stop_i) begin
                x_q            <= '0;
                y_q            <= '0;
                m_axis_valid_o <= 1'b0;
                busy_o         <= 1'b0;
            end else if (enable_i) begin
                if (start_i && !busy_o) begin
                    x_q            <= '0;
                    y_q            <= '0;
                    m_axis_valid_o <= 1'b1;
                    busy_o         <= 1'b1;
                    mode_q         <= mode_i;
                end else if (handshake) begin
                    if (last_pixel) begin
                        scroll_offset_q <= scroll_offset_q + ANIM_WIDTH'(1);

                        if (continuous_i) begin
                            x_q            <= '0;
                            y_q            <= '0;
                            m_axis_valid_o <= 1'b1;
                            busy_o         <= 1'b1;
                            mode_q         <= mode_i;
                        end else begin
                            x_q            <= '0;
                            y_q            <= '0;
                            m_axis_valid_o <= 1'b0;
                            busy_o         <= 1'b0;
                        end
                    end else if (last_x) begin
                        x_q <= '0;
                        y_q <= y_q + 1'b1;
                    end else begin
                        x_q <= x_q + 1'b1;
                    end
                end
            end
        end
    end

    // Frame metadata
    assign m_axis_data_o = data_next;
    assign m_axis_sof_o  = m_axis_valid_o && (x_q == '0) && (y_q == '0);
    assign m_axis_eol_o  = m_axis_valid_o && last_x;
    assign m_axis_eof_o  = m_axis_valid_o && last_pixel;

    // Combinational pattern selection
    always_comb begin
        data_next = BLACK;

        case (mode_e'(mode_q))

            MODE_CHECKER_SMALL: begin
                data_next = (x_q[CHECKER_SIZE_SMALL] ^ y_q[CHECKER_SIZE_SMALL])
                            ? WHITE : BLACK;
            end

            MODE_CHECKER_LARGE: begin
                data_next = (x_q[CHECKER_SIZE_LARGE] ^ y_q[CHECKER_SIZE_LARGE])
                            ? BLUE : YELLOW;
            end

            MODE_H_GRADIENT: begin
                logic [15:0] x_extended;
                x_extended = 16'(x_q);

                data_next.red = x_extended[10:6];
                data_next.grn = x_extended[9:4];
                data_next.blu = x_extended[7:3];
            end

            MODE_V_GRADIENT: begin
                logic [15:0] y_extended;
                y_extended = 16'(y_q);

                data_next.red = y_extended[10:6];
                data_next.grn = y_extended[9:4];
                data_next.blu = y_extended[7:3];
            end

            MODE_DIAG_SCROLL: begin
                logic [15:0] sum_extended;
                sum_extended = 16'(x_q) + 16'(y_q) + 16'(scroll_offset_q);

                data_next.red = sum_extended[10:6];
                data_next.grn = sum_extended[9:4];
                data_next.blu = sum_extended[7:3];
            end

            MODE_MOVING_BAR: begin
                if (((x_q + X_WIDTH'(scroll_offset_q)) & 8'h3F) < 16)
                    data_next = RED;
                else
                    data_next = BLACK;
            end

            MODE_COLOR_BARS: begin
                logic [X_WIDTH+2:0] x_times_8;
                x_times_8 = x_q << 3;

                //
                if      (x_times_8 < H_RES * 1) data_next = WHITE;
                else if (x_times_8 < H_RES * 2) data_next = YELLOW;
                else if (x_times_8 < H_RES * 3) data_next = CYAN;
                else if (x_times_8 < H_RES * 4) data_next = GREEN;
                else if (x_times_8 < H_RES * 5) data_next = PURPLE;
                else if (x_times_8 < H_RES * 6) data_next = RED;
                else if (x_times_8 < H_RES * 7) data_next = BLUE;
                else                            data_next = BLACK;
            end

            MODE_CROSSHAIR: begin
                logic [X_WIDTH-1:0] center_x;
                logic [Y_WIDTH-1:0] center_y;
                logic is_on_x_line;
                logic is_on_y_line;

                center_x = H_RES >> 1;
                center_y = V_RES >> 1;

                is_on_y_line = (y_q > center_y - 2) && (y_q < center_y + 2);
                is_on_x_line = (x_q > center_x - 2) && (x_q < center_x + 2);

                data_next = (is_on_x_line || is_on_y_line) ? WHITE : DARKGRAY;
            end

            default: begin
                data_next = ORANGE;
            end

        endcase
    end

endmodule

`endif
