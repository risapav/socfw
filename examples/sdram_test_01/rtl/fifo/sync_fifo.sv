/**
 * @file sync_fifo.sv
 * @brief Generický synchronný FIFO modul.
 *
 * Parametrizovaný FIFO s AXI-S rozhraním (valid/ready handshake).
 * Nahrádza cmd_fifo, data_fifo v write_engine a meta pipeline v read_engine.
 *
 * @param WIDTH  Šírka dátového slova v bitoch
 * @param DEPTH  Počet slov (musí byť mocnina 2)
 */

`ifndef SYNC_FIFO_SV
`define SYNC_FIFO_SV

`default_nettype none

module sync_fifo #(
  parameter int WIDTH               = 8,
  parameter int DEPTH               = 16,
  parameter int ALMOST_FULL_THRESH  = DEPTH - 2,  // almost_full keď cnt >= thresh
  parameter int ALMOST_EMPTY_THRESH = 2            // almost_empty keď cnt <= thresh
)(
  input  wire              clk,
  input  wire              rstn,

  // Vstupná strana (producer)
  input  wire [WIDTH-1:0]  s_data,
  input  wire              s_valid,
  output logic             s_ready,

  // Výstupná strana (consumer)
  output logic [WIDTH-1:0] m_data,
  output logic             m_valid,
  input  wire              m_ready,

  // Stavové výstupy
  output logic [$clog2(DEPTH):0] count,
  output logic                   almost_full,
  output logic                   almost_empty
);

  localparam int PTR_W  = $clog2(DEPTH);
  localparam int CNT_W  = PTR_W + 1;

  logic [WIDTH-1:0]  mem [0:DEPTH-1];
  logic [PTR_W-1:0]  wr_ptr, rd_ptr;
  logic [CNT_W-1:0]  cnt;

  wire push = s_valid && s_ready;
  wire pop  = m_valid && m_ready;

  assign s_ready     = (cnt < CNT_W'(DEPTH));
  assign m_valid     = (cnt > 0);
  assign m_data      = mem[rd_ptr];
  assign count       = cnt;
  assign almost_full  = (cnt >= CNT_W'(ALMOST_FULL_THRESH));
  assign almost_empty = (cnt <= CNT_W'(ALMOST_EMPTY_THRESH));

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      cnt    <= '0;
    end else begin
      if (push) begin
        mem[wr_ptr] <= s_data;
        wr_ptr      <= wr_ptr + 1;
      end
      if (pop)
        rd_ptr <= rd_ptr + 1;
      case ({push, pop})
        2'b10:   cnt <= cnt + 1;
        2'b01:   cnt <= cnt - 1;
        default: cnt <= cnt;
      endcase
    end
  end

  // ==========================================================================
  // Assertions
  // synthesis translate_off
  // --------------------------------------------------------------------------
  // Parametrická validácia — spustí sa raz pri elaborácii
  // --------------------------------------------------------------------------
  initial begin
    // DEPTH musí byť mocnina 2 — pointre používajú mod-2 aritmetiku
    if (DEPTH == 0 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "[SYNC_FIFO] DEPTH=%0d nie je mocnina 2. WIDTH=%0d",
             DEPTH, WIDTH);

    // Thresholdy musia byť v rozsahu
    if (ALMOST_FULL_THRESH < 1 || ALMOST_FULL_THRESH > DEPTH)
      $fatal(1, "[SYNC_FIFO] ALMOST_FULL_THRESH=%0d mimo rozsahu [1,%0d]",
             ALMOST_FULL_THRESH, DEPTH);
    if (ALMOST_EMPTY_THRESH < 0 || ALMOST_EMPTY_THRESH >= DEPTH)
      $fatal(1, "[SYNC_FIFO] ALMOST_EMPTY_THRESH=%0d mimo rozsahu [0,%0d)",
             ALMOST_EMPTY_THRESH, DEPTH);

    // WIDTH musí byť aspoň 1
    if (WIDTH < 1)
      $fatal(1, "[SYNC_FIFO] WIDTH=%0d musí byť >= 1", WIDTH);

    // DEPTH musí byť aspoň 2 (DEPTH=1 nemá zmysel pre pipeline)
    if (DEPTH < 2)
      $fatal(1, "[SYNC_FIFO] DEPTH=%0d musí byť >= 2", DEPTH);
  end

  // --------------------------------------------------------------------------
  // Runtime — overflow / underflow
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rstn) begin
      if (push && cnt == CNT_W'(DEPTH))
        $error("[SYNC_FIFO] Overflow!  WIDTH=%0d DEPTH=%0d cnt=%0d",
               WIDTH, DEPTH, cnt);
      if (pop && cnt == '0)
        $error("[SYNC_FIFO] Underflow! WIDTH=%0d DEPTH=%0d",
               WIDTH, DEPTH);
    end
  end
  // synthesis translate_on

endmodule

`endif
