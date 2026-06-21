// tb_native_word_port_unit.sv -- native_word_port unit test.
// No PHY, no SDRAM model. Fake phy_cmd_ready=1, inject fake phy_rvalid.
// Verifies:
//   A: 32-bit write generates correct low/high PHY sub-commands in order.
//   B: 32-bit read injects two fake halfwords, verifies rsp_rdata assembly.
`timescale 1ns/1ps

module tb_native_word_port_unit;

  localparam integer CLK_HALF = 4; // 125 MHz

  logic clk  = 0;
  logic rstn = 0;
  always #CLK_HALF clk = ~clk;

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
  // Flat PHY interface (fake model side)
  // -----------------------------------------------------------------------
  logic        phy_cmd_valid;
  logic        phy_cmd_ready = 1; // always ready
  logic        phy_cmd_write;
  logic [23:0] phy_cmd_addr;
  logic [15:0] phy_wdata;
  logic        phy_wdata_oe;

  logic        phy_rvalid = 0;
  logic [15:0] phy_rdata  = '0;

  // -----------------------------------------------------------------------
  // DUT
  // -----------------------------------------------------------------------
  native_word_port u_dut (
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
  // Cycle counter
  // -----------------------------------------------------------------------
  integer cyc = 0;
  always @(posedge clk) cyc++;

  // -----------------------------------------------------------------------
  // PHY command capture (for write verification)
  // -----------------------------------------------------------------------
  integer wr_cmd_cnt = 0;
  logic [23:0] wr_cmd_addr [2];
  logic [15:0] wr_cmd_data [2];

  integer rd_cmd_cnt = 0;
  logic [23:0] rd_cmd_addr [2];

  always @(posedge clk) begin
    if (phy_cmd_valid && phy_cmd_ready) begin
      $display("[cyc=%0d] PHY CMD: %s addr=0x%06h wdata=0x%04h oe=%b",
               cyc,
               phy_cmd_write ? "WRITE" : "READ ",
               phy_cmd_addr, phy_wdata, phy_wdata_oe);
      if (phy_cmd_write && wr_cmd_cnt < 2) begin
        wr_cmd_addr[wr_cmd_cnt] = phy_cmd_addr;
        wr_cmd_data[wr_cmd_cnt] = phy_wdata;
        wr_cmd_cnt++;
      end
      if (!phy_cmd_write && rd_cmd_cnt < 2) begin
        rd_cmd_addr[rd_cmd_cnt] = phy_cmd_addr;
        rd_cmd_cnt++;
      end
    end
  end

  // -----------------------------------------------------------------------
  // Constants
  // -----------------------------------------------------------------------
  localparam logic [31:0] WDATA   = 32'h1234_A5C3;
  localparam logic [23:0] ADDR    = 24'h000000;
  localparam integer      TIMEOUT = 30;

  integer errors = 0;

  // -----------------------------------------------------------------------
  // Test sequence
  // -----------------------------------------------------------------------
  initial begin
    $display("=== tb_native_word_port_unit ===");
    $display("=== WDATA=0x%08h ADDR=0x%06h ===", WDATA, ADDR);

    rstn = 0;
    repeat(4) @(posedge clk); #1;
    rstn = 1;
    @(posedge clk); #1;

    // -------------------------------------------------------------------
    // Test A: native 32-bit write
    // -------------------------------------------------------------------
    $display("[cyc=%0d] --- Test A: native write 0x%08h -> addr 0x%06h ---",
             cyc, WDATA, ADDR);

    req_valid = 1;
    req_write = 1;
    req_addr  = ADDR;
    req_wdata = WDATA;
    @(posedge clk); #1; // DUT latches: IDLE -> WR_LOW
    req_valid = 0;

    // Wait for req_ready (write completes after WR_LOW/HOLD/WR_HIGH/HOLD = 4 cycles)
    begin : wait_wr
      integer i;
      for (i = 0; i < TIMEOUT && !req_ready; i++) @(posedge clk); #1;
      if (!req_ready) begin
        $display("[FAIL] Write never completed (req_ready stayed 0)");
        errors++;
      end else begin
        $display("[cyc=%0d] Write complete (req_ready=1)", cyc);
      end
    end

    // Verify write sub-commands
    if (wr_cmd_cnt != 2) begin
      $display("[FAIL] Expected 2 write PHY commands, got %0d", wr_cmd_cnt);
      errors++;
    end else begin
      // Low halfword: addr=ADDR, data=WDATA[15:0]=0xA5C3
      if (wr_cmd_addr[0] !== ADDR || wr_cmd_data[0] !== WDATA[15:0]) begin
        $display("[FAIL] Write[0]: expected addr=0x%06h data=0x%04h, got addr=0x%06h data=0x%04h",
                 ADDR, WDATA[15:0], wr_cmd_addr[0], wr_cmd_data[0]);
        errors++;
      end else begin
        $display("[PASS] Write[0] addr=0x%06h data=0x%04h (low halfword) MATCH",
                 wr_cmd_addr[0], wr_cmd_data[0]);
      end
      // High halfword: addr=ADDR+1, data=WDATA[31:16]=0x1234
      if (wr_cmd_addr[1] !== ADDR+24'd1 || wr_cmd_data[1] !== WDATA[31:16]) begin
        $display("[FAIL] Write[1]: expected addr=0x%06h data=0x%04h, got addr=0x%06h data=0x%04h",
                 ADDR+24'd1, WDATA[31:16], wr_cmd_addr[1], wr_cmd_data[1]);
        errors++;
      end else begin
        $display("[PASS] Write[1] addr=0x%06h data=0x%04h (high halfword) MATCH",
                 wr_cmd_addr[1], wr_cmd_data[1]);
      end
    end

    repeat(2) @(posedge clk); #1;

    // -------------------------------------------------------------------
    // Test B: native 32-bit read + fake PHY response injection
    // -------------------------------------------------------------------
    $display("[cyc=%0d] --- Test B: native read addr 0x%06h ---", cyc, ADDR);

    req_valid = 1;
    req_write = 0;
    req_addr  = ADDR;
    @(posedge clk); #1; // DUT latches: IDLE -> RD_LOW
    req_valid = 0;

    // Wait for both RD_LOW and RD_HIGH commands to be issued:
    // Cycle 1: RD_LOW -> RD_HIGH (phy_cmd_ready=1)
    // Cycle 2: RD_HIGH -> RD_WAIT (phy_cmd_ready=1)
    @(posedge clk); #1; // DUT: RD_LOW
    @(posedge clk); #1; // DUT: RD_HIGH
    // DUT now in RD_WAIT

    // Inject low halfword
    phy_rvalid = 1; phy_rdata = WDATA[15:0];
    $display("[cyc=%0d] Inject phy_rvalid low=0x%04h", cyc, WDATA[15:0]);
    @(posedge clk); #1; // assembler stores low_word; rsp_cnt_r=1

    // Inject high halfword
    phy_rdata = WDATA[31:16];
    $display("[cyc=%0d] Inject phy_rvalid high=0x%04h", cyc, WDATA[31:16]);
    @(posedge clk); #1; // assembler fires word_valid=1 (NBA); state->IDLE

    // rsp_valid is a 1-cycle pulse from assembler -- check right now
    phy_rvalid = 0; phy_rdata = '0;

    $display("[cyc=%0d] rsp_valid=%b rsp_rdata=0x%08h expected=0x%08h %s",
             cyc, rsp_valid, rsp_rdata, WDATA,
             (rsp_valid === 1'b1 && rsp_rdata === WDATA) ? "MATCH" : "MISMATCH");

    if (rsp_valid !== 1'b1) begin
      $display("[FAIL] rsp_valid not asserted");
      errors++;
    end
    if (rsp_rdata !== WDATA) begin
      $display("[FAIL] rsp_rdata: expected=0x%08h got=0x%08h", WDATA, rsp_rdata);
      errors++;
    end

    // Verify read sub-commands
    if (rd_cmd_cnt != 2) begin
      $display("[FAIL] Expected 2 read PHY commands, got %0d", rd_cmd_cnt);
      errors++;
    end else begin
      if (rd_cmd_addr[0] !== ADDR) begin
        $display("[FAIL] Read[0]: expected addr=0x%06h got=0x%06h", ADDR, rd_cmd_addr[0]);
        errors++;
      end else $display("[PASS] Read[0] addr=0x%06h MATCH", rd_cmd_addr[0]);
      if (rd_cmd_addr[1] !== ADDR+24'd1) begin
        $display("[FAIL] Read[1]: expected addr=0x%06h got=0x%06h", ADDR+24'd1, rd_cmd_addr[1]);
        errors++;
      end else $display("[PASS] Read[1] addr=0x%06h MATCH", rd_cmd_addr[1]);
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
