`timescale 1ns/1ps
/**
 * @file tb_crc32_eth.sv
 * @brief Unit test for crc32_eth module.
 * @details Tests:
 *   T1: "123456789" -> fcs_o == 32'hCBF43926 (ANSI CRC32 standard vector)
 *   T2: clear_i resets CRC mid-sequence
 *   T3: crc_next_o combinatorial preview equals next cycle crc_state_o
 */

module tb_crc32_eth;
  import tb_eth_pkg::*;

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;
  logic        clear;
  logic        en;
  logic [7:0]  data;
  logic [31:0] crc_state;
  logic [31:0] crc_next;
  logic [31:0] fcs;

  always #4 clk = ~clk; // 125 MHz

  crc32_eth dut (
    .clk_i(clk), .rst_ni(rst_n),
    .clear_i(clear), .en_i(en),
    .data_i(data),
    .crc_state_o(crc_state), .crc_next_o(crc_next), .fcs_o(fcs)
  );

  int fails = 0;

  localparam logic [7:0] MSG[9] =
    '{8'h31,8'h32,8'h33,8'h34,8'h35,8'h36,8'h37,8'h38,8'h39};
  localparam logic [31:0] GOLDEN = 32'hCBF4_3926;

  task automatic clk_cyc(int n = 1);
    repeat (n) @(posedge clk);
  endtask

  initial begin
    clear = 1'b0; en = 1'b0; data = 8'h00;
    @(negedge clk); rst_n = 1'b0;
    clk_cyc(3);
    @(negedge clk); rst_n = 1'b1;
    clk_cyc(2);

    // --- T1: standard vector "123456789" ---
    @(negedge clk); clear = 1'b1;
    clk_cyc(1);
    @(negedge clk); clear = 1'b0;
    for (int i = 0; i < 9; i++) begin
      @(negedge clk);
      data = MSG[i];
      en   = 1'b1;
      clk_cyc(1);
    end
    @(negedge clk); en = 1'b0;
    clk_cyc(1);
    if (fcs !== GOLDEN) begin
      $error("T1 FAIL: CRC32('123456789') = 0x%08X, expected 0x%08X", fcs, GOLDEN);
      fails++;
    end else begin
      $display("T1 PASS: CRC32('123456789') = 0x%08X", fcs);
    end

    // --- T2: clear_i mid-sequence ---
    @(negedge clk); en = 1'b1; data = 8'hAA;
    clk_cyc(3);
    @(negedge clk); clear = 1'b1; en = 1'b0;
    clk_cyc(1);
    @(negedge clk); clear = 1'b0;
    clk_cyc(1);
    if (crc_state !== 32'hFFFF_FFFF) begin
      $error("T2 FAIL: after clear crc_state = 0x%08X, expected 0xFFFFFFFF", crc_state);
      fails++;
    end else begin
      $display("T2 PASS: crc_state after clear = 0xFFFFFFFF");
    end

    // --- T3: crc_next_o preview ---
    // crc_next_o is combinatorial: sample it at negedge (before posedge update),
    // then verify it matches crc_state on the following posedge.
    @(negedge clk); clear = 1'b1;
    @(posedge clk); #1; // crc_reg = 0xFFFFFFFF
    @(negedge clk); clear = 1'b0; data = MSG[0]; en = 1'b1;
    begin
      logic [31:0] preview;
      #1; // combinatorial settle
      preview = crc_next; // crc_next = next(0xFFFFFFFF, MSG[0])
      @(posedge clk); #1; // crc_reg latches crc_next
      @(negedge clk); en = 1'b0; // deassert before next posedge
      if (crc_state !== preview) begin
        $error("T3 FAIL: crc_state 0x%08X != crc_next preview 0x%08X", crc_state, preview);
        fails++;
      end else begin
        $display("T3 PASS: crc_next preview matches crc_state");
      end
    end

    if (fails == 0) $display("tb_crc32_eth: ALL PASS");
    else            $fatal(1, "tb_crc32_eth: %0d FAILURES", fails);
    $finish;
  end

endmodule
