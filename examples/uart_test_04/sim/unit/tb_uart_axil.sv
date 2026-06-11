// tb_uart_axil -- unit tests for uart_axil (AXI-Lite UART peripheral)
//
// Tests:
//   T01  Read static RO registers: ID, VERSION, BAUD_DIV_TX, BAUD_DIV_RX, CONF
//   T02  STATUS after reset: tx_ready=1, rx_valid=0, tx_fifo_empty=1, rx_fifo_empty=1
//   T03  TX: write 0x55 to TX_DATA, loopback tx->rx, wait for rx_valid in STATUS
//   T04  RX_DATA read pops FIFO: read 0x55, verify valid=1, verify FIFO empty after
//   T05  IRQ: enable rx_not_empty, send byte, verify irq_o goes high, clear IRQ_STATUS
//   T06  TX full write: fill TX FIFO, write one more, verify ERROR_STATUS[3] + IRQ_STATUS[5]
//   T07  WSTRB[0]=0: TX_DATA write with WSTRB=4'hE must not push byte to TX FIFO
//   T08  RX_DATA read when FIFO empty: valid=0, no side effect
//   T09  FIFO_LEVEL: write 3 bytes, verify tx_level=3, read them back, verify rx_level
//
// Sim parameters: SIM_CLK=1_600_000, SIM_BAUD=12_500
//   PRESCALE_TX    = round(1_600_000 / 12_500) = 128  (1x)
//   PRESCALE_RX_OS = floor(1_600_000 / (12_500 * 16)) = 8
//   BIT_CLKS = 128 clock cycles per bit
//   Frame: 10 bits (1 start + 8 data + 1 stop) = 1280 clocks
//
// Run: vsim -c -do "run -all; quit" tb_uart_axil

`timescale 1ns/1ps

module tb_uart_axil;

  // =========================================================================
  // Sim parameters
  // =========================================================================
  localparam int SIM_CLK_HZ = 1_600_000;
  localparam int SIM_BAUD   = 12_500;
  localparam int BIT_CLKS   = SIM_CLK_HZ / SIM_BAUD;      // 128
  localparam int FRAME_CLKS = BIT_CLKS * 10;               // 1280 (8N1 + start/stop)
  localparam int FIFO_DEPTH = 16;

  localparam int PRESCALE_TX    = (SIM_CLK_HZ + SIM_BAUD / 2) / SIM_BAUD;
  localparam int PRESCALE_RX_OS = SIM_CLK_HZ / (SIM_BAUD * 16);

  // =========================================================================
  // Clock + reset
  // =========================================================================
  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;

  always #5 clk_i = ~clk_i;

  // =========================================================================
  // AXI-Lite interface (master side driven by TB)
  // =========================================================================
  axi4lite_if #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) axil_bus(
    .ACLK   (clk_i),
    .ARESETn(rst_ni)
  );

  // Master-side drive signals (TB controls these)
  logic [7:0]  m_awaddr  = '0;
  logic        m_awvalid = 1'b0;
  logic [31:0] m_wdata   = '0;
  logic [3:0]  m_wstrb   = 4'hF;
  logic        m_wvalid  = 1'b0;
  logic        m_bready  = 1'b0;
  logic [7:0]  m_araddr  = '0;
  logic        m_arvalid = 1'b0;
  logic        m_rready  = 1'b0;

  assign axil_bus.AWADDR  = 32'(m_awaddr);
  assign axil_bus.AWPROT  = 3'h0;
  assign axil_bus.AWVALID = m_awvalid;
  assign axil_bus.WDATA   = m_wdata;
  assign axil_bus.WSTRB   = m_wstrb;
  assign axil_bus.WVALID  = m_wvalid;
  assign axil_bus.BREADY  = m_bready;
  assign axil_bus.ARADDR  = 32'(m_araddr);
  assign axil_bus.ARPROT  = 3'h0;
  assign axil_bus.ARVALID = m_arvalid;
  assign axil_bus.RREADY  = m_rready;

  // =========================================================================
  // DUT: uart_axil (loopback: tx_o -> rx_i)
  // =========================================================================
  wire loopback_w;
  wire irq_w;

  uart_axil #(
    .CLK_FREQ_HZ       (SIM_CLK_HZ),
    .BAUD_RATE         (SIM_BAUD),
    .RX_FIFO_DEPTH     (FIFO_DEPTH),
    .TX_FIFO_DEPTH     (FIFO_DEPTH)
  ) dut (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .s_axil (axil_bus),
    .rx_i   (loopback_w),
    .tx_o   (loopback_w),
    .irq_o  (irq_w)
  );

  // =========================================================================
  // AXI-Lite master tasks
  // =========================================================================
  logic [31:0] rd_data;

  task automatic axil_write_strb(input [7:0] addr, input [31:0] data, input [3:0] strb);
    @(posedge clk_i);
    m_awaddr  = addr;
    m_awvalid = 1'b1;
    m_wdata   = data;
    m_wstrb   = strb;
    m_wvalid  = 1'b1;
    m_bready  = 1'b1;
    while (!axil_bus.AWREADY) @(posedge clk_i);
    @(posedge clk_i);
    m_awvalid = 1'b0;
    while (!axil_bus.WREADY) @(posedge clk_i);
    m_wvalid  = 1'b0;
    while (!axil_bus.BVALID) @(posedge clk_i);
    @(posedge clk_i);
    m_bready  = 1'b0;
    @(posedge clk_i);
  endtask

  task automatic axil_write(input [7:0] addr, input [31:0] data);
    @(posedge clk_i);
    m_awaddr  = addr;
    m_awvalid = 1'b1;
    m_wdata   = data;
    m_wstrb   = 4'hF;
    m_wvalid  = 1'b1;
    m_bready  = 1'b1;
    // Wait for AW accepted
    while (!axil_bus.AWREADY) @(posedge clk_i);
    @(posedge clk_i);
    m_awvalid = 1'b0;
    // Wait for W accepted
    while (!axil_bus.WREADY) @(posedge clk_i);
    m_wvalid  = 1'b0;
    // Wait for B
    while (!axil_bus.BVALID) @(posedge clk_i);
    @(posedge clk_i);
    m_bready  = 1'b0;
    @(posedge clk_i);
  endtask

  task automatic axil_read(input [7:0] addr, output [31:0] data);
    @(posedge clk_i);
    m_araddr  = addr;
    m_arvalid = 1'b1;
    m_rready  = 1'b1;
    // Wait for AR accepted
    while (!axil_bus.ARREADY) @(posedge clk_i);
    @(posedge clk_i);
    m_arvalid = 1'b0;
    // Wait for R
    while (!axil_bus.RVALID) @(posedge clk_i);
    data      = axil_bus.RDATA;
    @(posedge clk_i);
    m_rready  = 1'b0;
    @(posedge clk_i);
  endtask

  // =========================================================================
  // Pass/fail helpers
  // =========================================================================
  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic check(input string label, input logic cond);
    if (cond) begin $display("# PASS %s", label); pass_cnt++; end
    else      begin $display("# FAIL %s", label); fail_cnt++; end
  endtask

  task automatic check_eq(input string label, input logic [31:0] got, exp);
    if (got === exp) begin
      $display("# PASS %s (0x%08X)", label, got);
      pass_cnt++;
    end else begin
      $display("# FAIL %s: got=0x%08X exp=0x%08X", label, got, exp);
      fail_cnt++;
    end
  endtask

  // =========================================================================
  // Test body
  // =========================================================================
  initial begin
    rst_ni = 1'b0;
    repeat(4) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat(4) @(posedge clk_i);

    // ------------------------------------------------------------------
    // T01: Read static RO registers
    // ------------------------------------------------------------------
    axil_read(8'h00, rd_data);
    check_eq("T01 ID",          rd_data, 32'h5541_5254);

    axil_read(8'h04, rd_data);
    check_eq("T01 VERSION",     rd_data, 32'h0001_0500);

    axil_read(8'h08, rd_data);
    check_eq("T01 BAUD_DIV_TX", rd_data, 32'(PRESCALE_TX));

    axil_read(8'h0C, rd_data);
    check_eq("T01 BAUD_DIV_RX", rd_data, 32'(PRESCALE_RX_OS));

    axil_read(8'h10, rd_data);
    check_eq("T01 CONF",        rd_data, 32'h0);       // default: 8N1, 1 stop

    // ------------------------------------------------------------------
    // T02: STATUS after reset
    // ------------------------------------------------------------------
    axil_read(8'h14, rd_data);
    check("T02 tx_ready set",      rd_data[7]);
    check("T02 rx_valid clear",   !rd_data[6]);
    check("T02 rx_fifo_empty set", rd_data[4]);
    check("T02 tx_fifo_empty set", rd_data[2]);
    check("T02 tx_busy clear",    !rd_data[0]);
    check("T02 rx_busy clear",    !rd_data[1]);

    axil_read(8'h18, rd_data);
    check_eq("T02 FIFO_LEVEL=0", rd_data, 32'h0);

    // ------------------------------------------------------------------
    // T03: TX -- write 0x55 to TX_DATA, wait for loopback into RX FIFO
    // ------------------------------------------------------------------
    axil_write(8'h20, 32'h55);   // push 0x55 to TX FIFO

    // Poll STATUS until rx_valid set (RX FIFO has the loopback byte)
    // Timeout: 4x FRAME_CLKS (generous margin for TX+RX pipeline)
    begin : blk_t03_poll
      automatic int timeout = 0;
      rd_data = '0;
      while (!rd_data[6]) begin
        axil_read(8'h14, rd_data);
        timeout++;
        if (timeout > 10) begin
          repeat(FRAME_CLKS / 4) @(posedge clk_i);
        end
        if (timeout > 50) begin
          $display("# TIMEOUT T03 waiting for rx_valid");
          disable blk_t03_poll;
        end
      end
    end
    check("T03 rx_valid after loopback", rd_data[6]);

    axil_read(8'h18, rd_data);
    check("T03 rx_level >= 1", rd_data[23:12] >= 12'd1);

    // ------------------------------------------------------------------
    // T04: RX_DATA read pops FIFO, returns correct byte
    // ------------------------------------------------------------------
    axil_read(8'h1C, rd_data);
    check("T04 rx_data valid bit",   rd_data[8]);
    check_eq("T04 rx_data = 0x55", {24'h0, rd_data[7:0]}, 32'h55);

    // After pop: rx_valid in STATUS should clear (only 1 byte in FIFO)
    repeat(2) @(posedge clk_i);
    axil_read(8'h14, rd_data);
    check("T04 rx_valid cleared after pop", !rd_data[6]);
    check("T04 rx_fifo_empty after pop",     rd_data[4]);

    // ------------------------------------------------------------------
    // T05: IRQ -- enable rx_not_empty, send byte, verify irq_o rises
    // ------------------------------------------------------------------
    // Clear any stale IRQ_STATUS from previous tests (T03 left [0]=1)
    axil_write(8'h28, 32'h1F);
    axil_write(8'h24, 32'h01);   // IRQ_ENABLE[0] = rx_not_empty

    axil_write(8'h20, 32'hAA);   // send 0xAA
    begin : blk_t05_poll
      automatic int timeout = 0;
      while (!irq_w) begin
        @(posedge clk_i);
        timeout++;
        if (timeout > 4 * FRAME_CLKS) begin
          $display("# TIMEOUT T05 waiting for irq_o");
          disable blk_t05_poll;
        end
      end
    end
    check("T05 irq_o asserted", irq_w);

    axil_read(8'h28, rd_data);
    check("T05 IRQ_STATUS[0] set", rd_data[0]);

    // Consume the byte to clear the level condition
    axil_read(8'h1C, rd_data);
    check_eq("T05 rx_data=0xAA", {24'h0, rd_data[7:0]}, 32'hAA);

    // Clear IRQ_STATUS[0] (level condition now gone -- FIFO empty)
    axil_write(8'h28, 32'h01);

    repeat(2) @(posedge clk_i);
    check("T05 irq_o deasserted after clear", !irq_w);

    // ------------------------------------------------------------------
    // T06: TX write-when-full -> ERROR_STATUS[3] + IRQ_STATUS[5]
    // ------------------------------------------------------------------
    // Enable IRQ for tx_write_when_full (bit 5)
    axil_write(8'h24, 32'h20);
    // Fill TX FIFO: write FIFO_DEPTH+1 bytes because TX core pops the
    // first byte immediately (while still idle), so we need one extra write
    begin : blk_t06_fill
      for (int i = 0; i < FIFO_DEPTH + 1; i++) begin
        axil_write(8'h20, 32'hA5);
      end
    end
    // Verify FIFO full in STATUS
    axil_read(8'h14, rd_data);
    check("T06 tx_fifo_full set", rd_data[3]);

    // Write one more -- byte must be dropped, ERROR_STATUS[3] must be set
    axil_write(8'h20, 32'hBB);

    // Allow one clock for error_next_w -> error_status_q
    repeat(2) @(posedge clk_i);

    axil_read(8'h2C, rd_data);
    check("T06 ERROR_STATUS[3] set", rd_data[3]);
    check("T06 ERROR_STATUS[2:0] clear", !rd_data[2] && !rd_data[1] && !rd_data[0]);

    // IRQ_STATUS[5] must be set (irq_cond_w[5] = error_status_q[3])
    axil_read(8'h28, rd_data);
    check("T06 IRQ_STATUS[5] set", rd_data[5]);

    // irq_o must be asserted (IRQ_ENABLE[5]=1)
    repeat(2) @(posedge clk_i);
    check("T06 irq_o asserted", irq_w);

    // Clear ERROR_STATUS[3] via W1C -- must also clear IRQ_STATUS[5]
    axil_write(8'h2C, 32'h08);
    repeat(2) @(posedge clk_i);

    axil_read(8'h2C, rd_data);
    check("T06 ERROR_STATUS[3] cleared", !rd_data[3]);

    axil_read(8'h28, rd_data);
    check("T06 IRQ_STATUS[5] cleared by ERROR W1C", !rd_data[5]);

    check("T06 irq_o deasserted", !irq_w);

    // ------------------------------------------------------------------
    // T07: WSTRB[0]=0 -- TX_DATA write must be silently ignored
    // ------------------------------------------------------------------
    // Drain ERROR_STATUS/IRQ_ENABLE state from T06
    axil_write(8'h24, 32'h00);  // IRQ_ENABLE = 0
    axil_write(8'h2C, 32'h0F);  // clear all ERROR bits

    // Wait for TX FIFO empty AND TX core idle (all T06 bytes still in flight)
    begin : blk_t07_drain_tx
      automatic int t = 0;
      do begin
        axil_read(8'h14, rd_data);
        t++;
      end while ((!rd_data[2] || rd_data[0]) && t < (FIFO_DEPTH + 2) * FRAME_CLKS);
    end
    // Allow last loopback byte to fully arrive at RX FIFO
    repeat(FRAME_CLKS) @(posedge clk_i);
    // Drain RX FIFO (loopback bytes from T06)
    begin : blk_t07_drain_rx
      automatic logic [31:0] dummy;
      axil_read(8'h14, rd_data);
      while (rd_data[6]) begin
        axil_read(8'h1C, dummy);
        axil_read(8'h14, rd_data);
      end
    end

    // Write TX_DATA with WSTRB=4'hE (bit 0 = 0) -> should NOT push byte
    axil_write_strb(8'h20, 32'hBB, 4'hE);
    repeat(2) @(posedge clk_i);

    // STATUS: tx_fifo_empty must still be 1 (no byte was pushed)
    axil_read(8'h14, rd_data);
    check("T07 tx_fifo_empty after WSTRB[0]=0 write", rd_data[2]);

    // ERROR_STATUS must not have tx_write_full set
    axil_read(8'h2C, rd_data);
    check("T07 ERROR_STATUS clear after WSTRB[0]=0", !rd_data[3]);

    // ------------------------------------------------------------------
    // T08: RX_DATA read when RX FIFO empty -> valid=0
    // ------------------------------------------------------------------
    // Verify FIFO is empty (T07 drained nothing from TX, no loopback yet)
    axil_read(8'h14, rd_data);
    check("T08 rx_fifo_empty before read", rd_data[4]);

    axil_read(8'h1C, rd_data);
    check("T08 RX_DATA valid=0 when empty", !rd_data[8]);

    // RX FIFO_LEVEL must still be 0 (no pop occurred)
    axil_read(8'h18, rd_data);
    check_eq("T08 FIFO_LEVEL rx=0 after empty read", {20'h0, rd_data[23:12]}, 32'h0);

    // ------------------------------------------------------------------
    // T09: FIFO_LEVEL -- write 3 bytes, verify tx_level=3, receive and verify rx_level
    // ------------------------------------------------------------------
    axil_write(8'h20, 32'hC1);
    axil_write(8'h20, 32'hC2);
    axil_write(8'h20, 32'hC3);

    // TX FIFO: at least 2 bytes queued (first was grabbed by TX core)
    axil_read(8'h18, rd_data);
    check("T09 tx_level >= 2", rd_data[11:0] >= 12'd2);

    // Wait for all 3 bytes to arrive via loopback
    begin : blk_t09_wait
      automatic int timeout = 0;
      do begin
        axil_read(8'h18, rd_data);
        timeout++;
      end while (rd_data[23:12] < 3 && timeout < 10 * FRAME_CLKS);
    end
    check("T09 rx_level=3 after loopback", rd_data[23:12] == 12'd3);

    // Read all 3 back
    axil_read(8'h1C, rd_data); check_eq("T09 rx[0]=0xC1", {24'h0, rd_data[7:0]}, 32'hC1);
    axil_read(8'h1C, rd_data); check_eq("T09 rx[1]=0xC2", {24'h0, rd_data[7:0]}, 32'hC2);
    axil_read(8'h1C, rd_data); check_eq("T09 rx[2]=0xC3", {24'h0, rd_data[7:0]}, 32'hC3);

    axil_read(8'h14, rd_data);
    check("T09 rx_fifo_empty after drain", rd_data[4]);

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(10) @(posedge clk_i);
    $display("# tb_uart_axil: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("# tb_uart_axil: all tests passed");
    else
      $display("# FAIL tb_uart_axil: %0d failures", fail_cnt);
    $finish;
  end

endmodule
