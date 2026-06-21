// tb_read_word_assembler.sv -- Unit test for read_word_assembler.
// No SDRAM model. No PHY. Pure combinational/registered logic test.
// Expected: first=16'hA5C3, second=16'h1234 -> word=32'h1234_A5C3
`timescale 1ns/1ps

module tb_read_word_assembler;

  // -----------------------------------------------------------------------
  // Clock (125 MHz = 8 ns period, but timing irrelevant for this unit test)
  // -----------------------------------------------------------------------
  localparam integer CLK_HALF = 4;

  logic clk  = 0;
  logic rstn = 0;

  always #CLK_HALF clk = ~clk;

  // -----------------------------------------------------------------------
  // DUT ports
  // -----------------------------------------------------------------------
  logic        hw_valid = 0;
  logic [15:0] hw_data  = 0;
  logic        hw_first = 0;

  logic        word_valid;
  logic [31:0] word_data;

  // -----------------------------------------------------------------------
  // DUT
  // -----------------------------------------------------------------------
  read_word_assembler #(
    .SDRAM_DATA_WIDTH(16),
    .WORD_DATA_WIDTH (32)
  ) u_dut (
    .clk       (clk),
    .rstn      (rstn),
    .hw_valid  (hw_valid),
    .hw_data   (hw_data),
    .hw_first  (hw_first),
    .word_valid(word_valid),
    .word_data (word_data)
  );

  // -----------------------------------------------------------------------
  // Cycle counter for display
  // -----------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) cyc++;

  // -----------------------------------------------------------------------
  // Test sequence
  // -----------------------------------------------------------------------
  integer errors = 0;

  initial begin
    $display("=== tb_read_word_assembler ===");

    // Reset
    rstn = 0; hw_valid = 0;
    repeat(4) @(posedge clk);
    #1; rstn = 1;
    @(posedge clk); #1;

    // Cycle 1: first halfword (low word)
    hw_valid = 1; hw_first = 1; hw_data = 16'hA5C3;
    $display("[cyc=%0d] Feed: hw_valid=1 hw_first=1 hw_data=0x%04h", cyc, hw_data);
    @(posedge clk); #1;

    // Cycle 2: second halfword (high word)
    hw_valid = 1; hw_first = 0; hw_data = 16'h1234;
    $display("[cyc=%0d] Feed: hw_valid=1 hw_first=0 hw_data=0x%04h", cyc, hw_data);
    @(posedge clk); #1;

    // Cycle 3: deassert, check outputs
    hw_valid = 0; hw_first = 0; hw_data = 0;
    $display("[cyc=%0d] Check: word_valid=%b word_data=0x%08h",
             cyc, word_valid, word_data);

    if (word_valid !== 1'b1) begin
      $display("[FAIL] word_valid: expected 1, got %b", word_valid);
      errors++;
    end
    if (word_data !== 32'h1234_A5C3) begin
      $display("[FAIL] word_data: expected 0x1234A5C3, got 0x%08h", word_data);
      errors++;
    end

    // word_valid must deassert next cycle (pulse of 1)
    @(posedge clk); #1;
    if (word_valid !== 1'b0) begin
      $display("[FAIL] word_valid should deassert after 1 cycle, still %b", word_valid);
      errors++;
    end

    @(posedge clk); #1;

    // -------------------------------------------------------
    if (errors == 0) begin
      $display("==============================================");
      $display("  *** PASS *** (errors=%0d)", errors);
      $display("==============================================");
    end else begin
      $display("==============================================");
      $display("  *** FAIL *** (errors=%0d)", errors);
      $display("==============================================");
    end
    $finish;
  end

endmodule
