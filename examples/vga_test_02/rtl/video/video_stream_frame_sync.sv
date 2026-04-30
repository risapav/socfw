/**
 * @file video_stream_frame_sync.sv
 * @brief Synchronizátor video streamu s VGA časovaním.
 * @details Zabezpečuje, že stream z FIFO začne presne na súradniciach (0,0) VGA rámca.
 */

`ifndef VIDEO_STREAM_FRAME_SYNC_SV
`define VIDEO_STREAM_FRAME_SYNC_SV

`timescale 1ns/1ns

`default_nettype none

import video_pkg::*;

module video_stream_frame_sync (
    input  wire logic clk_i,
    input  wire logic rst_ni,

    // Status signály z VGA kontroléra
    input  wire logic video_active_i,
    input  wire logic video_frame_start_i,

    // Stream vstup
    input  rgb565_t   s_axis_data_i,
    input  wire logic s_axis_valid_i,
    output logic      s_axis_ready_o,
    input  wire logic s_axis_sof_i,
    input  wire logic s_axis_eol_i,
    input  wire logic s_axis_eof_i,

    // Stream výstup
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

    logic output_handshake;

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

            // Zahadzuj všetko až po najbližší SOF.
            ST_SEARCH_SOF: begin
                if (s_axis_valid_i) begin
                    if (s_axis_sof_i) begin
                        // SOF necháme stáť na čele FIFO.
                        // Nesmie sa skonzumovať mimo začiatku VGA frame.
                        s_axis_ready_o = 1'b0;
                        state_d        = ST_WAIT_FRAME;
                    end else begin
                        // Staré alebo posunuté pixely zahodíme.
                        s_axis_ready_o = 1'b1;
                        dropping_o     = 1'b1;
                    end
                end
            end

            // SOF je pripravený na vstupe, čakáme na VGA pixel (0,0).
            ST_WAIT_FRAME: begin
                if (s_axis_valid_i && !s_axis_sof_i) begin
                    // Toto by pri korektnom FIFO nemalo nastať,
                    // ale je to recovery cesta.
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

            // Normálne streamovanie pixelov počas aktívnej oblasti.
            ST_STREAM: begin
                synced_o = 1'b1;

                if (video_active_i) begin
                    if (s_axis_valid_i) begin
                        m_axis_valid_o = 1'b1;
                        s_axis_ready_o = m_axis_ready_i;

                        if (output_handshake && s_axis_eof_i)
                            state_d = ST_SEARCH_SOF;
                    end else begin
                        // Kritické: chýba pixel počas active video.
                        // Ďalší pixel by už bol posunutý, preto stratíme sync.
                        underflow_o = 1'b1;
                        state_d     = ST_SEARCH_SOF;
                    end
                end

                // Bezpečnostná poistka:
                // ak príde nový VGA frame a ešte sme nevideli EOF,
                // stream je pravdepodobne rozbitý.
                if (video_frame_start_i && !s_axis_sof_i)
                    state_d = ST_SEARCH_SOF;
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
