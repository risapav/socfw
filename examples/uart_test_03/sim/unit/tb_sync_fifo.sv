// tb_sync_fifo -- unit tests for sync_fifo
//
// Tests:
//   F01  empty after reset: rd_valid=0, level=0, full=0, empty=1
//   F02  write one byte: rd_valid=1, level=1
//   F03  read one byte back: data correct, level=0, empty=1
//   F04  write until full: level=DEPTH, full=1, wr_ready=0
//   F05  simultaneous write+read does not change level
//   F06  drain full FIFO: empty after drain
//   F07  overflow attempt: overflow_o set, level unchanged, no corruption
//   F08  err_clear clears overflow_o; underflow attempt sets underflow_o
//
// Run: vsim -c -do "run -all; quit" tb_sync_fifo

`timescale 1ns/1ps

module tb_sync_fifo;

  localparam int DATA_WIDTH = 8;
  localparam int DEPTH      = 8;

  logic clk       = 1'b0;
  logic rstn      = 1'b0;
  logic err_clear = 1'b0;

  always #5 clk = ~clk;

  logic [DATA_WIDTH-1:0] wr_data  = '0;
  logic                  wr_valid = 1'b0;
  logic [DATA_WIDTH-1:0] rd_data;
  logic                  rd_ready = 1'b0;
  logic                  wr_ready;
  logic                  rd_valid;
  logic [$clog2(DEPTH):0] level;
  logic                  full;
  logic                  empty;
  logic                  overflow;
  logic                  underflow;

  sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (DEPTH)
  ) dut (
    .clk        (clk),
    .rstn       (rstn),
    .wr_data_i  (wr_data),
    .wr_valid_i (wr_valid),
    .wr_ready_o (wr_ready),
    .rd_data_o  (rd_data),
    .rd_valid_o (rd_valid),
    .rd_ready_i (rd_ready),
    .err_clear_i(err_clear),
    .level_o    (level),
    .full_o     (full),
    .empty_o    (empty),
    .overflow_o (overflow),
    .underflow_o(underflow)
  );

  int fails = 0;

  task automatic chk(input logic cond, input string lbl);
    if (!cond) begin $display("FAIL %s", lbl); fails++; end
    else             $display("PASS %s", lbl);
  endtask

  task automatic fifo_write(input logic [7:0] data);
    wr_data  = data;
    wr_valid = 1'b1;
    @(posedge clk);
    wr_valid = 1'b0;
  endtask

  task automatic fifo_read(output logic [7:0] data_out);
    rd_ready = 1'b1;
    @(posedge clk);
    data_out = rd_data;
    rd_ready = 1'b0;
  endtask

  logic [7:0] got;

  initial begin
    repeat(4) @(posedge clk);
    rstn = 1'b1;
    @(posedge clk);

    // ------------------------------------------------------------------
    // F01: empty after reset
    // ------------------------------------------------------------------
    chk(rd_valid  === 1'b0, "F01 rd_valid=0 after reset");
    chk(level     === '0,   "F01 level=0 after reset");
    chk(full      === 1'b0, "F01 full=0 after reset");
    chk(empty     === 1'b1, "F01 empty=1 after reset");
    chk(wr_ready  === 1'b1, "F01 wr_ready=1 after reset");
    chk(overflow  === 1'b0, "F01 overflow=0 after reset");
    chk(underflow === 1'b0, "F01 underflow=0 after reset");

    // ------------------------------------------------------------------
    // F02: write one byte
    // ------------------------------------------------------------------
    fifo_write(8'hA5);
    @(posedge clk);
    chk(rd_valid === 1'b1,  "F02 rd_valid=1 after write");
    chk(level    === 4'(1), "F02 level=1 after write");
    chk(empty    === 1'b0,  "F02 empty=0 after write");
    chk(full     === 1'b0,  "F02 full=0 after one write");

    // ------------------------------------------------------------------
    // F03: read one byte back
    // ------------------------------------------------------------------
    chk(rd_data === 8'hA5, "F03 data correct before read");
    fifo_read(got);
    @(posedge clk);
    chk(got    === 8'hA5, "F03 read data=0xA5");
    chk(level  === '0,    "F03 level=0 after read");
    chk(empty  === 1'b1,  "F03 empty=1 after drain");

    // ------------------------------------------------------------------
    // F04: write until full
    // ------------------------------------------------------------------
    for (int i = 0; i < DEPTH; i++) begin
      fifo_write(8'(i));
    end
    @(posedge clk);
    chk(full     === 1'b1,                      "F04 full=1 after DEPTH writes");
    chk(level    === ($clog2(DEPTH)+1)'(DEPTH),
        $sformatf("F04 level=%0d after DEPTH writes", DEPTH));
    chk(wr_ready === 1'b0,                      "F04 wr_ready=0 when full");

    // ------------------------------------------------------------------
    // F05: simultaneous write+read does not change level
    //   FIFO full after F04; drain one slot first (wr_ready=1), then fire.
    // ------------------------------------------------------------------
    begin
      rd_ready = 1'b1;
      @(posedge clk);
      rd_ready = 1'b0;
      @(posedge clk);
      begin : blk_f05
        automatic int lvl_before = int'(level);
        wr_data  = 8'hFF;
        wr_valid = 1'b1;
        rd_ready = 1'b1;
        @(posedge clk);
        wr_valid = 1'b0;
        rd_ready = 1'b0;
        @(posedge clk);
        chk(int'(level) == lvl_before,
            $sformatf("F05 level unchanged=%0d during sim rd+wr", lvl_before));
      end
    end

    // ------------------------------------------------------------------
    // F06: drain remaining entries; FIFO empty after drain
    // ------------------------------------------------------------------
    begin : blk_f06
      repeat(DEPTH) begin
        rd_ready = 1'b1;
        @(posedge clk);
        rd_ready = 1'b0;
        @(posedge clk);
      end
      chk(empty === 1'b1, "F06 FIFO empty after full drain");
    end

    // ------------------------------------------------------------------
    // F07: overflow attempt when full -- overflow_o set, level unchanged
    // ------------------------------------------------------------------
    for (int i = 0; i < DEPTH; i++) begin
      fifo_write(8'(i + 8'h10));
    end
    @(posedge clk);
    chk(full === 1'b1, "F07 full before overflow attempt");
    wr_data  = 8'hEE;
    wr_valid = 1'b1;
    @(posedge clk);
    wr_valid = 1'b0;
    @(posedge clk);
    chk(level    === ($clog2(DEPTH)+1)'(DEPTH), "F07 level unchanged");
    chk(full     === 1'b1,                      "F07 still full");
    chk(rd_data  === 8'h10,                     "F07 first byte not corrupted");
    chk(overflow === 1'b1,                      "F07 overflow_o set");

    // ------------------------------------------------------------------
    // F08: err_clear clears overflow_o; underflow attempt sets underflow_o
    // ------------------------------------------------------------------
    // Clear overflow
    err_clear = 1'b1;
    @(posedge clk);
    err_clear = 1'b0;
    @(posedge clk);
    chk(overflow === 1'b0, "F08 overflow cleared by err_clear");
    // Drain FIFO fully then attempt read from empty
    repeat(DEPTH) begin
      rd_ready = 1'b1;
      @(posedge clk);
      rd_ready = 1'b0;
      @(posedge clk);
    end
    chk(empty === 1'b1, "F08 FIFO empty before underflow attempt");
    rd_ready = 1'b1;
    @(posedge clk);
    rd_ready = 1'b0;
    @(posedge clk);
    chk(underflow === 1'b1, "F08 underflow_o set after read from empty");
    // Clear both
    err_clear = 1'b1;
    @(posedge clk);
    err_clear = 1'b0;
    @(posedge clk);
    chk(underflow === 1'b0, "F08 underflow cleared by err_clear");

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    if (fails == 0)
      $display("PASS tb_sync_fifo: all tests passed");
    else
      $display("FAIL tb_sync_fifo: %0d test(s) failed", fails);

    $finish;
  end

  initial begin
    repeat(50_000) @(posedge clk);
    $display("FAIL tb_sync_fifo: TIMEOUT");
    $finish;
  end

endmodule : tb_sync_fifo
