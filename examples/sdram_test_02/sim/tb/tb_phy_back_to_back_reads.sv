// tb_phy_back_to_back_reads.sv -- PHY + SDRAM model. Two consecutive reads.
// Write col0=16'hA5C3, col1=16'h1234. Read col0 then col1.
// Records exact cycle numbers for each dq_i_valid capture.
`timescale 1ns/1ps

import sdram_pkg::*;

module tb_phy_back_to_back_reads;

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
  // PHY wires
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

  integer cyc = 0;
  always @(posedge clk) cyc++;

  integer sh_cyc = 0;
  always @(posedge clk_sh) begin
    sh_cyc++;
    $display("[sh=%0d cyc=%0d] cs=%b ras=%b cas=%b we=%b | DQ=%04h(Z=%b) dq_i_v=%b dq_i=%04h",
             sh_cyc, cyc,
             sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n,
             sdram_dq, $isunknown(sdram_dq),
             dq_i_valid, dq_i);
  end

  // -----------------------------------------------------------------------
  localparam logic [15:0] DATA_COL0 = 16'hA5C3;
  localparam logic [15:0] DATA_COL1 = 16'h1234;
  localparam logic [8:0]  COL0      = 9'd0;
  localparam logic [8:0]  COL1      = 9'd1;
  localparam logic [12:0] ROW0      = 13'd0;
  localparam logic [1:0]  BANK0     = 2'd0;
  localparam integer      TIMEOUT   = 50;

  integer errors = 0;
  integer cap_cyc[2];
  logic [15:0] cap_data[2];
  integer n_captures = 0;

  task drive_nop;
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0; dq_oe = 0; dq_o = '0;
  endtask

  // -----------------------------------------------------------------------
  // Capture monitor (async watcher, clk domain)
  // -----------------------------------------------------------------------
  always @(posedge clk) begin
    if (dq_i_valid && n_captures < 2) begin
      cap_cyc[n_captures]  = cyc;
      cap_data[n_captures] = dq_i;
      n_captures++;
    end
  end

  // -----------------------------------------------------------------------
  initial begin
    $display("=== tb_phy_back_to_back_reads ===");
    $display("=== RSHIFT=%0d CL=3 ===", u_phy.READ_CAPTURE_SHIFT);

    drive_nop(); rstn = 0;
    repeat(6) @(posedge clk); #1; rstn = 1;
    @(posedge clk); #1;

    // ACTIVE
    phy_cmd = CMD_ACT; addr_in = ROW0; ba_in = BANK0;
    $display("[cyc=%0d] ACTIVE B%0d R%0d", cyc, BANK0, ROW0);
    @(posedge clk); #1;
    drive_nop();
    repeat(3) @(posedge clk); #1;  // tRCD coverage

    // WRITE col=0
    phy_cmd = CMD_WR; addr_in = {4'b0, COL0}; ba_in = BANK0;
    dq_o = DATA_COL0; dq_oe = 1;
    $display("[cyc=%0d] WRITE C%0d data=0x%04h", cyc, COL0, DATA_COL0);
    @(posedge clk); #1;

    // Hold dq_oe=1: model processes col0 WRITE at sh=M+1, must see DATA_COL0 on DQ.
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0;
    @(posedge clk); #1;

    // WRITE col=1
    phy_cmd = CMD_WR; addr_in = {4'b0, COL1}; ba_in = BANK0;
    dq_o = DATA_COL1; dq_oe = 1;
    $display("[cyc=%0d] WRITE C%0d data=0x%04h", cyc, COL1, DATA_COL1);
    @(posedge clk); #1;

    // Hold dq_oe=1: model processes col1 WRITE at sh=M+1, must see DATA_COL1 on DQ.
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0;
    @(posedge clk); #1;

    // Release DQ, wait tWR=2.
    drive_nop();
    repeat(2) @(posedge clk); #1;

    // READ col=0
    phy_cmd = CMD_RD; addr_in = {4'b0, COL0}; ba_in = BANK0;
    $display("[cyc=%0d] READ C%0d (expect 0x%04h)", cyc, COL0, DATA_COL0);
    @(posedge clk); #1;

    // READ col=1 immediately after
    phy_cmd = CMD_RD; addr_in = {4'b0, COL1}; ba_in = BANK0;
    $display("[cyc=%0d] READ C%0d (expect 0x%04h)", cyc, COL1, DATA_COL1);
    @(posedge clk); #1;

    drive_nop();

    // Wait for 2 captures
    begin : wait_caps
      integer i;
      for (i = 0; i < TIMEOUT && n_captures < 2; i++) begin
        @(posedge clk); #1;
      end
    end

    $display("");
    $display("=== Capture summary ===");
    if (n_captures == 0) begin
      $display("[FAIL] No captures within timeout");
      errors++;
    end else begin
      $display("Capture[0]: cyc=%0d data=0x%04h expected=0x%04h %s",
               cap_cyc[0], cap_data[0], DATA_COL0,
               (cap_data[0] === DATA_COL0) ? "MATCH" : "MISMATCH");
      if (cap_data[0] !== DATA_COL0) errors++;
    end

    if (n_captures < 2) begin
      $display("[FAIL] Only %0d capture(s) within timeout", n_captures);
      errors++;
    end else begin
      $display("Capture[1]: cyc=%0d data=0x%04h expected=0x%04h %s",
               cap_cyc[1], cap_data[1], DATA_COL1,
               (cap_data[1] === DATA_COL1) ? "MATCH" : "MISMATCH");
      if (cap_data[1] !== DATA_COL1) errors++;
      $display("Cycle gap between captures: %0d", cap_cyc[1] - cap_cyc[0]);
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
