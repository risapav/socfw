/**
 * @file video_stream_fifo.sv
 * @brief Synchrónny FIFO buffer pre video dáta s metadátami.
 * @param DEPTH Hĺbka FIFO pamäte v počte pixelov.
 * @details Ukladá RGB565 dáta spolu so signálmi SOF, EOL a EOF.
 */

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

  // Slave rozhranie (Vstup zo zdroja)
  input  rgb565_t   s_axis_data_i,
  input  wire logic s_axis_valid_i,
  output logic      s_axis_ready_o,
  input  wire logic s_axis_sof_i,
  input  wire logic s_axis_eol_i,
  input  wire logic s_axis_eof_i,

  // Master rozhranie (Výstup do synchronizátora)
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

  // Pamäťové polia pre dáta a metadáta[cite: 2]
  rgb565_t data_mem [DEPTH];
  logic    sof_mem  [DEPTH];
  logic    eol_mem  [DEPTH];
  logic    eof_mem  [DEPTH];

  logic [PTR_WIDTH-1:0] wr_ptr_q, rd_ptr_q;
  logic [CNT_WIDTH-1:0] count_q;

  logic push, pop;

  // Riadenie toku: READY ak nie je plno, VALID ak nie je prázdno[cite: 2]
  assign s_axis_ready_o = count_q < DEPTH;
  assign m_axis_valid_o = count_q > 0;

  assign push = s_axis_valid_i && s_axis_ready_o;
  assign pop  = m_axis_valid_o && m_axis_ready_i;

  assign m_axis_data_o = data_mem[rd_ptr_q];
  assign m_axis_sof_o  = sof_mem [rd_ptr_q];
  assign m_axis_eol_o  = eol_mem [rd_ptr_q];
  assign m_axis_eof_o  = eof_mem [rd_ptr_q];

  assign level_o = count_q;

  // Pomocná funkcia pre inkrementáciu pointerov s wrap-around[cite: 2]
  function automatic logic [PTR_WIDTH-1:0] ptr_next(
    input logic [PTR_WIDTH-1:0] ptr
  );
    return (ptr == DEPTH - 1) ? '0 : ptr + 1'b1;
  endfunction

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      wr_ptr_q    <= '0;
      rd_ptr_q    <= '0;
      count_q     <= '0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
    end else begin
      // Detekcia chýb v reálnom čase[cite: 2]
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

      // Update počítadla zaplnenia[cite: 2]
      unique case ({push, pop})
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end

endmodule

`endif
