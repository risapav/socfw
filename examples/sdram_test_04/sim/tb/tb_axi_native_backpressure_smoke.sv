// @file tb_axi_native_backpressure_smoke.sv
// @brief M4: AXI backpressure smoke -- BREADY stall (B1), normal write (B2),
//            RREADY stall (R1), normal read (R2). Full chain.
// @details B1: write ADDR0 with 3-cycle BREADY hold; injects AW+W to verify
//          AWREADY=0/WREADY=0 during stall. B2: normal write ADDR4.
//          R1: read ADDR0 with 3-cycle RREADY hold; injects AR to verify
//          ARREADY=0 and RDATA/RVALID stability. R2: normal read ADDR4.
//          Chain: axi_native_adapter -> native_word_port -> sdram_phy -> sdram_model_pro.
`timescale 1ns/1ps

import sdram_pkg::*;

module tb_axi_native_backpressure_smoke;

  localparam int CLK_HALF = 4;
  localparam int TIMEOUT  = 150;

  localparam logic [23:0] ADDR0  = 24'h000000;
  localparam logic [23:0] ADDR4  = 24'h000004;
  localparam logic [31:0] WDATA0 = 32'h1234_A5C3;
  localparam logic [31:0] WDATA4 = 32'hDEAD_BEEF;

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
  // Bridge: tb_phase controls ACTIVE vs native pass-through
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
  // Cycle counter
  // -------------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) cyc++;

  // -------------------------------------------------------------------------
  // Test state
  // -------------------------------------------------------------------------
  integer errors          = 0;

  integer b1_bvalid_cyc   = 0;
  integer b1_bvalid_cnt   = 0;
  integer b1_bresp_cnt    = 0;
  integer b1_awready_cnt  = 0;
  integer b1_wready_cnt   = 0;
  integer b1_complete_cyc = 0;

  integer r1_rvalid_cyc   = 0;
  integer r1_rvalid_cnt   = 0;
  integer r1_rresp_cnt    = 0;
  integer r1_rdata_cnt    = 0;
  integer r1_arready_cnt  = 0;

  logic [31:0] r1_rdata_cap = '0;
  logic [31:0] r2_rdata_cap = '0;

  // -------------------------------------------------------------------------
  // Simple write task (no stall -- B2)
  // -------------------------------------------------------------------------
  task automatic do_axi_write(
    input [23:0] axi_addr,
    input [31:0] wdata,
    input integer idx
  );
    integer i;
    integer got_b;
    s_axi_awaddr  = axi_addr;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = wdata;
    s_axi_wstrb   = 4'hF;
    s_axi_wvalid  = 1'b1;
    @(posedge clk); #1;
    $display("[cyc=%0d] W%0d AXI AW+W awaddr=0x%06h wdata=0x%08h",
             cyc, idx, axi_addr, wdata);
    s_axi_awvalid = 1'b0;
    s_axi_wvalid  = 1'b0;
    got_b = 0;
    for (i = 0; i < TIMEOUT; i++) begin
      @(posedge clk); #1;
      if (s_axi_bvalid) begin
        got_b = 1;
        $display("[cyc=%0d] W%0d AXI BVALID bresp=%02b", cyc, idx, s_axi_bresp);
        if (s_axi_bresp !== 2'b00) begin
          $display("[FAIL] W%0d bresp=%02b expected 00", idx, s_axi_bresp);
          errors++;
        end
        s_axi_bready = 1'b1;
        @(posedge clk); #1;
        s_axi_bready = 1'b0;
        break;
      end
    end
    if (!got_b) begin
      $display("[FAIL] W%0d Timeout: BVALID not seen in %0d cycles", idx, TIMEOUT);
      errors++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Simple read task (no stall -- R2)
  // -------------------------------------------------------------------------
  task automatic do_axi_read(
    input  [23:0] axi_addr,
    input  [31:0] exp_data,
    input  integer idx,
    output logic [31:0] rdata_out
  );
    integer i;
    integer got_r;
    s_axi_araddr  = axi_addr;
    s_axi_arvalid = 1'b1;
    @(posedge clk); #1;
    $display("[cyc=%0d] R%0d AXI AR araddr=0x%06h", cyc, idx, axi_addr);
    s_axi_arvalid = 1'b0;
    rdata_out = '0;
    got_r     = 0;
    for (i = 0; i < TIMEOUT; i++) begin
      @(posedge clk); #1;
      if (s_axi_rvalid) begin
        got_r     = 1;
        rdata_out = s_axi_rdata;
        $display("[cyc=%0d] R%0d AXI RVALID rresp=%02b rdata=0x%08h expected=0x%08h %s",
                 cyc, idx, s_axi_rresp, s_axi_rdata, exp_data,
                 (s_axi_rdata === exp_data) ? "MATCH" : "MISMATCH");
        if (s_axi_rresp !== 2'b00) begin
          $display("[FAIL] R%0d rresp=%02b expected 00", idx, s_axi_rresp);
          errors++;
        end
        if (s_axi_rdata !== exp_data) begin
          $display("[FAIL] R%0d rdata=0x%08h expected=0x%08h", idx, s_axi_rdata, exp_data);
          errors++;
        end
        s_axi_rready = 1'b1;
        @(posedge clk); #1;
        s_axi_rready = 1'b0;
        break;
      end
    end
    if (!got_r) begin
      $display("[FAIL] R%0d Timeout: RVALID not seen in %0d cycles", idx, TIMEOUT);
      errors++;
    end
  endtask

  // -------------------------------------------------------------------------
  initial begin
    $display("=== tb_axi_native_backpressure_smoke ===");
    $display("=== RSHIFT=%0d CL=3 ===", u_phy.READ_CAPTURE_SHIFT);
    $display("=== WDATA0=0x%08h WDATA4=0x%08h ===", WDATA0, WDATA4);

    rstn = 0; tb_phase = 0;
    repeat(6) @(posedge clk); #1;
    rstn = 1;
    @(posedge clk); #1;

    // Open bank 0 row 0 -- covers col 0-3 (ADDR0 and ADDR4)
    tb_phase = 2'd1;
    $display("[cyc=%0d] ACTIVE B0 R0", cyc);
    @(posedge clk); #1;

    // tRCD wait
    tb_phase = 2'd2;
    repeat(3) @(posedge clk); #1;

    // Enable native pass-through
    tb_phase = 2'd3;

    // =====================================================================
    // B1: BREADY stall -- write ADDR0, hold BREADY=0 for 3 cycles
    // =====================================================================
    $display("[cyc=%0d] === B1: BREADY stall write ADDR0=0x%08h ===", cyc, WDATA0);
    s_axi_awaddr  = ADDR0;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = WDATA0;
    s_axi_wstrb   = 4'hF;
    s_axi_wvalid  = 1'b1;
    @(posedge clk); #1;
    $display("[cyc=%0d] B1 AXI AW+W awaddr=0x%06h wdata=0x%08h", cyc, ADDR0, WDATA0);
    s_axi_awvalid = 1'b0;
    s_axi_wvalid  = 1'b0;

    // Wait for B1 BVALID (do not assert BREADY yet)
    begin : wait_b1_bvalid
      integer i;
      for (i = 0; i < TIMEOUT; i++) begin
        @(posedge clk); #1;
        if (s_axi_bvalid) begin
          b1_bvalid_cyc = cyc;
          $display("[cyc=%0d] B1 BVALID bresp=%02b -- BREADY held 0", cyc, s_axi_bresp);
          disable wait_b1_bvalid;
        end
      end
      $display("[FAIL] B1 Timeout: BVALID not seen in %0d cycles", TIMEOUT);
      errors++;
    end

    // Inject AW+W for ADDR4 to probe AWREADY/WREADY blocking during B1 stall
    s_axi_awaddr  = ADDR4;
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = WDATA4;
    s_axi_wstrb   = 4'hF;
    s_axi_wvalid  = 1'b1;

    // 3 stall cycles -- check BVALID/BRESP stable, AWREADY/WREADY blocked
    begin : b1_stall_loop
      integer i;
      for (i = 0; i < 3; i++) begin
        @(posedge clk); #1;
        b1_bvalid_cnt  += (s_axi_bvalid  === 1'b1)  ? 1 : 0;
        b1_bresp_cnt   += (s_axi_bresp   === 2'b00) ? 1 : 0;
        b1_awready_cnt += (s_axi_awready === 1'b0)  ? 1 : 0;
        b1_wready_cnt  += (s_axi_wready  === 1'b0)  ? 1 : 0;
        $display("[cyc=%0d] B1 stall cy%0d: bvalid=%b bresp=%02b awready=%b wready=%b",
                 cyc, i+1, s_axi_bvalid, s_axi_bresp, s_axi_awready, s_axi_wready);
        if (s_axi_bvalid !== 1'b1) begin
          $display("[FAIL] B1 cy%0d: BVALID dropped", i+1); errors++;
        end
        if (s_axi_bresp !== 2'b00) begin
          $display("[FAIL] B1 cy%0d: BRESP=%02b expected 00", i+1, s_axi_bresp); errors++;
        end
        if (s_axi_awready !== 1'b0) begin
          $display("[FAIL] B1 cy%0d: AWREADY=1 expected 0", i+1); errors++;
        end
        if (s_axi_wready !== 1'b0) begin
          $display("[FAIL] B1 cy%0d: WREADY=1 expected 0", i+1); errors++;
        end
      end
    end

    // Clear injected signals, then release BREADY
    s_axi_awvalid = 1'b0;
    s_axi_wvalid  = 1'b0;
    s_axi_bready  = 1'b1;
    @(posedge clk); #1;
    s_axi_bready   = 1'b0;
    b1_complete_cyc = cyc;
    $display("[cyc=%0d] B1 BREADY released, write complete", cyc);

    // =====================================================================
    // B2: normal write -- ADDR4 (no stall)
    // =====================================================================
    $display("[cyc=%0d] === B2: normal write ADDR4=0x%08h ===", cyc, WDATA4);
    do_axi_write(ADDR4, WDATA4, 2);

    // =====================================================================
    // R1: RREADY stall -- read ADDR0, hold RREADY=0 for 3 cycles
    // =====================================================================
    $display("[cyc=%0d] === R1: RREADY stall read ADDR0 expected=0x%08h ===", cyc, WDATA0);
    s_axi_araddr  = ADDR0;
    s_axi_arvalid = 1'b1;
    @(posedge clk); #1;
    $display("[cyc=%0d] R1 AXI AR araddr=0x%06h", cyc, ADDR0);
    s_axi_arvalid = 1'b0;

    // Wait for R1 RVALID (do not assert RREADY yet)
    begin : wait_r1_rvalid
      integer i;
      for (i = 0; i < TIMEOUT; i++) begin
        @(posedge clk); #1;
        if (s_axi_rvalid) begin
          r1_rvalid_cyc = cyc;
          r1_rdata_cap  = s_axi_rdata;
          $display("[cyc=%0d] R1 RVALID rresp=%02b rdata=0x%08h -- RREADY held 0",
                   cyc, s_axi_rresp, s_axi_rdata);
          disable wait_r1_rvalid;
        end
      end
      $display("[FAIL] R1 Timeout: RVALID not seen in %0d cycles", TIMEOUT);
      errors++;
    end

    // Inject AR for ADDR4 to probe ARREADY blocking during R1 stall
    s_axi_araddr  = ADDR4;
    s_axi_arvalid = 1'b1;

    // 3 stall cycles -- check RVALID/RRESP/RDATA stable, ARREADY blocked
    begin : r1_stall_loop
      integer i;
      for (i = 0; i < 3; i++) begin
        @(posedge clk); #1;
        r1_rvalid_cnt  += (s_axi_rvalid  === 1'b1)   ? 1 : 0;
        r1_rresp_cnt   += (s_axi_rresp   === 2'b00)  ? 1 : 0;
        r1_rdata_cnt   += (s_axi_rdata   === WDATA0) ? 1 : 0;
        r1_arready_cnt += (s_axi_arready === 1'b0)   ? 1 : 0;
        $display("[cyc=%0d] R1 stall cy%0d: rvalid=%b rresp=%02b rdata=0x%08h arready=%b",
                 cyc, i+1, s_axi_rvalid, s_axi_rresp, s_axi_rdata, s_axi_arready);
        if (s_axi_rvalid !== 1'b1) begin
          $display("[FAIL] R1 cy%0d: RVALID dropped", i+1); errors++;
        end
        if (s_axi_rresp !== 2'b00) begin
          $display("[FAIL] R1 cy%0d: RRESP=%02b expected 00", i+1, s_axi_rresp); errors++;
        end
        if (s_axi_rdata !== WDATA0) begin
          $display("[FAIL] R1 cy%0d: RDATA=0x%08h expected=0x%08h",
                   i+1, s_axi_rdata, WDATA0); errors++;
        end
        if (s_axi_arready !== 1'b0) begin
          $display("[FAIL] R1 cy%0d: ARREADY=1 expected 0", i+1); errors++;
        end
      end
    end

    // Clear injected AR, release RREADY
    s_axi_arvalid = 1'b0;
    s_axi_rready  = 1'b1;
    @(posedge clk); #1;
    s_axi_rready = 1'b0;
    $display("[cyc=%0d] R1 RREADY released RDATA=0x%08h expected=0x%08h %s",
             cyc, r1_rdata_cap, WDATA0,
             (r1_rdata_cap === WDATA0) ? "MATCH" : "MISMATCH");
    if (r1_rdata_cap !== WDATA0) begin
      $display("[FAIL] R1 rdata=0x%08h expected=0x%08h", r1_rdata_cap, WDATA0);
      errors++;
    end

    // =====================================================================
    // R2: normal read -- ADDR4 (no stall)
    // =====================================================================
    $display("[cyc=%0d] === R2: normal read ADDR4 expected=0x%08h ===", cyc, WDATA4);
    do_axi_read(ADDR4, WDATA4, 2, r2_rdata_cap);

    repeat(4) @(posedge clk); #1;

    // =====================================================================
    // Summary
    // =====================================================================
    $display("==============================================");
    $display("  B1 BREADY stall:");
    $display("  BVALID cycle:       cyc=%0d", b1_bvalid_cyc);
    $display("  BREADY stall:       3 cycles");
    $display("  BRESP stable:       %0d/3 cycles OKAY", b1_bresp_cnt);
    $display("  AWREADY blocked:    %0d/3 cycles", b1_awready_cnt);
    $display("  WREADY blocked:     %0d/3 cycles", b1_wready_cnt);
    $display("  write complete:     cyc=%0d", b1_complete_cyc);
    $display("  R1 RREADY stall:");
    $display("  RVALID cycle:       cyc=%0d", r1_rvalid_cyc);
    $display("  RREADY stall:       3 cycles");
    $display("  RDATA stable:       %0d/3 cycles == 0x%08h", r1_rdata_cnt, WDATA0);
    $display("  ARREADY blocked:    %0d/3 cycles", r1_arready_cnt);
    $display("  RDATA actual:       0x%08h", r1_rdata_cap);
    $display("  RDATA expected:     0x%08h", WDATA0);
    $display("----------------------------------------------");
    $display("  BREADY_STALL_RESULT = %s",
             (b1_bvalid_cnt==3 && b1_bresp_cnt==3 &&
              b1_awready_cnt==3 && b1_wready_cnt==3) ? "PASS" : "FAIL");
    $display("  RREADY_STALL_RESULT = %s",
             (r1_rvalid_cnt==3 && r1_rresp_cnt==3 &&
              r1_rdata_cnt==3 && r1_arready_cnt==3) ? "PASS" : "FAIL");
    $display("  ADDR0_RDATA_RESULT  = %s",
             (r1_rdata_cap === WDATA0) ? "PASS" : "FAIL");
    $display("  ADDR4_RDATA_RESULT  = %s",
             (r2_rdata_cap === WDATA4) ? "PASS" : "FAIL");
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
