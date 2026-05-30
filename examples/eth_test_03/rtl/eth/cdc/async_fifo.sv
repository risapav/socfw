/**
 * @file async_fifo.sv
 * @brief Dual-clock asynchronous FIFO using gray-code pointer synchronization.
 * @details Standard gray-code FIFO design (Cummings 2002).
 *   Write and read interfaces use valid/ready handshake.
 *   DEPTH must be a power of 2, minimum 4.
 *   Storage uses synchronous write + registered FWFT output (M10K-compatible).
 *   (* ramstyle = "no_rw_check" *) allows Quartus to infer block RAM.
 *
 * @param DATA_WIDTH  Width of each FIFO entry in bits.
 * @param DEPTH       Entry count; must be a power of 2 >= 4.
 */

`ifndef ASYNC_FIFO_SV
`define ASYNC_FIFO_SV

`default_nettype none

module async_fifo #(
  parameter int DATA_WIDTH = 8,
  parameter int DEPTH      = 16
)(
  // Write side (wr_clk domain)
  input  wire logic                  wr_clk_i,
  input  wire logic                  wr_rst_ni,
  input  wire logic [DATA_WIDTH-1:0] wr_data_i,
  input  wire logic                  wr_valid_i,
  output      logic                  wr_ready_o,

  // Read side (rd_clk domain)
  input  wire logic                  rd_clk_i,
  input  wire logic                  rd_rst_ni,
  output      logic [DATA_WIDTH-1:0] rd_data_o,
  output      logic                  rd_valid_o,
  input  wire logic                  rd_ready_i
);
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int PTR_W  = ADDR_W + 1;

  (* ramstyle = "no_rw_check" *)
  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  // Write-domain binary pointer + gray-coded version.
  logic [PTR_W-1:0] wptr_bin_q, wptr_gray_q;
  // Write-domain synced gray read pointer (2-FF synchronizer from rd domain).
  logic [PTR_W-1:0] rptr_gray_s1_q, rptr_gray_s2_q;

  // Read-domain binary pointer + gray-coded version.
  logic [PTR_W-1:0] rptr_bin_q, rptr_gray_q;
  // Read-domain synced gray write pointer (2-FF synchronizer from wr domain).
  logic [PTR_W-1:0] wptr_gray_s1_q, wptr_gray_s2_q;

  // FWFT output register: pre-fetched data from RAM.
  logic [DATA_WIDTH-1:0] rd_data_q;
  logic                  oq_valid_q;

  // Full (write domain): Cummings 2002 gray-code full condition.
  logic full_w;
  assign full_w = (wptr_gray_q == {~rptr_gray_s2_q[PTR_W-1],
                                   ~rptr_gray_s2_q[PTR_W-2],
                                    rptr_gray_s2_q[PTR_W-3:0]});

  // Empty (read domain): read pointer gray equals synced write pointer gray.
  logic empty_w;
  assign empty_w = (rptr_gray_q == wptr_gray_s2_q);

  assign wr_ready_o = !full_w;
  assign rd_data_o  = rd_data_q;
  assign rd_valid_o = oq_valid_q;

  // ----- Write logic (wr_clk domain) -----
  always_ff @(posedge wr_clk_i or negedge wr_rst_ni) begin
    if (!wr_rst_ni) begin
      wptr_bin_q  <= '0;
      wptr_gray_q <= '0;
    end else if (wr_valid_i && !full_w) begin
      mem[wptr_bin_q[ADDR_W-1:0]] <= wr_data_i;
      wptr_bin_q  <= wptr_bin_q + PTR_W'(1);
      wptr_gray_q <= (wptr_bin_q + PTR_W'(1)) ^ ((wptr_bin_q + PTR_W'(1)) >> 1);
    end
  end

  // 2-FF sync: rd gray pointer -> wr domain
  always_ff @(posedge wr_clk_i or negedge wr_rst_ni) begin
    if (!wr_rst_ni) begin
      rptr_gray_s1_q <= '0;
      rptr_gray_s2_q <= '0;
    end else begin
      rptr_gray_s1_q <= rptr_gray_q;
      rptr_gray_s2_q <= rptr_gray_s1_q;
    end
  end

  // ----- Read logic (rd_clk domain) — FWFT with registered output -----
  // Fetch from RAM when output register is empty or consumer is taking data.
  logic do_rd_w;
  assign do_rd_w = !empty_w && (!oq_valid_q || rd_ready_i);

  always_ff @(posedge rd_clk_i or negedge rd_rst_ni) begin
    if (!rd_rst_ni) begin
      rptr_bin_q  <= '0;
      rptr_gray_q <= '0;
      rd_data_q   <= '0;
      oq_valid_q  <= 1'b0;
    end else begin
      if (do_rd_w) begin
        rd_data_q   <= mem[rptr_bin_q[ADDR_W-1:0]];
        rptr_bin_q  <= rptr_bin_q + PTR_W'(1);
        rptr_gray_q <= (rptr_bin_q + PTR_W'(1)) ^ ((rptr_bin_q + PTR_W'(1)) >> 1);
        oq_valid_q  <= 1'b1;
      end else if (rd_ready_i) begin
        oq_valid_q  <= 1'b0;
      end
    end
  end

  // 2-FF sync: wr gray pointer -> rd domain
  always_ff @(posedge rd_clk_i or negedge rd_rst_ni) begin
    if (!rd_rst_ni) begin
      wptr_gray_s1_q <= '0;
      wptr_gray_s2_q <= '0;
    end else begin
      wptr_gray_s1_q <= wptr_gray_q;
      wptr_gray_s2_q <= wptr_gray_s1_q;
    end
  end

endmodule

`endif // ASYNC_FIFO_SV
