// tb_phy_single_read.sv -- PHY + SDRAM model. Single 16-bit read.
// Sweeps READ_CAPTURE_SHIFT via sdram_build_cfg.svh (regenerated per make target).
// Logs every cycle: DQ bus state, dq_i_valid, dq_i.
// Goal: find first cycle where dq_i_valid=1 and dq_i==expected.
`timescale 1ns/1ps

import sdram_pkg::*;

module tb_phy_single_read;

  // -----------------------------------------------------------------------
  // Clocks: clk=0deg, clk_sh=+90deg (=+2ns at 125 MHz / 8ns period)
  // -----------------------------------------------------------------------
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
  logic [3:0]  phy_cmd   = 4'b0111;  // CMD_NOP
  logic [12:0] addr_in   = '0;
  logic [1:0]  ba_in     = '0;
  logic        read_en_in = 0;
  logic [15:0] dq_o      = '0;
  logic        dq_oe     = 0;

  logic [15:0] dq_i;
  logic        dq_i_valid;
  logic        phy_wready;

  logic [12:0] sdram_addr;
  logic [1:0]  sdram_ba;
  logic        sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cs_n, sdram_cke;
  wire  [15:0] sdram_dq;
  wire         sdram_clk;

  // -----------------------------------------------------------------------
  // DUT: PHY
  // -----------------------------------------------------------------------
  sdram_phy #(
    .DATA_WIDTH    (16),
    .ROW_ADDR_WIDTH(13),
    .BANK_ADDR_WIDTH(2),
    .CAS_LATENCY   (3),
    .USE_ALTIOBUF  (0)
  ) u_phy (
    .clk         (clk),
    .clk_sh      (clk_sh),
    .rstn        (rstn),
    .phy_cmd     (phy_cmd),
    .addr_in     (addr_in),
    .ba_in       (ba_in),
    .read_en_in  (read_en_in),
    .dq_o        (dq_o),
    .dq_oe       (dq_oe),
    .dq_i        (dq_i),
    .dq_i_valid  (dq_i_valid),
    .phy_wready  (phy_wready),
    .sdram_addr  (sdram_addr),
    .sdram_ba    (sdram_ba),
    .sdram_ras_n (sdram_ras_n),
    .sdram_cas_n (sdram_cas_n),
    .sdram_we_n  (sdram_we_n),
    .sdram_cs_n  (sdram_cs_n),
    .sdram_dq    (sdram_dq),
    .sdram_clk   (sdram_clk),
    .sdram_cke   (sdram_cke)
  );

  // -----------------------------------------------------------------------
  // SDRAM model (clocked by sdram_clk = clk_sh in SIM)
  // -----------------------------------------------------------------------
  sdram_model_pro #(
    .DATA_WIDTH(16),
    .ROW_WIDTH (13),
    .COL_WIDTH (9),
    .BANKS     (4),
    .tRCD(2), .tRP(2), .tRAS(6), .tWR(2), .tRFC(8),
    .CL(3)
  ) u_sdram (
    .clk  (sdram_clk),
    .rst  (~rstn),
    .addr (sdram_addr),
    .ba   (sdram_ba),
    .ras_n(sdram_ras_n),
    .cas_n(sdram_cas_n),
    .we_n (sdram_we_n),
    .cs_n (sdram_cs_n),
    .dq   (sdram_dq)
  );

  // -----------------------------------------------------------------------
  // Cycle counter (clk domain)
  // -----------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) cyc++;

  // -----------------------------------------------------------------------
  // Cycle-by-cycle monitor (clk_sh domain — SDRAM clock)
  // -----------------------------------------------------------------------
  integer sh_cyc = 0;
  always @(posedge clk_sh) begin
    sh_cyc++;
    $display("[sh=%0d clk=%0d] cs=%b ras=%b cas=%b we=%b | DQ=%04h (Z=%b) | dq_i_valid=%b dq_i=%04h",
             sh_cyc, cyc,
             sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n,
             sdram_dq, $isunknown(sdram_dq),
             dq_i_valid, dq_i);
  end

  // -----------------------------------------------------------------------
  // Test sequence (driven in clk domain)
  // -----------------------------------------------------------------------
  localparam logic [15:0] WRITE_DATA  = 16'hA5C3;
  localparam logic [8:0]  COL_ADDR    = 9'h000;
  localparam logic [12:0] ROW_ADDR    = 13'h0000;
  localparam logic [1:0]  BANK_ADDR   = 2'h0;
  localparam integer      TIMEOUT_CYC = 40;

  integer errors    = 0;
  integer got_valid = 0;

  task drive_nop;
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0;
    dq_oe = 0; dq_o = '0;
  endtask

  initial begin
    $display("=== tb_phy_single_read ===");
    $display("=== READ_CAPTURE_SHIFT=%0d CMD_REG_ON_CLK_SH=%0d CAS_LATENCY=3 ===",
             u_phy.READ_CAPTURE_SHIFT, u_phy.CMD_REG_ON_CLK_SH);

    // ---- Reset ----
    drive_nop();
    rstn = 0;
    repeat(6) @(posedge clk);
    #1; rstn = 1;
    @(posedge clk); #1;

    $display("[cyc=%0d] Reset released", cyc);

    // ---- ACTIVE B0 R0 ----
    phy_cmd = CMD_ACT; addr_in = ROW_ADDR; ba_in = BANK_ADDR;
    $display("[cyc=%0d] Issue ACTIVE B%0d R%0d", cyc, BANK_ADDR, ROW_ADDR);
    @(posedge clk); #1;

    // NOP x3 (covers tRCD=2 from model's perspective, +1 for CMD FF latency)
    drive_nop();
    repeat(3) @(posedge clk); #1;

    // ---- WRITE B0 C0 data=A5C3 ----
    phy_cmd = CMD_WR; addr_in = {4'b0, COL_ADDR}; ba_in = BANK_ADDR;
    dq_o = WRITE_DATA; dq_oe = 1;
    $display("[cyc=%0d] Issue WRITE B%0d C%0d data=0x%04h",
             cyc, BANK_ADDR, COL_ADDR, WRITE_DATA);
    @(posedge clk); #1;

    // CMD FF adds 1 clk_sh latency: model processes WRITE at sh=M+1.
    // Hold dq_oe=1 one extra CLK so sdram_dq is valid when model reads it.
    phy_cmd = CMD_NOP; addr_in = '0; ba_in = '0;
    @(posedge clk); #1;

    // Release DQ, wait tWR=2.
    drive_nop();
    repeat(2) @(posedge clk); #1;

    // ---- READ B0 C0 ----
    phy_cmd = CMD_RD; addr_in = {4'b0, COL_ADDR}; ba_in = BANK_ADDR;
    $display("[cyc=%0d] Issue READ B%0d C%0d (expect dq_i=0x%04h)",
             cyc, BANK_ADDR, COL_ADDR, WRITE_DATA);
    @(posedge clk); #1;

    drive_nop();

    // ---- Wait for dq_i_valid with timeout ----
    begin : wait_valid
      integer i;
      for (i = 0; i < TIMEOUT_CYC; i++) begin
        @(posedge clk); #1;
        if (dq_i_valid) begin
          got_valid = 1;
          $display("[cyc=%0d] dq_i_valid=1  dq_i=0x%04h  (expected=0x%04h)  %s",
                   cyc, dq_i, WRITE_DATA,
                   (dq_i === WRITE_DATA) ? "MATCH" : "MISMATCH");
          if (dq_i !== WRITE_DATA) begin
            $display("[FAIL] dq_i: expected 0x%04h, got 0x%04h (Z=%b)",
                     WRITE_DATA, dq_i, $isunknown(dq_i));
            errors++;
          end
          disable wait_valid;
        end
      end
    end

    if (!got_valid) begin
      $display("[FAIL] Timeout: dq_i_valid never went high in %0d cycles", TIMEOUT_CYC);
      errors++;
    end

    repeat(4) @(posedge clk);

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
