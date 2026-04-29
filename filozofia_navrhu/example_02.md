Áno. Pridaj medzi FIFO a VGA tento modul:

```text
picture_gen_stream
        ↓
video_stream_fifo
        ↓
video_stream_frame_sync
        ↓
vga_rgb565_stream
```

## `video_stream_frame_sync.sv`

```systemverilog
`ifndef VIDEO_STREAM_FRAME_SYNC_SV
`define VIDEO_STREAM_FRAME_SYNC_SV

`timescale 1ns/1ns
`default_nettype none

import video_pkg::*;

module video_stream_frame_sync (
    input  wire logic clk_i,
    input  wire logic rst_ni,

    input  wire logic video_active_i,
    input  wire logic video_frame_start_i,

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

    output logic      synced_o,
    output logic      dropping_o,
    output logic      underflow_o
);

    typedef enum logic [1:0] {
        ST_SEARCH_SOF,
        ST_WAIT_FRAME,
        ST_STREAM
    } state_e;

    state_e state_q, state_d;

    logic input_handshake;
    logic output_handshake;

    assign input_handshake  = s_axis_valid_i && s_axis_ready_o;
    assign output_handshake = m_axis_valid_o && m_axis_ready_i;

    assign m_axis_data_o = s_axis_data_i;
    assign m_axis_sof_o  = s_axis_sof_i;
    assign m_axis_eol_o  = s_axis_eol_i;
    assign m_axis_eof_o  = s_axis_eof_i;

    always_comb begin
        state_d        = state_q;

        s_axis_ready_o = 1'b0;
        m_axis_valid_o = 1'b0;

        synced_o       = 1'b0;
        dropping_o     = 1'b0;
        underflow_o    = 1'b0;

        case (state_q)

            ST_SEARCH_SOF: begin
                synced_o = 1'b0;

                if (s_axis_valid_i) begin
                    if (s_axis_sof_i) begin
                        s_axis_ready_o = 1'b0;
                        state_d        = ST_WAIT_FRAME;
                    end else begin
                        s_axis_ready_o = 1'b1;
                        dropping_o     = 1'b1;
                    end
                end
            end

            ST_WAIT_FRAME: begin
                synced_o = 1'b0;

                if (s_axis_valid_i && !s_axis_sof_i) begin
                    s_axis_ready_o = 1'b1;
                    dropping_o     = 1'b1;
                    state_d        = ST_SEARCH_SOF;
                end else if (s_axis_valid_i && s_axis_sof_i && video_frame_start_i) begin
                    m_axis_valid_o = 1'b1;
                    s_axis_ready_o = m_axis_ready_i;

                    if (output_handshake)
                        state_d = s_axis_eof_i ? ST_SEARCH_SOF : ST_STREAM;
                end
            end

            ST_STREAM: begin
                synced_o = 1'b1;

                if (video_active_i) begin
                    m_axis_valid_o = s_axis_valid_i;
                    s_axis_ready_o = m_axis_ready_i;

                    underflow_o = !s_axis_valid_i;

                    if (output_handshake && s_axis_eof_i)
                        state_d = ST_SEARCH_SOF;
                end
            end

            default: begin
                state_d = ST_SEARCH_SOF;
            end

        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni)
            state_q <= ST_SEARCH_SOF;
        else
            state_q <= state_d;
    end

endmodule

`endif
```

## Zapojenie

Signály medzi FIFO a frame sync:

```systemverilog
rgb565_t fifo_data;
logic    fifo_valid;
logic    fifo_ready;
logic    fifo_sof;
logic    fifo_eol;
logic    fifo_eof;

rgb565_t sync_data;
logic    sync_valid;
logic    sync_ready;
logic    sync_sof;
logic    sync_eol;
logic    sync_eof;
```

FIFO výstup pripoj na `frame_sync`:

```systemverilog
video_stream_frame_sync u_frame_sync (
    .clk_i(clk),
    .rst_ni(rst_n),

    .video_active_i(vga_active),
    .video_frame_start_i(vga_frame_start),

    .s_axis_data_i(fifo_data),
    .s_axis_valid_i(fifo_valid),
    .s_axis_ready_o(fifo_ready),
    .s_axis_sof_i(fifo_sof),
    .s_axis_eol_i(fifo_eol),
    .s_axis_eof_i(fifo_eof),

    .m_axis_data_o(sync_data),
    .m_axis_valid_o(sync_valid),
    .m_axis_ready_i(sync_ready),
    .m_axis_sof_o(sync_sof),
    .m_axis_eol_o(sync_eol),
    .m_axis_eof_o(sync_eof),

    .synced_o(),
    .dropping_o(),
    .underflow_o()
);
```

VGA potom pripájaj už iba na zarovnaný stream:

```systemverilog
vga_rgb565_stream u_vga (
    .clk_i(clk),
    .rst_ni(rst_n),

    .s_axis_data_i(sync_data),
    .s_axis_valid_i(sync_valid),
    .s_axis_ready_o(sync_ready),
    .s_axis_sof_i(sync_sof),
    .s_axis_eol_i(sync_eol),
    .s_axis_eof_i(sync_eof),

    .vga_r_o(vga_r),
    .vga_g_o(vga_g),
    .vga_b_o(vga_b),
    .vga_hs_o(vga_hs),
    .vga_vs_o(vga_vs),

    .active_video_o(vga_active),
    .frame_start_o(vga_frame_start),
    .line_start_o(),

    .pixel_x_o(),
    .pixel_y_o(),

    .underflow_o(),
    .sync_error_o()
);
```

## Dôležitá poznámka

Vo VGA module už potom nerob hľadanie `SOF`. VGA má byť iba jednoduchý sink:

```systemverilog
assign s_axis_ready_o = active_video;
```

Synchronizáciu rieši výhradne:

```systemverilog
video_stream_frame_sync
```

Takto sa pixel `SOF`, teda pixel `(0,0)`, pustí do VGA presne vtedy, keď je VGA tiež na začiatku aktívnej snímky.
