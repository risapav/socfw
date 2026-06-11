/**
 * @file    sync_fifo.sv
 * @brief   Generic synchronous FIFO with AXI-Stream-compatible ports.
 * @param   DATA_WIDTH  Width of each entry in bits (default 8).
 * @param   DEPTH       FIFO capacity in entries; must be a power of 2.
 * @param   RAM_STYLE   Quartus ramstyle hint: "logic", "M9K", "MLAB", or "AUTO" (default "logic").
 * @details
 *  Write port is an AXI-Stream slave (wr_valid_i / wr_ready_o).
 *  Read port is an AXI-Stream master with held-valid semantics:
 *    rd_valid_o stays high while data is available.
 *    rd_data_o is stable while rd_valid_o is high.
 *
 *  Simultaneous read+write in the same clock is fully supported;
 *  level_o stays unchanged in that case.
 *
 *  Overflow guard: wr_ready_o is deasserted when full; writes are ignored
 *  while wr_ready_o is low.  Underflow guard: rd_valid_o is deasserted when
 *  empty; rd_ready_i has no effect when rd_valid_o is low.
 *
 *  Sticky overflow_o records any attempt to write while full.
 *  underflow_o is always 0: in AXI-Stream a sink may hold ready=1 while
 *  valid=0, which is legal and not an error.  Assert err_clear_i to clear
 *  overflow_o.
 */

`ifndef SYNC_FIFO_SV
`define SYNC_FIFO_SV

`default_nettype none

module sync_fifo #(
  parameter int    DATA_WIDTH = 8,
  parameter int    DEPTH      = 64,
  parameter string RAM_STYLE  = "logic"
)(
  input  wire clk,
  input  wire rstn,

  // Write port (AXI-Stream slave)
  input  wire [DATA_WIDTH-1:0] wr_data_i,
  input  wire                  wr_valid_i,
  output logic                 wr_ready_o,

  // Read port (AXI-Stream master, held-valid)
  output logic [DATA_WIDTH-1:0] rd_data_o,
  output logic                  rd_valid_o,
  input  wire                   rd_ready_i,

  // Control
  input  wire  err_clear_i,

  // Status
  output logic [$clog2(DEPTH):0] level_o,
  output logic                   full_o,
  output logic                   empty_o,
  output logic                   overflow_o,
  output logic                   underflow_o
);

  localparam int PTR_W = $clog2(DEPTH);
  localparam int LVL_W = PTR_W + 1;

  // synthesis translate_off
  initial begin
    assert(DEPTH > 1)         else $fatal(1, "sync_fifo: DEPTH must be > 1");
    assert(2**PTR_W == DEPTH) else $fatal(1, "sync_fifo: DEPTH must be a power of 2");
  end
  // synthesis translate_on

  (* ramstyle = RAM_STYLE *) logic [DATA_WIDTH-1:0] mem_q [DEPTH];
  logic [PTR_W-1:0]      head_q;
  logic [PTR_W-1:0]      tail_q;
  logic [LVL_W-1:0]      level_q;
  logic                  overflow_q;
  logic                  underflow_q;

  wire wr_fire_w    = wr_valid_i && wr_ready_o;
  wire rd_fire_w    = rd_valid_o && rd_ready_i;
  wire wr_drop_w    = wr_valid_i && !wr_ready_o;
  wire rd_drop_w    = 1'b0;  // ready=1 with valid=0 is legal in AXI-Stream

  assign full_o      = (level_q == LVL_W'(DEPTH));
  assign empty_o     = (level_q == '0);
  assign wr_ready_o  = !full_o;
  assign rd_valid_o  = !empty_o;
  assign rd_data_o   = mem_q[tail_q];
  assign level_o     = level_q;
  assign overflow_o  = overflow_q;
  assign underflow_o = underflow_q;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      head_q     <= '0;
      tail_q     <= '0;
      level_q    <= '0;
      overflow_q  <= 1'b0;
      underflow_q <= 1'b0;
    end else begin
      if (wr_fire_w) begin
        mem_q[head_q] <= wr_data_i;
        head_q        <= head_q + PTR_W'(1);
      end
      if (rd_fire_w) begin
        tail_q <= tail_q + PTR_W'(1);
      end
      unique case ({wr_fire_w, rd_fire_w})
        2'b10:   level_q <= level_q + LVL_W'(1);
        2'b01:   level_q <= level_q - LVL_W'(1);
        default: ;
      endcase
      if (err_clear_i) begin
        overflow_q  <= 1'b0;
        underflow_q <= 1'b0;
      end else begin
        if (wr_drop_w) overflow_q  <= 1'b1;
        if (rd_drop_w) underflow_q <= 1'b1;
      end
    end
  end

endmodule

`default_nettype wire

`endif // SYNC_FIFO_SV
