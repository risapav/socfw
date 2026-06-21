// @file tb_axi_native_raw_read_after_bvalid.sv
// @brief M2b: AXI read issued immediately after BVALID -- no manual NWP wait.
// @details Hazard test: BVALID fires when NWP accepts the write request, not when
//          the SDRAM write physically completes. Tests whether issuing AR immediately
//          after BVALID causes data corruption. Chain: axi_native_adapter ->
//          native_word_port -> bridge -> sdram_phy -> sdram_model_pro.
//          Key invariant under test: ST_RD_ISSU naturally serializes via native_req_ready.
`timescale 1ns/1ps

import sdram_pkg::*;

module tb_axi_native_raw_read_after_bvalid;

  localparam int CLK_HALF = 4;
  localparam int TIMEOUT  = 100;
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
  // SDRAM command decode for event tracking (combinatorial -- pre-edge)
  // -------------------------------------------------------------------------
  wire cmd_wr_on_w = (!sdram_cs_n && sdram_ras_n && !sdram_cas_n && !sdram_we_n);
  wire cmd_rd_on_w = (!sdram_cs_n && sdram_ras_n && !sdram_cas_n &&  sdram_we_n);

  // -------------------------------------------------------------------------
  // Cycle counters
  // -------------------------------------------------------------------------
  integer cyc    = 0;
  integer sh_cyc = 0;
  always @(posedge clk)    cyc++;

  // -------------------------------------------------------------------------
  // Event cycle records
  //   clk domain events: set via initial block (post-#1 = post-NBA)
  //   ev_nwp_done_cyc: set in always @(posedge clk) via cyc+1 (= posedge N number)
  //   clk_sh domain events: set in always @(posedge clk_sh)
  // -------------------------------------------------------------------------
  integer ev_aw_cyc       = 0;
  integer ev_w_cyc        = 0;
  integer ev_bvalid_cyc   = 0;
  integer ev_nwp_done_cyc = 0;
  integer ev_ar_cyc       = 0;
  integer ev_rvalid_cyc   = 0;
  integer ev_wr_lo_sh     = 0;
  integer ev_wr_hi_sh     = 0;
  integer ev_rd_lo_sh     = 0;
  integer ev_rd_hi_sh     = 0;
  integer ev_dqi_lo_sh    = 0;
  integer ev_dqi_hi_sh    = 0;

  logic write_handshook = 0;
  logic ev_nwp_done_f   = 0;
  logic ev_wr_lo_f      = 0;
  logic ev_wr_hi_f      = 0;
  logic ev_rd_lo_f      = 0;
  logic ev_rd_hi_f      = 0;
  logic ev_dqi_lo_f     = 0;
  logic ev_dqi_hi_f     = 0;

  // -------------------------------------------------------------------------
  // CLK domain: NWP write-done detection
  //   write_handshook: set when NWP accepts native write req (req_ready=1, write=1)
  //   ev_nwp_done_cyc: first cycle where req_ready returns to 1 AFTER write_handshook
  // -------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rstn) begin
      if (!write_handshook
          && native_req_valid_w && native_req_write_w && native_req_ready_w)
        write_handshook <= 1;

      if (write_handshook && !ev_nwp_done_f && native_req_ready_w) begin
        ev_nwp_done_cyc = cyc + 1;
        ev_nwp_done_f  <= 1;
        $display("[cyc=%0d] NWP req_ready=1 (write complete)", cyc + 1);
      end
    end
  end

  // -------------------------------------------------------------------------
  // CLK_SH domain: SDRAM bus trace + CMD_WR / CMD_RD / dq_i_valid event capture
  // -------------------------------------------------------------------------
  always @(posedge clk_sh) begin
    sh_cyc++;
    $display("[sh=%0d cyc=%0d] cs=%b ras=%b cas=%b we=%b | DQ=%04h dq_i_v=%b dq_i=%04h",
             sh_cyc, cyc,
             sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n,
             sdram_dq, dq_i_valid_w, dq_i_w);
    if (rstn) begin
      if (cmd_wr_on_w) begin
        if (!ev_wr_lo_f) begin
          ev_wr_lo_sh = sh_cyc;
          ev_wr_lo_f <= 1;
          $display("[sh=%0d] EVENT: CMD_WR lo", sh_cyc);
        end else if (!ev_wr_hi_f) begin
          ev_wr_hi_sh = sh_cyc;
          ev_wr_hi_f <= 1;
          $display("[sh=%0d] EVENT: CMD_WR hi", sh_cyc);
        end
      end
      if (cmd_rd_on_w) begin
        if (!ev_rd_lo_f) begin
          ev_rd_lo_sh = sh_cyc;
          ev_rd_lo_f <= 1;
          $display("[sh=%0d] EVENT: CMD_RD lo", sh_cyc);
        end else if (!ev_rd_hi_f) begin
          ev_rd_hi_sh = sh_cyc;
          ev_rd_hi_f <= 1;
          $display("[sh=%0d] EVENT: CMD_RD hi", sh_cyc);
        end
      end
      if (dq_i_valid_w) begin
        if (!ev_dqi_lo_f) begin
          ev_dqi_lo_sh = sh_cyc;
          ev_dqi_lo_f <= 1;
          $display("[sh=%0d] EVENT: dq_i_valid lo dq_i=%04h", sh_cyc, dq_i_w);
        end else if (!ev_dqi_hi_f) begin
          ev_dqi_hi_sh = sh_cyc;
          ev_dqi_hi_f <= 1;
          $display("[sh=%0d] EVENT: dq_i_valid hi dq_i=%04h", sh_cyc, dq_i_w);
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  integer errors = 0;
  logic [31:0] rdata_captured = '0;

  initial begin
    $display("=== tb_axi_native_raw_read_after_bvalid ===");
    $display("=== RSHIFT=%0d CL=3 WDATA=0x%08h ===",
             u_phy.READ_CAPTURE_SHIFT, WDATA);

    rstn = 0; tb_phase = 0;
    repeat(6) @(posedge clk); #1;
    rstn = 1;
    @(posedge clk); #1;

    // ACTIVE B0 R0 -- open bank 0 row 0
    tb_phase = 2'd1;
    $display("[cyc=%0d] ACTIVE B0 R0", cyc);
    @(posedge clk); #1;

    // tRCD wait (3 cycles, covers CMD_REG_ON_CLK_SH=1 lag)
    tb_phase = 2'd2;
    repeat(3) @(posedge clk); #1;

    // Switch to native pass-through
    tb_phase = 2'd3;

    // -----------------------------------------------------------------------
    // AXI write: AW+W simultaneously, adapter IDLE -> ST_WR_ISSU at this posedge
    // -----------------------------------------------------------------------
    s_axi_awaddr  = AXI_ADDR;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = WDATA;
    s_axi_wstrb   = 4'hF;
    s_axi_wvalid  = 1'b1;
    @(posedge clk); #1;
    // Handshake occurred at this posedge (adapter IDLE: awready=1, wready=1)
    ev_aw_cyc = cyc;
    ev_w_cyc  = cyc;
    $display("[cyc=%0d] AXI AW handshake awaddr=0x%06h", cyc, AXI_ADDR);
    $display("[cyc=%0d] AXI W  handshake wdata=0x%08h wstrb=%04b", cyc, WDATA, 4'hF);
    s_axi_awvalid = 1'b0;
    s_axi_wvalid  = 1'b0;

    begin : wait_bvalid
      integer i;
      integer got_b;
      got_b = 0;
      for (i = 0; i < TIMEOUT; i++) begin
        @(posedge clk); #1;
        if (s_axi_bvalid) begin
          got_b       = 1;
          ev_bvalid_cyc = cyc;
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

    // *** KEY: NO wait_nwp_wr. NO tWR gap. AR issued immediately. ***

    // -----------------------------------------------------------------------
    // AXI read -- immediate after BVALID accepted, no NWP-ready wait
    // -----------------------------------------------------------------------
    s_axi_araddr  = AXI_ADDR;
    s_axi_arvalid = 1'b1;
    @(posedge clk); #1;
    ev_ar_cyc = cyc;
    $display("[cyc=%0d] AXI AR handshake araddr=0x%06h", cyc, AXI_ADDR);
    s_axi_arvalid = 1'b0;

    begin : wait_rvalid
      integer i;
      integer got_r;
      got_r = 0;
      for (i = 0; i < TIMEOUT; i++) begin
        @(posedge clk); #1;
        if (s_axi_rvalid) begin
          got_r          = 1;
          ev_rvalid_cyc  = cyc;
          rdata_captured = s_axi_rdata;
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

    repeat(4) @(posedge clk); #1;

    $display("==============================================");
    $display("  EVENT SUMMARY");
    $display("  AXI AW handshake:           cyc=%0d", ev_aw_cyc);
    $display("  AXI W  handshake:           cyc=%0d", ev_w_cyc);
    $display("  AXI BVALID:                 cyc=%0d", ev_bvalid_cyc);
    $display("  SDRAM CMD_WR lo:            sh=%0d",  ev_wr_lo_sh);
    $display("  SDRAM CMD_WR hi:            sh=%0d",  ev_wr_hi_sh);
    $display("  NWP req_ready (wr done):    cyc=%0d", ev_nwp_done_cyc);
    $display("  AXI AR handshake:           cyc=%0d", ev_ar_cyc);
    $display("  SDRAM CMD_RD lo:            sh=%0d",  ev_rd_lo_sh);
    $display("  SDRAM CMD_RD hi:            sh=%0d",  ev_rd_hi_sh);
    $display("  dq_i_valid lo:              sh=%0d",  ev_dqi_lo_sh);
    $display("  dq_i_valid hi:              sh=%0d",  ev_dqi_hi_sh);
    $display("  AXI RVALID:                 cyc=%0d", ev_rvalid_cyc);
    $display("  RDATA actual:   0x%08h", rdata_captured);
    $display("  RDATA expected: 0x%08h", WDATA);
    $display("  BVALID_BEFORE_WRITE_COMPLETE = %s",
             (ev_bvalid_cyc < ev_nwp_done_cyc) ? "YES" : "NO");
    $display("  READ_ISSUED_WITHOUT_MANUAL_NATIVE_WAIT = YES");
    $display("==============================================");

    if (errors == 0) begin
      $display("  *** PASS *** (errors=%0d)", errors);
    end else begin
      $display("  *** FAIL *** (errors=%0d)", errors);
    end
    $display("==============================================");
    $finish;
  end

endmodule
