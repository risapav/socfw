// @file tb_axi_native_single_write_read.sv
// @brief M2 integration: AXI-lite write/read through adapter, NWP, PHY, SDRAM model.
// @details AXI write 0x1234_A5C3 at byte addr 0x00, AXI read addr 0x00.
//          Expected: BRESP=OKAY, RRESP=OKAY, RDATA=0x1234_A5C3.
//          Chain: axi_native_adapter -> native_word_port -> bridge -> sdram_phy -> sdram_model_pro.
//          Bridge mux: phase=1 drives ACTIVE B0 R0, phase=3 passes NWP commands.
`timescale 1ns/1ps

import sdram_pkg::*;

module tb_axi_native_single_write_read;

  localparam int CLK_HALF = 4;
  localparam int TIMEOUT  = 80;
  localparam logic [31:0] WDATA    = 32'h1234_A5C3;
  localparam logic [23:0] AXI_ADDR = 24'h000000;

  // -------------------------------------------------------------------------
  // Clocks and reset
  // -------------------------------------------------------------------------
  logic clk    = 0;
  logic clk_sh;
  logic rstn   = 0;

  always #CLK_HALF clk = ~clk;
  initial begin clk_sh = 0; #2; forever #CLK_HALF clk_sh = ~clk_sh; end

  // -------------------------------------------------------------------------
  // AXI-lite signals
  // -------------------------------------------------------------------------
  logic [23:0] s_axi_awaddr  = '0;
  logic        s_axi_awvalid = 1'b0;
  logic        s_axi_awready;

  logic [31:0] s_axi_wdata   = '0;
  logic [3:0]  s_axi_wstrb   = 4'hF;
  logic        s_axi_wvalid  = 1'b0;
  logic        s_axi_wready;

  logic [1:0]  s_axi_bresp;
  logic        s_axi_bvalid;
  logic        s_axi_bready  = 1'b0;

  logic [23:0] s_axi_araddr  = '0;
  logic        s_axi_arvalid = 1'b0;
  logic        s_axi_arready;

  logic [31:0] s_axi_rdata;
  logic [1:0]  s_axi_rresp;
  logic        s_axi_rvalid;
  logic        s_axi_rready  = 1'b0;

  // -------------------------------------------------------------------------
  // Native interface wires (adapter <-> NWP)
  // -------------------------------------------------------------------------
  logic        native_req_valid_w;
  logic        native_req_ready_w;
  logic        native_req_write_w;
  logic [23:0] native_req_addr_w;
  logic [31:0] native_req_wdata_w;
  logic        native_rsp_valid_w;
  logic [31:0] native_rsp_rdata_w;

  // -------------------------------------------------------------------------
  // NWP <-> bridge interface wires
  // -------------------------------------------------------------------------
  logic        phy_cmd_valid_w;
  logic        phy_cmd_ready_w;
  logic        phy_cmd_write_w;
  logic [23:0] phy_cmd_addr_w;
  logic [15:0] phy_wdata_w;
  logic        phy_wdata_oe_w;
  logic        phy_rvalid_w;
  logic [15:0] phy_rdata_w;

  // -------------------------------------------------------------------------
  // PHY <-> SDRAM model wires
  // -------------------------------------------------------------------------
  logic [3:0]  sdram_cmd_w;
  logic [12:0] addr_in_w;
  logic [1:0]  ba_in_w;
  logic        read_en_in_w  = 1'b0;
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

  // -------------------------------------------------------------------------
  // DUTs
  // -------------------------------------------------------------------------
  axi_native_adapter #(
    .AXI_ADDR_WIDTH   (24),
    .AXI_DATA_WIDTH   (32),
    .NATIVE_ADDR_WIDTH(24)
  ) u_axi (
    .clk              (clk),
    .rstn             (rstn),
    .s_axi_awaddr     (s_axi_awaddr),
    .s_axi_awvalid    (s_axi_awvalid),
    .s_axi_awready    (s_axi_awready),
    .s_axi_wdata      (s_axi_wdata),
    .s_axi_wstrb      (s_axi_wstrb),
    .s_axi_wvalid     (s_axi_wvalid),
    .s_axi_wready     (s_axi_wready),
    .s_axi_bresp      (s_axi_bresp),
    .s_axi_bvalid     (s_axi_bvalid),
    .s_axi_bready     (s_axi_bready),
    .s_axi_araddr     (s_axi_araddr),
    .s_axi_arvalid    (s_axi_arvalid),
    .s_axi_arready    (s_axi_arready),
    .s_axi_rdata      (s_axi_rdata),
    .s_axi_rresp      (s_axi_rresp),
    .s_axi_rvalid     (s_axi_rvalid),
    .s_axi_rready     (s_axi_rready),
    .native_req_valid (native_req_valid_w),
    .native_req_ready (native_req_ready_w),
    .native_req_write (native_req_write_w),
    .native_req_addr  (native_req_addr_w),
    .native_req_wdata (native_req_wdata_w),
    .native_rsp_valid (native_rsp_valid_w),
    .native_rsp_rdata (native_rsp_rdata_w)
  );

  native_word_port #(
    .ADDR_WIDTH      (24),
    .SDRAM_DATA_WIDTH(16),
    .WORD_DATA_WIDTH (32)
  ) u_nwp (
    .clk          (clk),
    .rstn         (rstn),
    .req_valid    (native_req_valid_w),
    .req_ready    (native_req_ready_w),
    .req_write    (native_req_write_w),
    .req_addr     (native_req_addr_w),
    .req_wdata    (native_req_wdata_w),
    .rsp_valid    (native_rsp_valid_w),
    .rsp_rdata    (native_rsp_rdata_w),
    .phy_cmd_valid(phy_cmd_valid_w),
    .phy_cmd_ready(phy_cmd_ready_w),
    .phy_cmd_write(phy_cmd_write_w),
    .phy_cmd_addr (phy_cmd_addr_w),
    .phy_wdata    (phy_wdata_w),
    .phy_wdata_oe (phy_wdata_oe_w),
    .phy_rvalid   (phy_rvalid_w),
    .phy_rdata    (phy_rdata_w)
  );

  sdram_phy #(
    .DATA_WIDTH     (16),
    .ROW_ADDR_WIDTH (13),
    .BANK_ADDR_WIDTH(2),
    .CAS_LATENCY    (3),
    .USE_ALTIOBUF   (0)
  ) u_phy (
    .clk        (clk),
    .clk_sh     (clk_sh),
    .rstn       (rstn),
    .phy_cmd    (sdram_cmd_w),
    .addr_in    (addr_in_w),
    .ba_in      (ba_in_w),
    .read_en_in (read_en_in_w),
    .dq_o       (dq_o_w),
    .dq_oe      (dq_oe_w),
    .dq_i       (dq_i_w),
    .dq_i_valid (dq_i_valid_w),
    .phy_wready (phy_wready_w),
    .sdram_addr (sdram_addr),
    .sdram_ba   (sdram_ba),
    .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n),
    .sdram_we_n (sdram_we_n),
    .sdram_cs_n (sdram_cs_n),
    .sdram_dq   (sdram_dq),
    .sdram_clk  (sdram_clk),
    .sdram_cke  (sdram_cke)
  );

  sdram_model_pro #(
    .DATA_WIDTH(16), .ROW_WIDTH(13), .COL_WIDTH(9), .BANKS(4),
    .tRCD(2), .tRP(2), .tRAS(6), .tWR(2), .tRFC(8), .CL(3)
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

  // -------------------------------------------------------------------------
  // Bridge: tb_phase controls mux between INIT (ACTIVE) and READY (native)
  //   0 = reset / NOP
  //   1 = assert ACTIVE B0 R0
  //   2 = tRCD wait (NOP)
  //   3 = native pass-through
  // -------------------------------------------------------------------------
  logic [1:0] tb_phase = 2'd0;

  localparam logic [12:0] ROW_ADDR = 13'h0000;
  localparam logic [1:0]  BANK0    = 2'h0;

  always_comb begin
    sdram_cmd_w     = CMD_NOP;
    addr_in_w       = '0;
    ba_in_w         = '0;
    dq_o_w          = phy_wdata_w;
    dq_oe_w         = phy_wdata_oe_w;
    phy_cmd_ready_w = 1'b0;
    phy_rvalid_w    = dq_i_valid_w;
    phy_rdata_w     = dq_i_w;

    case (tb_phase)
      2'd1: begin
        sdram_cmd_w = CMD_ACT;
        addr_in_w   = ROW_ADDR;
        ba_in_w     = BANK0;
      end
      2'd3: begin
        phy_cmd_ready_w = 1'b1;
        if (phy_cmd_valid_w) begin
          sdram_cmd_w = phy_cmd_write_w ? CMD_WR : CMD_RD;
          addr_in_w   = {4'b0, phy_cmd_addr_w[8:0]};
          ba_in_w     = phy_cmd_addr_w[10:9];
        end
      end
      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // Cycle counters and SDRAM bus trace
  // -------------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) cyc++;

  integer sh_cyc = 0;
  always @(posedge clk_sh) begin
    sh_cyc++;
    $display("[sh=%0d cyc=%0d] cs=%b ras=%b cas=%b we=%b | DQ=%04h dq_i_v=%b dq_i=%04h",
             sh_cyc, cyc,
             sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n,
             sdram_dq, dq_i_valid_w, dq_i_w);
  end

  // -------------------------------------------------------------------------
  integer errors = 0;

  initial begin
    $display("=== tb_axi_native_single_write_read ===");
    $display("=== RSHIFT=%0d CL=3 WDATA=0x%08h ===",
             u_phy.READ_CAPTURE_SHIFT, WDATA);

    rstn = 0; tb_phase = 0;
    repeat(6) @(posedge clk); #1;
    rstn = 1;
    @(posedge clk); #1;

    // ACTIVE B0 R0 -- open bank 0 row 0 before any RD/WR
    tb_phase = 2'd1;
    $display("[cyc=%0d] ACTIVE B0 R0", cyc);
    @(posedge clk); #1;

    // tRCD wait (3 cycles, covers CMD_REG_ON_CLK_SH=1 lag)
    tb_phase = 2'd2;
    repeat(3) @(posedge clk); #1;

    // Switch to native pass-through
    tb_phase = 2'd3;

    // -----------------------------------------------------------------------
    // AXI write
    // -----------------------------------------------------------------------
    s_axi_awaddr  = AXI_ADDR;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = WDATA;
    s_axi_wstrb   = 4'hF;
    s_axi_wvalid  = 1'b1;
    $display("[cyc=%0d] AXI WRITE awaddr=0x%06h wdata=0x%08h", cyc, AXI_ADDR, WDATA);
    @(posedge clk); #1;
    s_axi_awvalid = 1'b0;
    s_axi_wvalid  = 1'b0;

    begin : wait_bvalid
      integer i;
      integer got_b;
      got_b = 0;
      for (i = 0; i < TIMEOUT; i++) begin
        @(posedge clk); #1;
        if (s_axi_bvalid) begin
          got_b = 1;
          $display("[cyc=%0d] AXI BVALID bresp=%02b", cyc, s_axi_bresp);
          if (s_axi_bresp !== 2'b00) begin
            $display("[FAIL] bresp=%02b expected 00 (OKAY)", s_axi_bresp);
            errors++;
          end
          s_axi_bready = 1'b1;
          @(posedge clk); #1;
          s_axi_bready = 1'b0;
          disable wait_bvalid;
        end
      end
      if (!got_b) begin
        $display("[FAIL] Timeout: s_axi_bvalid never asserted in %0d cycles", TIMEOUT);
        errors++;
      end
    end

    // Wait for NWP IDLE (req_ready=1) -- ensures last CMD_WR reached SDRAM
    begin : wait_nwp_wr
      integer i;
      for (i = 0; i < TIMEOUT && !native_req_ready_w; i++) @(posedge clk); #1;
    end
    $display("[cyc=%0d] NWP write complete (req_ready=1)", cyc);

    // tWR safety gap: 2 CLK cycles after NWP IDLE
    repeat(2) @(posedge clk); #1;

    // -----------------------------------------------------------------------
    // AXI read
    // -----------------------------------------------------------------------
    s_axi_araddr  = AXI_ADDR;
    s_axi_arvalid = 1'b1;
    $display("[cyc=%0d] AXI READ araddr=0x%06h expect=0x%08h", cyc, AXI_ADDR, WDATA);
    @(posedge clk); #1;
    s_axi_arvalid = 1'b0;

    begin : wait_rvalid
      integer i;
      integer got_r;
      got_r = 0;
      for (i = 0; i < TIMEOUT; i++) begin
        @(posedge clk); #1;
        if (s_axi_rvalid) begin
          got_r = 1;
          $display("[cyc=%0d] AXI RVALID rresp=%02b rdata=0x%08h expected=0x%08h %s",
                   cyc, s_axi_rresp, s_axi_rdata, WDATA,
                   (s_axi_rdata === WDATA) ? "MATCH" : "MISMATCH");
          if (s_axi_rresp !== 2'b00) begin
            $display("[FAIL] rresp=%02b expected 00 (OKAY)", s_axi_rresp);
            errors++;
          end
          if (s_axi_rdata !== WDATA) begin
            $display("[FAIL] rdata mismatch: got=0x%08h expected=0x%08h",
                     s_axi_rdata, WDATA);
            errors++;
          end
          s_axi_rready = 1'b1;
          @(posedge clk); #1;
          s_axi_rready = 1'b0;
          disable wait_rvalid;
        end
      end
      if (!got_r) begin
        $display("[FAIL] Timeout: s_axi_rvalid never asserted in %0d cycles", TIMEOUT);
        errors++;
      end
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
