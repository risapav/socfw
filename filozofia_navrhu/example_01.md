Nižšie je kompletný refaktor v 4 súboroch:

1. `video_pkg.sv`
2. `picture_gen_stream.sv`
3. `video_stream_fifo.sv`
4. `vga_rgb565_stream.sv`

---

## 1. `video_pkg.sv`

```systemverilog
`ifndef VIDEO_PKG_SV
`define VIDEO_PKG_SV

package video_pkg;

    typedef struct packed {
        logic [4:0] red;
        logic [5:0] grn;
        logic [4:0] blu;
    } rgb565_t;

    localparam rgb565_t BLACK    = '{red:5'h00, grn:6'h00, blu:5'h00};
    localparam rgb565_t WHITE    = '{red:5'h1F, grn:6'h3F, blu:5'h1F};
    localparam rgb565_t RED      = '{red:5'h1F, grn:6'h00, blu:5'h00};
    localparam rgb565_t GREEN    = '{red:5'h00, grn:6'h3F, blu:5'h00};
    localparam rgb565_t BLUE     = '{red:5'h00, grn:6'h00, blu:5'h1F};
    localparam rgb565_t YELLOW   = '{red:5'h1F, grn:6'h3F, blu:5'h00};
    localparam rgb565_t CYAN     = '{red:5'h00, grn:6'h3F, blu:5'h1F};
    localparam rgb565_t PURPLE   = '{red:5'h1F, grn:6'h00, blu:5'h1F};
    localparam rgb565_t ORANGE   = '{red:5'h1F, grn:6'h20, blu:5'h00};
    localparam rgb565_t DARKGRAY = '{red:5'h04, grn:6'h08, blu:5'h04};

endpackage

`endif
```

---

## 2. `picture_gen_stream.sv`

```systemverilog
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

    output logic    m_axis_sof_o,
    output logic    m_axis_eol_o,
    output logic    m_axis_eof_o,

    output logic    busy_o,

    output logic [X_WIDTH-1:0] x_o,
    output logic [Y_WIDTH-1:0] y_o
);

    localparam int CHECKER_SIZE_SMALL = 3;
    localparam int CHECKER_SIZE_LARGE = 5;
    localparam int ANIM_WIDTH         = 8;

    typedef enum logic [MODE_WIDTH-1:0] {
        MODE_CHECKER_SMALL = 3'd0,
        MODE_CHECKER_LARGE = 3'd1,
        MODE_H_GRADIENT    = 3'd2,
        MODE_V_GRADIENT    = 3'd3,
        MODE_COLOR_BARS    = 3'd4,
        MODE_CROSSHAIR     = 3'd5,
        MODE_DIAG_SCROLL   = 3'd6,
        MODE_MOVING_BAR    = 3'd7
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

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            m_axis_data_o <= BLACK;
            m_axis_sof_o  <= 1'b0;
            m_axis_eol_o  <= 1'b0;
            m_axis_eof_o  <= 1'b0;
        end else if (!m_axis_valid_o || m_axis_ready_i) begin
            m_axis_data_o <= data_next;
            m_axis_sof_o  <= m_axis_valid_o && (x_q == '0) && (y_q == '0);
            m_axis_eol_o  <= m_axis_valid_o && last_x;
            m_axis_eof_o  <= m_axis_valid_o && last_pixel;
        end
    end

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
```

---

## 3. `video_stream_fifo.sv`

```systemverilog
`ifndef VIDEO_STREAM_FIFO_SV
`define VIDEO_STREAM_FIFO_SV

`timescale 1ns/1ns
`default_nettype none

import video_pkg::*;

module video_stream_fifo #(
    parameter int DEPTH = 1024,
    parameter int PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int CNT_WIDTH = $clog2(DEPTH + 1)
)(
    input  wire logic clk_i,
    input  wire logic rst_ni,

    input  rgb565_t   s_axis_data_i,
    input  wire logic s_axis_valid_i,
    output logic      s_axis_ready_o,
    input  wire logic s_axis_sof_i,
    input  wire logic s_axis_eol_i,
    input  wire logic s_axis_eof_i,

    output rgb565_t   m_axis_data_o,
    output logic      m_axis_valid_o,
    input  wire logic m_axis_ready_i,
    output logic      m_axis_sof_o,
    output logic      m_axis_eol_o,
    output logic      m_axis_eof_o,

    output logic [CNT_WIDTH-1:0] level_o,
    output logic overflow_o,
    output logic underflow_o
);

    rgb565_t data_mem [DEPTH];
    logic    sof_mem  [DEPTH];
    logic    eol_mem  [DEPTH];
    logic    eof_mem  [DEPTH];

    logic [PTR_WIDTH-1:0] wr_ptr_q;
    logic [PTR_WIDTH-1:0] rd_ptr_q;
    logic [CNT_WIDTH-1:0] count_q;

    logic push;
    logic pop;

    assign s_axis_ready_o = count_q < DEPTH;
    assign m_axis_valid_o = count_q > 0;

    assign push = s_axis_valid_i && s_axis_ready_o;
    assign pop  = m_axis_valid_o && m_axis_ready_i;

    assign m_axis_data_o = data_mem[rd_ptr_q];
    assign m_axis_sof_o  = sof_mem [rd_ptr_q];
    assign m_axis_eol_o  = eol_mem [rd_ptr_q];
    assign m_axis_eof_o  = eof_mem [rd_ptr_q];

    assign level_o = count_q;

    function automatic logic [PTR_WIDTH-1:0] ptr_next(
        input logic [PTR_WIDTH-1:0] ptr
    );
        if (ptr == DEPTH - 1)
            ptr_next = '0;
        else
            ptr_next = ptr + 1'b1;
    endfunction

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            wr_ptr_q    <= '0;
            rd_ptr_q    <= '0;
            count_q     <= '0;
            overflow_o  <= 1'b0;
            underflow_o <= 1'b0;
        end else begin
            overflow_o  <= s_axis_valid_i && !s_axis_ready_o;
            underflow_o <= m_axis_ready_i && !m_axis_valid_o;

            if (push) begin
                data_mem[wr_ptr_q] <= s_axis_data_i;
                sof_mem [wr_ptr_q] <= s_axis_sof_i;
                eol_mem [wr_ptr_q] <= s_axis_eol_i;
                eof_mem [wr_ptr_q] <= s_axis_eof_i;
                wr_ptr_q           <= ptr_next(wr_ptr_q);
            end

            if (pop) begin
                rd_ptr_q <= ptr_next(rd_ptr_q);
            end

            unique case ({push, pop})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

endmodule

`endif
```

---

## 4. `vga_rgb565_stream.sv`

```systemverilog
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
```

---

## Typické zapojenie

```systemverilog
picture_gen_stream #(
    .H_RES(640),
    .V_RES(480)
) u_picture_gen (
    .clk_i(clk),
    .rst_ni(rst_n),

    .enable_i(1'b1),
    .start_i(start),
    .stop_i(1'b0),
    .continuous_i(1'b1),

    .mode_i(mode),

    .m_axis_data_o(gen_data),
    .m_axis_valid_o(gen_valid),
    .m_axis_ready_i(gen_ready),
    .m_axis_sof_o(gen_sof),
    .m_axis_eol_o(gen_eol),
    .m_axis_eof_o(gen_eof),

    .busy_o(),
    .x_o(),
    .y_o()
);

video_stream_fifo #(
    .DEPTH(2048)
) u_fifo (
    .clk_i(clk),
    .rst_ni(rst_n),

    .s_axis_data_i(gen_data),
    .s_axis_valid_i(gen_valid),
    .s_axis_ready_o(gen_ready),
    .s_axis_sof_i(gen_sof),
    .s_axis_eol_i(gen_eol),
    .s_axis_eof_i(gen_eof),

    .m_axis_data_o(vga_data),
    .m_axis_valid_o(vga_valid),
    .m_axis_ready_i(vga_ready),
    .m_axis_sof_o(vga_sof),
    .m_axis_eol_o(vga_eol),
    .m_axis_eof_o(vga_eof),

    .level_o(),
    .overflow_o(),
    .underflow_o()
);

vga_rgb565_stream #(
    .H_ACTIVE(640),
    .H_FP(16),
    .H_SYNC(96),
    .H_BP(48),

    .V_ACTIVE(480),
    .V_FP(10),
    .V_SYNC(2),
    .V_BP(33)
) u_vga (
    .clk_i(clk),
    .rst_ni(rst_n),

    .s_axis_data_i(vga_data),
    .s_axis_valid_i(vga_valid),
    .s_axis_ready_o(vga_ready),
    .s_axis_sof_i(vga_sof),
    .s_axis_eol_i(vga_eol),
    .s_axis_eof_i(vga_eof),

    .vga_r_o(vga_r),
    .vga_g_o(vga_g),
    .vga_b_o(vga_b),
    .vga_hs_o(vga_hs),
    .vga_vs_o(vga_vs),

    .active_video_o(),
    .frame_start_o(),
    .line_start_o(),

    .pixel_x_o(),
    .pixel_y_o(),

    .underflow_o(),
    .sync_error_o()
);
```

Kompiluj v poradí:

```text
video_pkg.sv
picture_gen_stream.sv
video_stream_fifo.sv
vga_rgb565_stream.sv
```

Toto je už dobrý základ pre neskoršie mapovanie na AXI-Stream Video:

```systemverilog
tdata  = data
tvalid = valid
tready = ready
tuser  = sof
tlast  = eol
```
