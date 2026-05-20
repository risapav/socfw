`timescale 1ns/1ps

// Standalone testbench for axis_uart_rx (uart_baud_gen + uart_core_rx).
//
// Sends the XFCP WRITE packet byte-by-byte over the rxd_i pin and verifies
// that every received byte matches the transmitted byte.
//
// Packet under test: FE 11 00 04 FF 02 00 04 00 00 00 3F  (12 bytes)
//
// BAUD_DIV=16 clocks/bit. One byte = 10 bits * 16 = 160 clocks.
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) $(UART_COMMON) \
//        $(RTL_AXIS)/axis_uart_rx.sv tb_uart_core_rx.sv
//   vsim -c -do "run -all; quit" tb_uart_core_rx

module tb_uart_core_rx;

  localparam int BAUD_DIV    = 16;
  localparam int NUM_BYTES   = 12;

  // Expected byte sequence: XFCP WRITE packet
  localparam logic [7:0] PKT [0:NUM_BYTES-1] = '{
    8'hFE, 8'h11, 8'h00, 8'h04,
    8'hFF, 8'h02, 8'h00, 8'h04,
    8'h00, 8'h00, 8'h00, 8'h3F
  };

  logic clk, rst_ni;
  logic rxd;

  import axi_pkg::*;
  import uart_pkg::*;

  axi4s_if #(.DATA_WIDTH(8)) rx_axis(.TCLK(clk), .TRESETn(rst_ni));

  uart_conf_t cfg;
  uart_status_t status;

  // 8N1, no parity, 1 stop bit
  initial begin
    cfg        = '0;
    cfg.dbits  = 2'b00; // 8-bit
    cfg.parity = 2'b00;
    cfg.stop2  = 1'b0;
  end

  assign rx_axis.TREADY = 1'b1; // always accept

  axis_uart_rx #(
    .DATA_WIDTH(8),
    .AXIS_TLAST(1'b0)
  ) dut (
    .m_axis     (rx_axis),
    .rxd_i      (rxd),
    .prescale_i (16'(BAUD_DIV)),
    .cfg_i      (cfg),
    .status_o   (status),
    .err_clear_i(1'b0)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ---- Capture buffer ---------------------------------------------------
  logic [7:0] cap_buf [0:31];
  int unsigned cap_wptr;
  int unsigned cap_rptr;

  initial begin : axis_monitor
    cap_wptr = 0;
    cap_rptr = 0;
    @(posedge rst_ni);
    repeat(4) @(posedge clk);
    forever begin
      @(posedge clk);
      if (rx_axis.TVALID && rx_axis.TREADY) begin
        cap_buf[cap_wptr & 31] = rx_axis.TDATA;
        cap_wptr++;
      end
    end
  end

  // ---- uart_send --------------------------------------------------------
  task automatic uart_send(input logic [7:0] b);
    $display("[%0t] TB SEND 0x%02h", $time, b);
    @(negedge clk); rxd = 1'b0;         // start bit
    repeat(BAUD_DIV) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      @(negedge clk); rxd = b[i];
      repeat(BAUD_DIV) @(posedge clk);
    end
    @(negedge clk); rxd = 1'b1;         // stop bit
    repeat(BAUD_DIV) @(posedge clk);
  endtask

  // Wait for next captured byte (with timeout)
  task automatic recv_byte(output logic [7:0] b);
    int unsigned cnt;
    cnt = 0;
    while (cap_rptr == cap_wptr) begin
      @(posedge clk);
      cnt++;
      if (cnt > 200_000)
        $fatal(1, "recv_byte timeout — DUT did not produce output");
    end
    b = cap_buf[cap_rptr & 31];
    cap_rptr++;
  endtask

  task automatic chk8(
    input logic [7:0] got,
    input logic [7:0] exp,
    input int         idx
  );
    if (got !== exp)
      $display("FAIL byte[%0d]: got=0x%02h exp=0x%02h", idx, got, exp);
    else
      $display("PASS byte[%0d]: 0x%02h", idx, got);
    if (got !== exp) fails++;
  endtask

  // ---- Main stimulus ----------------------------------------------------
  logic [7:0] rb;

  initial begin
    rxd    = 1'b1;
    rst_ni = 1'b0;
    repeat(8) @(posedge clk);
    rst_ni = 1'b1;
    repeat(4) @(posedge clk);

    // Send all bytes back-to-back (no gap between bytes, same as real XFCP sender)
    for (int i = 0; i < NUM_BYTES; i++)
      uart_send(PKT[i]);

    // Now collect and verify all received bytes
    for (int i = 0; i < NUM_BYTES; i++) begin
      recv_byte(rb);
      chk8(rb, PKT[i], i);
    end

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
