// tb_read_32bit_word_timing.sv -- PHY + read_word_assembler. Full 32-bit word.
// Write col0=16'hA5C3, col1=16'h1234. Read back as 32-bit word.
// Expected: word_data=32'h1234_A5C3
`timescale 1ns/1ps

import sdram_pkg::*;

module tb_read_32bit_word_timing;

  localparam integer CLK_HALF = 4;

  logic clk   = 0;
  logic clk_sh;
  logic rstn  = 0;

  always #CLK_HALF clk = ~clk;

  initial begin
    clk_sh = 0;
    #2;
    forever #CLK_HALF clk_sh = ~clk_sh;
  end

  // -----------------------------------------------------------------------
  // PHY
  // -----------------------------------------------------------------------
  logic [3:0]  phy_cmd    = 4'b0111;
  logic [12:0] addr_in    = '0;
  logic [1:0]  ba_in      = '0;
  logic        read_en_in = 0;
  logic [15:0] dq_o       = '0;
  logic        dq_oe      = 0;

  logic [15:0] dq_i;
  logic        dq_i_valid;
  logic        phy_wready;

  logic [12:0] sdram_addr;
  logic [1:0]  sdram_ba;
  logic        sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cs_n, sdram_cke;
  wire  [15:0] sdram_dq;
  wire         sdram_clk;

  sdram_phy #(
    .DATA_WIDTH     (16),
    .ROW_ADDR_WIDTH (13),
    .BANK_ADDR_WIDTH(2),
    .CAS_LATENCY    (3),
    .USE_ALTIOBUF   (0)
  ) u_phy (
    .clk        (clk),      .clk_sh     (clk_sh),   .rstn       (rstn),
    .phy_cmd    (phy_cmd),  .addr_in    (addr_in),   .ba_in      (ba_in),
    .read_en_in (read_en_in),
    .dq_o       (dq_o),     .dq_oe      (dq_oe),
    .dq_i       (dq_i),     .dq_i_valid (dq_i_valid), .phy_wready(phy_wready),
    .sdram_addr (sdram_addr), .sdram_ba   (sdram_ba),
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
    .sdram_we_n (sdram_we_n),  .sdram_cs_n (sdram_cs_n),
    .sdram_dq   (sdram_dq),    .sdram_clk  (sdram_clk),  .sdram_cke(sdram_cke)
  );

  sdram_model_pro #(
    .DATA_WIDTH(16), .ROW_WIDTH(13), .COL_WIDTH(9), .BANKS(4),
    .tRCD(2), .tRP(2), .tRAS(6), .tWR(2), .tRFC(8), .CL(3)
  ) u_sdram (
    .clk  (sdram_clk), .rst  (~rstn),
    .addr (sdram_addr), .ba   (sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),  .cs_n (sdram_cs_n), .dq(sdram_dq)
  );

  // -----------------------------------------------------------------------
  // Phase tracking: alternate hw_first for assembler
  // -----------------------------------------------------------------------
  logic hw_first_r = 1;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) hw_first_r <= 1'b1;
    else if (dq_i_valid) hw_first_r <= ~hw_first_r;
  end

  // -----------------------------------------------------------------------
  // Word assembler
  // -----------------------------------------------------------------------
  logic        word_valid;
  logic [31:0] word_data;

  read_word_assembler #(
    .SDRAM_DATA_WIDTH(16),
    .WORD_DATA_WIDTH (32)
  ) u_asm (
    .clk       (clk),
    .rstn      (rstn),
    .hw_valid  (dq_i_valid),
    .hw_data   (dq_i),
    .hw_first  (hw_first_r),
    .word_valid(word_valid),
    .word_data (word_data)
  );

  // -----------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) cyc++;

  integer sh_cyc = 0;
  always @(posedge clk_sh) sh_cyc++;

  // -----------------------------------------------------------------------
  localparam logic [15:0] DATA_COL0  = 16'hA5C3;
  localparam logic [15:0] DATA_COL1  = 16'h1234;
  localparam logic [31:0] WORD_EXPECTED = 32'h1234_A5C3;
  localparam logic [8:0]  COL0       = 9'd0;
  localparam logic [8:0]  COL1       = 9'd1;
  localparam logic [12:0] ROW0       = 13'd0;
  localparam logic [1:0]  BANK0      = 2'd0;
  localparam integer      TIMEOUT    = 60;

  integer errors    = 0;
  integer got_word  = 0;

  task drive_nop;
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0; dq_oe = 0; dq_o = '0;
  endtask

  initial begin
    $display("=== tb_read_32bit_word_timing ===");
    $display("=== RSHIFT=%0d CL=3 expected=0x%08h ===",
             u_phy.READ_CAPTURE_SHIFT, WORD_EXPECTED);

    drive_nop(); rstn = 0;
    repeat(6) @(posedge clk); #1; rstn = 1;
    @(posedge clk); #1;

    // ACTIVE
    phy_cmd = CMD_ACT; addr_in = ROW0; ba_in = BANK0;
    @(posedge clk); #1;
    drive_nop();
    repeat(3) @(posedge clk); #1;

    // WRITE col=0
    phy_cmd = CMD_WR; addr_in = {4'b0, COL0}; ba_in = BANK0;
    dq_o = DATA_COL0; dq_oe = 1;
    $display("[cyc=%0d] WRITE C0=0x%04h", cyc, DATA_COL0);
    @(posedge clk); #1;

    // Hold dq_oe=1: model processes col0 WRITE at sh=M+1, must see DATA_COL0 on DQ.
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0;
    @(posedge clk); #1;

    // WRITE col=1
    phy_cmd = CMD_WR; addr_in = {4'b0, COL1}; ba_in = BANK0;
    dq_o = DATA_COL1; dq_oe = 1;
    $display("[cyc=%0d] WRITE C1=0x%04h", cyc, DATA_COL1);
    @(posedge clk); #1;

    // Hold dq_oe=1: model processes col1 WRITE at sh=M+1, must see DATA_COL1 on DQ.
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0;
    @(posedge clk); #1;

    drive_nop();
    repeat(2) @(posedge clk); #1;

    // READ col=0
    phy_cmd = CMD_RD; addr_in = {4'b0, COL0}; ba_in = BANK0;
    $display("[cyc=%0d] READ C0", cyc);
    @(posedge clk); #1;

    // READ col=1
    phy_cmd = CMD_RD; addr_in = {4'b0, COL1}; ba_in = BANK0;
    $display("[cyc=%0d] READ C1", cyc);
    @(posedge clk); #1;

    drive_nop();

    // Wait for word_valid
    begin : wait_word
      integer i;
      for (i = 0; i < TIMEOUT; i++) begin
        @(posedge clk); #1;
        if (dq_i_valid)
          $display("[cyc=%0d] dq_i_valid=1 dq_i=0x%04h hw_first=%b",
                   cyc, dq_i, hw_first_r);
        if (word_valid) begin
          got_word = 1;
          $display("[cyc=%0d] word_valid=1 word_data=0x%08h expected=0x%08h %s",
                   cyc, word_data, WORD_EXPECTED,
                   (word_data === WORD_EXPECTED) ? "MATCH" : "MISMATCH");
          if (word_data !== WORD_EXPECTED) begin
            $display("[FAIL] word mismatch: expected=0x%08h got=0x%08h",
                     WORD_EXPECTED, word_data);
            errors++;
          end
          disable wait_word;
        end
      end
    end

    if (!got_word) begin
      $display("[FAIL] Timeout: word_valid never went high in %0d cycles", TIMEOUT);
      errors++;
    end

    repeat(4) @(posedge clk);

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
