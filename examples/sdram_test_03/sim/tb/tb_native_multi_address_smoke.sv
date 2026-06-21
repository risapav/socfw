// tb_native_multi_address_smoke.sv -- 3-address native R/W smoke test.
// native_word_port + sdram_phy + sdram_model_pro.
// Writes 3 x 32-bit words at halfword base addresses 0, 2, 4; reads back and verifies.
// Address rule: req_addr = halfword base; 32-bit word occupies req_addr and req_addr+1.
`timescale 1ns/1ps

import sdram_pkg::*;

module tb_native_multi_address_smoke;

  localparam integer CLK_HALF = 4;

  logic clk    = 0;
  logic clk_sh;
  logic rstn   = 0;

  always #CLK_HALF clk = ~clk;
  initial begin clk_sh = 0; #2; forever #CLK_HALF clk_sh = ~clk_sh; end

  // -----------------------------------------------------------------------
  // Native interface
  // -----------------------------------------------------------------------
  logic        req_valid = 0;
  logic        req_ready;
  logic        req_write = 0;
  logic [23:0] req_addr  = '0;
  logic [31:0] req_wdata = '0;

  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  // -----------------------------------------------------------------------
  // Flat PHY interface (native_word_port <-> bridge)
  // -----------------------------------------------------------------------
  logic        phy_cmd_valid;
  logic        phy_cmd_ready;
  logic        phy_cmd_write;
  logic [23:0] phy_cmd_addr;
  logic [15:0] phy_wdata;
  logic        phy_wdata_oe;

  logic        phy_rvalid;
  logic [15:0] phy_rdata;

  // -----------------------------------------------------------------------
  // sdram_phy wires
  // -----------------------------------------------------------------------
  logic [3:0]  sdram_cmd_w;
  logic [12:0] addr_in_w;
  logic [1:0]  ba_in_w;
  logic        read_en_in_w = 0;
  logic [15:0] dq_o_w;
  logic        dq_oe_w;
  logic [15:0] dq_i_w;
  logic        dq_i_valid_w;
  logic        phy_wready_w;

  logic [12:0] sdram_addr;
  logic [1:0]  sdram_ba;
  logic        sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cs_n, sdram_cke;
  wire  [15:0] sdram_dq;
  wire         sdram_clk;

  // -----------------------------------------------------------------------
  // DUT: native_word_port
  // -----------------------------------------------------------------------
  native_word_port u_nat (
    .clk          (clk),
    .rstn         (rstn),
    .req_valid    (req_valid),
    .req_ready    (req_ready),
    .req_write    (req_write),
    .req_addr     (req_addr),
    .req_wdata    (req_wdata),
    .rsp_valid    (rsp_valid),
    .rsp_rdata    (rsp_rdata),
    .phy_cmd_valid(phy_cmd_valid),
    .phy_cmd_ready(phy_cmd_ready),
    .phy_cmd_write(phy_cmd_write),
    .phy_cmd_addr (phy_cmd_addr),
    .phy_wdata    (phy_wdata),
    .phy_wdata_oe (phy_wdata_oe),
    .phy_rvalid   (phy_rvalid),
    .phy_rdata    (phy_rdata)
  );

  // -----------------------------------------------------------------------
  // sdram_phy
  // -----------------------------------------------------------------------
  sdram_phy #(
    .DATA_WIDTH     (16),
    .ROW_ADDR_WIDTH (13),
    .BANK_ADDR_WIDTH(2),
    .CAS_LATENCY    (3),
    .USE_ALTIOBUF   (0)
  ) u_phy (
    .clk        (clk),        .clk_sh     (clk_sh),        .rstn       (rstn),
    .phy_cmd    (sdram_cmd_w), .addr_in    (addr_in_w),     .ba_in      (ba_in_w),
    .read_en_in (read_en_in_w),
    .dq_o       (dq_o_w),     .dq_oe      (dq_oe_w),
    .dq_i       (dq_i_w),     .dq_i_valid (dq_i_valid_w),  .phy_wready (phy_wready_w),
    .sdram_addr (sdram_addr),  .sdram_ba   (sdram_ba),
    .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
    .sdram_we_n (sdram_we_n),  .sdram_cs_n (sdram_cs_n),
    .sdram_dq   (sdram_dq),    .sdram_clk  (sdram_clk),    .sdram_cke  (sdram_cke)
  );

  // -----------------------------------------------------------------------
  // SDRAM model
  // -----------------------------------------------------------------------
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
  // Bridge: tb_phase mux
  //   0 = reset/NOP
  //   1 = ACTIVE B0 R0
  //   2 = tRCD wait (NOP)
  //   3 = native pass-through
  // -----------------------------------------------------------------------
  logic [1:0] tb_phase = 2'd0;

  localparam logic [12:0] ROW_ADDR = 13'h0000;
  localparam logic [1:0]  BANK0    = 2'h0;

  always_comb begin
    sdram_cmd_w    = CMD_NOP;
    addr_in_w      = '0;
    ba_in_w        = '0;
    dq_o_w         = phy_wdata;
    dq_oe_w        = phy_wdata_oe;
    phy_cmd_ready  = 1'b0;
    phy_rvalid     = dq_i_valid_w;
    phy_rdata      = dq_i_w;

    case (tb_phase)
      2'd1: begin
        sdram_cmd_w = CMD_ACT;
        addr_in_w   = ROW_ADDR;
        ba_in_w     = BANK0;
      end
      2'd3: begin
        phy_cmd_ready = 1'b1;
        if (phy_cmd_valid) begin
          sdram_cmd_w = phy_cmd_write ? CMD_WR : CMD_RD;
          addr_in_w   = {4'b0, phy_cmd_addr[8:0]};
          ba_in_w     = phy_cmd_addr[10:9];
        end
      end
      default: ;
    endcase
  end

  // -----------------------------------------------------------------------
  // Cycle counter
  // -----------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) cyc++;

  // -----------------------------------------------------------------------
  // Test data: 3 x 32-bit words at halfword base addresses 0, 2, 4
  // -----------------------------------------------------------------------
  localparam integer N_OPS   = 3;
  localparam integer TIMEOUT = 200;

  localparam logic [31:0] WDATA [0:2] = '{32'h1234_A5C3, 32'hDEAD_BEEF, 32'hCAFE_5678};
  localparam logic [23:0] ADDRS [0:2] = '{24'h000000,    24'h000002,    24'h000004};

  integer      errors   = 0;
  logic [31:0] got_data [0:2];
  integer      got_cyc  [0:2];

  integer idx, i, got;

  // -----------------------------------------------------------------------
  // Test sequence
  // -----------------------------------------------------------------------
  initial begin
    $display("=== tb_native_multi_address_smoke ===");
    $display("=== RSHIFT=%0d CL=3 N_OPS=%0d ===", u_phy.READ_CAPTURE_SHIFT, N_OPS);

    got_data[0] = 32'h0; got_data[1] = 32'h0; got_data[2] = 32'h0;
    got_cyc[0]  = 0;     got_cyc[1]  = 0;     got_cyc[2]  = 0;

    rstn = 0; tb_phase = 0;
    repeat(6) @(posedge clk); #1;
    rstn = 1;
    @(posedge clk); #1;

    // ACTIVE B0 R0
    tb_phase = 2'd1;
    $display("[cyc=%0d] ACTIVE B0 R0", cyc);
    @(posedge clk); #1;

    // tRCD wait
    tb_phase = 2'd2;
    repeat(3) @(posedge clk); #1;

    tb_phase = 2'd3;

    // -------------------------------------------------------------------
    // Write phase: 3 words at halfword base addresses 0, 2, 4
    // -------------------------------------------------------------------
    for (idx = 0; idx < N_OPS; idx++) begin
      req_valid = 1; req_write = 1;
      req_addr  = ADDRS[idx];
      req_wdata = WDATA[idx];
      $display("[cyc=%0d] WR[%0d] addr=0x%06h wdata=0x%08h",
               cyc, idx, ADDRS[idx], WDATA[idx]);
      @(posedge clk); #1;
      req_valid = 0;
      // Wait for write complete (req_ready=1 means state=ST_IDLE)
      for (i = 0; i < TIMEOUT && !req_ready; i++) @(posedge clk);
      #1;
      $display("[cyc=%0d] WR[%0d] complete", cyc, idx);
      // tWR safety gap before next operation
      repeat(2) @(posedge clk); #1;
    end

    // -------------------------------------------------------------------
    // Read phase: read back addr 0, 2, 4
    // -------------------------------------------------------------------
    for (idx = 0; idx < N_OPS; idx++) begin
      req_valid = 1; req_write = 0;
      req_addr  = ADDRS[idx];
      $display("[cyc=%0d] RD[%0d] addr=0x%06h expect=0x%08h",
               cyc, idx, ADDRS[idx], WDATA[idx]);
      @(posedge clk); #1;
      req_valid = 0;

      got = 0;
      for (i = 0; i < TIMEOUT && !got; i++) begin
        @(posedge clk); #1;
        if (rsp_valid) begin
          got           = 1;
          got_data[idx] = rsp_rdata;
          got_cyc[idx]  = cyc;
          $display("[cyc=%0d] RD[%0d] addr=0x%06h expected=0x%08h actual=0x%08h rsp_cyc=%0d %s",
                   cyc, idx, ADDRS[idx], WDATA[idx], rsp_rdata, cyc,
                   (rsp_rdata === WDATA[idx]) ? "PASS" : "FAIL");
          if (rsp_rdata !== WDATA[idx]) errors++;
        end
      end
      if (!got) begin
        $display("[FAIL] RD[%0d] timeout: rsp_valid not asserted in %0d cycles", idx, TIMEOUT);
        errors++;
      end
    end

    repeat(4) @(posedge clk);

    // -------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------
    $display("-------------------------------------------");
    $display("SUMMARY:");
    for (idx = 0; idx < N_OPS; idx++) begin
      $display("  RD[%0d] addr=0x%06h expected=0x%08h actual=0x%08h rsp_cyc=%0d %s",
               idx, ADDRS[idx], WDATA[idx], got_data[idx], got_cyc[idx],
               (got_data[idx] === WDATA[idx]) ? "PASS" : "FAIL");
    end
    $display("-------------------------------------------");
    $display("  errors=%0d", errors);

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
