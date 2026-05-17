`timescale 1ns/1ps

// Testbench for axil_uart_adapter -- validates all 7 registers, sticky error
// bits, and one-cycle err_clr_o pulse.
//
// DUT: BAUD_DIV_DEFAULT=434
//   reg0 0x00 RO    COMPONENT_ID -- 0x55415254 ("UART")
//   reg1 0x04 RW    BAUD_DIV     -- prescaler (reset=434)
//   reg2 0x08 RW    CONFIG       -- [4:0] UART config (reset=0x0 = 8N1)
//   reg3 0x0C PULSE ERR_CLR      -- [0]=clear sticky errors + err_clr_o
//   reg4 0x10 RO    STATUS       -- [4:0] busy+error bits (errors sticky)
//   reg5 0x14 RO    TX_FIFO_CNT
//   reg6 0x18 RO    RX_FIFO_CNT
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) ../rtl/axil/axil_regfile.sv \
//        ../rtl/axil/axil_uart_adapter.sv tb_axil_uart_adapter.sv
//   vsim -c -do "run -all; quit" tb_axil_uart_adapter

module tb_axil_uart_adapter;
  import axi_pkg::*;

  logic        clk, rst_ni;
  logic        tx_busy, rx_busy;
  logic        overrun_err, frame_err, parity_err;
  logic [7:0]  tx_fifo_cnt, rx_fifo_cnt;
  logic [31:0] baud_div;
  logic [4:0]  config_out;
  logic        err_clr;

  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_if (
    .ACLK(clk), .ARESETn(rst_ni)
  );

  axil_uart_adapter #(
    .BAUD_DIV_DEFAULT (434)
  ) dut (
    .clk_i          (clk),
    .rst_ni         (rst_ni),
    .s_axil         (axil_if.slave),
    .tx_busy_i      (tx_busy),
    .rx_busy_i      (rx_busy),
    .overrun_err_i  (overrun_err),
    .frame_err_i    (frame_err),
    .parity_err_i   (parity_err),
    .tx_fifo_cnt_i  (tx_fifo_cnt),
    .rx_fifo_cnt_i  (rx_fifo_cnt),
    .baud_div_o     (baud_div),
    .config_o       (config_out),
    .err_clr_o      (err_clr)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails       = 0;
  int err_clr_cnt = 0;

  always @(posedge clk) if (err_clr) err_clr_cnt++;

  // -----------------------------------------------------------------------
  // AXI-Lite master tasks
  // -----------------------------------------------------------------------

  task automatic axi_write(
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0]  strb = 4'hF
  );
    @(negedge clk);
    axil_if.AWVALID = 1'b1; axil_if.AWADDR = addr; axil_if.AWPROT = '0;
    axil_if.WVALID  = 1'b1; axil_if.WDATA  = data; axil_if.WSTRB  = strb;
    axil_if.BREADY  = 1'b1;
    @(posedge clk);
    while (!(axil_if.AWREADY && axil_if.WREADY)) @(posedge clk);
    @(negedge clk);
    axil_if.AWVALID = 1'b0;
    axil_if.WVALID  = 1'b0;
    @(posedge clk);
    while (!axil_if.BVALID) @(posedge clk);
    @(negedge clk);
    axil_if.BREADY = 1'b0;
  endtask

  task automatic axi_read(
    input  logic [31:0] addr,
    output logic [31:0] data
  );
    @(negedge clk);
    axil_if.ARVALID = 1'b1; axil_if.ARADDR = addr; axil_if.ARPROT = '0;
    axil_if.RREADY  = 1'b1;
    @(posedge clk);
    while (!axil_if.ARREADY) @(posedge clk);
    @(negedge clk);
    axil_if.ARVALID = 1'b0;
    @(posedge clk);
    while (!axil_if.RVALID) @(posedge clk);
    data = axil_if.RDATA;
    @(negedge clk);
    axil_if.RREADY = 1'b0;
  endtask

  task automatic chk32(
    input logic [31:0] got,
    input logic [31:0] exp,
    input string       lbl
  );
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08X exp=0x%08X", lbl, got, exp);
      fails++;
    end else
      $display("PASS %s: 0x%08X", lbl, got);
  endtask

  task automatic chk_int(
    input int    got,
    input int    exp,
    input string lbl
  );
    if (got !== exp) begin
      $display("FAIL %s: got=%0d exp=%0d", lbl, got, exp);
      fails++;
    end else
      $display("PASS %s: %0d", lbl, got);
  endtask

  // -----------------------------------------------------------------------

  logic [31:0] rdata;

  initial begin
    axil_if.AWVALID = 0; axil_if.AWADDR = 0; axil_if.AWPROT = 0;
    axil_if.WVALID  = 0; axil_if.WDATA  = 0; axil_if.WSTRB  = 0;
    axil_if.BREADY  = 0;
    axil_if.ARVALID = 0; axil_if.ARADDR = 0; axil_if.ARPROT = 0;
    axil_if.RREADY  = 0;
    tx_busy    = 1'b0;
    rx_busy    = 1'b0;
    overrun_err = 1'b0;
    frame_err  = 1'b0;
    parity_err = 1'b0;
    tx_fifo_cnt = 8'h0;
    rx_fifo_cnt = 8'h0;

    rst_ni = 1'b0;
    repeat(4) @(posedge clk);
    rst_ni = 1'b1;
    repeat(2) @(posedge clk);

    // ---- T1: COMPONENT_ID = "UART" ----
    axi_read(32'h00, rdata);
    chk32(rdata, 32'h5541_5254, "T1 COMPONENT_ID");

    // ---- T2: BAUD_DIV default = 434 ----
    axi_read(32'h04, rdata);
    chk32(rdata, 32'd434, "T2 BAUD_DIV default");
    chk32(baud_div, 32'd434, "T2 baud_div_o default");

    // ---- T3: CONFIG default = 0x0 (dbits=00=8-bit, no parity, 1 stop = 8N1) ----
    axi_read(32'h08, rdata);
    chk32(rdata & 32'h1F, 32'h0, "T3 CONFIG default 8N1");
    chk32({27'h0, config_out}, 32'h0, "T3 config_o default");

    // ---- T4: STATUS -- tx_busy and rx_busy direct pass-through ----
    tx_busy = 1'b1;
    rx_busy = 1'b1;
    axi_read(32'h10, rdata);
    chk32(rdata & 32'h3, 32'h3, "T4 STATUS tx_busy[0]+rx_busy[1]");
    tx_busy = 1'b0;
    rx_busy = 1'b0;

    // ---- T5: STATUS -- sticky errors accumulate ----
    // Pulse each error for one cycle
    @(negedge clk);
    overrun_err = 1'b1;
    @(posedge clk); @(negedge clk);
    overrun_err = 1'b0;
    frame_err   = 1'b1;
    @(posedge clk); @(negedge clk);
    frame_err  = 1'b0;
    parity_err = 1'b1;
    @(posedge clk); @(negedge clk);
    parity_err = 1'b0;
    axi_read(32'h10, rdata);
    chk32(rdata & 32'h1C, 32'h1C, "T5 STATUS sticky errors[4:2] all set");

    // ---- T6: ERR_CLR -- clears sticky errors, fires err_clr_o once ----
    err_clr_cnt = 0;
    axi_write(32'h0C, 32'h0000_0001); // ERR_CLR[0] = 1
    chk_int(err_clr_cnt, 1, "T6 err_clr_o pulse count");
    axi_read(32'h10, rdata);
    chk32(rdata & 32'h1C, 32'h0, "T6 STATUS errors cleared");

    // ---- T7: BAUD_DIV write/read ----
    axi_write(32'h04, 32'd867); // 100 MHz / 115200
    axi_read(32'h04, rdata);
    chk32(rdata, 32'd867, "T7 BAUD_DIV write/read");
    chk32(baud_div, 32'd867, "T7 baud_div_o updated");

    // ---- T8: CONFIG write/read ----
    // 7-bit data(01), parity even(en=1,odd=0), 2-stop: CONFIG=5'b1_0_1_01 = 5'h15
    axi_write(32'h08, 32'h0000_0015);
    axi_read(32'h08, rdata);
    chk32(rdata & 32'h1F, 32'h15, "T8 CONFIG write/read");
    chk32({27'h0, config_out}, 32'h15, "T8 config_o updated");

    // ---- T9: TX_FIFO_CNT pass-through ----
    tx_fifo_cnt = 8'hAB;
    axi_read(32'h14, rdata);
    chk32(rdata & 32'hFF, 32'hAB, "T9 TX_FIFO_CNT");

    // ---- T10: RX_FIFO_CNT pass-through ----
    rx_fifo_cnt = 8'hCD;
    axi_read(32'h18, rdata);
    chk32(rdata & 32'hFF, 32'hCD, "T10 RX_FIFO_CNT");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
