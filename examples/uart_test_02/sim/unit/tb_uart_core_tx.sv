// tb_uart_core_tx -- unit tests for uart_core_tx via uart wrapper
//
// Tests:
//   T01  TX idle = 1 after reset
//   T02  0x55  8N1 -- bit pattern check (alternating)
//   T03  0x00  8N1 -- all zeros
//   T04  0xFF  8N1 -- all ones
//   T05  back-to-back 0xAA then 0x55
//   T06  ready_o = 0 while TX busy; accepted when idle
//   T07  odd parity: 0xAA (4 ones) -> parity bit = 1 for odd total
//   T08  even parity: 0xAA (4 ones) -> parity=0, 0x07 (3 ones) -> parity=1
//   T09  7-bit data mode (DBITS=01): 0xFE -> lower 7 bits = 0x7E in frame
//   T10  2 stop bits (STOP2=1): two consecutive stop bits high
//
// Simulation parameters:
//   SIM_CLK_HZ=1_600_000, SIM_BAUD=100_000 -> PRESCALE=16, BIT_CLKS=16
//
// Run: vsim -c -do "run -all; quit" tb_uart_core_tx

`timescale 1ns/1ps

module tb_uart_core_tx;
  import uart_pkg::*;

  // =========================================================================
  // Sim parameters
  // =========================================================================
  localparam int SIM_CLK_HZ = 1_600_000;
  localparam int SIM_BAUD   = 100_000;
  // PRESCALE = (1_600_000 + 50_000) / 100_000 = 16
  localparam int BIT_CLKS   = (SIM_CLK_HZ + SIM_BAUD/2) / SIM_BAUD;

  // =========================================================================
  // Clock + reset
  // =========================================================================
  logic clk  = 1'b0;
  logic rstn = 1'b0;

  always #5 clk = ~clk; // 10 ns period

  // =========================================================================
  // DUT: 8N1
  // =========================================================================
  logic [7:0] tx_data;
  logic       tx_valid;
  wire        tx_ready;
  wire        txd;
  wire        tx_busy;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD)
  ) dut (
    .clk          (clk),
    .rstn         (rstn),
    .rx_i         (1'b1),
    .tx_o         (txd),
    .tx_data_i    (tx_data),
    .tx_valid_i   (tx_valid),
    .tx_ready_o   (tx_ready),
    .tx_done_o    (),
    .rx_data_o    (),
    .rx_valid_o   (),
    .rx_ready_i   (1'b1),
    .err_clear_i  (1'b0),
    .tx_busy_o    (tx_busy),
    .rx_busy_o    (),
    .overrun_err_o(),
    .frame_err_o  (),
    .parity_err_o ()
  );

  // =========================================================================
  // DUT: odd parity (for T07)
  // =========================================================================
  logic [7:0] tx_data_op;
  logic       tx_valid_op;
  wire        tx_ready_op;
  wire        txd_op;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .PARITY      (2'b01)
  ) dut_op (
    .clk          (clk),
    .rstn         (rstn),
    .rx_i         (1'b1),
    .tx_o         (txd_op),
    .tx_data_i    (tx_data_op),
    .tx_valid_i   (tx_valid_op),
    .tx_ready_o   (tx_ready_op),
    .tx_done_o    (),
    .rx_data_o    (),
    .rx_valid_o   (),
    .rx_ready_i   (1'b1),
    .err_clear_i  (1'b0),
    .tx_busy_o    (),
    .rx_busy_o    (),
    .overrun_err_o(),
    .frame_err_o  (),
    .parity_err_o ()
  );

  // =========================================================================
  // DUT: even parity (for T08)
  // =========================================================================
  logic [7:0] tx_data_ep;
  logic       tx_valid_ep;
  wire        tx_ready_ep;
  wire        txd_ep;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .PARITY      (2'b10)
  ) dut_ep (
    .clk          (clk),
    .rstn         (rstn),
    .rx_i         (1'b1),
    .tx_o         (txd_ep),
    .tx_data_i    (tx_data_ep),
    .tx_valid_i   (tx_valid_ep),
    .tx_ready_o   (tx_ready_ep),
    .tx_done_o    (),
    .rx_data_o    (),
    .rx_valid_o   (),
    .rx_ready_i   (1'b1),
    .err_clear_i  (1'b0),
    .tx_busy_o    (),
    .rx_busy_o    (),
    .overrun_err_o(),
    .frame_err_o  (),
    .parity_err_o ()
  );

  // =========================================================================
  // DUT: 7-bit data mode (for T09)
  // =========================================================================
  logic [7:0] tx_data_7b;
  logic       tx_valid_7b;
  wire        tx_ready_7b;
  wire        txd_7b;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .DBITS       (2'b01)
  ) dut_7b (
    .clk          (clk),
    .rstn         (rstn),
    .rx_i         (1'b1),
    .tx_o         (txd_7b),
    .tx_data_i    (tx_data_7b),
    .tx_valid_i   (tx_valid_7b),
    .tx_ready_o   (tx_ready_7b),
    .tx_done_o    (),
    .rx_data_o    (),
    .rx_valid_o   (),
    .rx_ready_i   (1'b1),
    .err_clear_i  (1'b0),
    .tx_busy_o    (),
    .rx_busy_o    (),
    .overrun_err_o(),
    .frame_err_o  (),
    .parity_err_o ()
  );

  // =========================================================================
  // DUT: 2 stop bits (for T10)
  // =========================================================================
  logic [7:0] tx_data_s2;
  logic       tx_valid_s2;
  wire        tx_ready_s2;
  wire        txd_s2;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .STOP2       (1'b1)
  ) dut_s2 (
    .clk          (clk),
    .rstn         (rstn),
    .rx_i         (1'b1),
    .tx_o         (txd_s2),
    .tx_data_i    (tx_data_s2),
    .tx_valid_i   (tx_valid_s2),
    .tx_ready_o   (tx_ready_s2),
    .tx_done_o    (),
    .rx_data_o    (),
    .rx_valid_o   (),
    .rx_ready_i   (1'b1),
    .err_clear_i  (1'b0),
    .tx_busy_o    (),
    .rx_busy_o    (),
    .overrun_err_o(),
    .frame_err_o  (),
    .parity_err_o ()
  );

  // =========================================================================
  // Check helper
  // =========================================================================
  int fails = 0;

  task automatic chk(input logic cond, input string lbl);
    if (!cond) begin $display("FAIL %s", lbl); fails++; end
    else             $display("PASS %s", lbl);
  endtask

  // =========================================================================
  // TX send: drive valid for one fire cycle
  // =========================================================================
  task automatic tx_send(input logic [7:0] data);
    while (!tx_ready) @(posedge clk);
    tx_data  = data;
    tx_valid = 1'b1;
    @(posedge clk); // fire
    tx_valid = 1'b0;
  endtask

  task automatic tx_send_op(input logic [7:0] data);
    while (!tx_ready_op) @(posedge clk);
    tx_data_op  = data;
    tx_valid_op = 1'b1;
    @(posedge clk);
    tx_valid_op = 1'b0;
  endtask

  task automatic tx_send_ep(input logic [7:0] data);
    while (!tx_ready_ep) @(posedge clk);
    tx_data_ep  = data;
    tx_valid_ep = 1'b1;
    @(posedge clk);
    tx_valid_ep = 1'b0;
  endtask

  task automatic tx_send_7b(input logic [7:0] data);
    while (!tx_ready_7b) @(posedge clk);
    tx_data_7b  = data;
    tx_valid_7b = 1'b1;
    @(posedge clk);
    tx_valid_7b = 1'b0;
  endtask

  task automatic tx_send_s2(input logic [7:0] data);
    while (!tx_ready_s2) @(posedge clk);
    tx_data_s2  = data;
    tx_valid_s2 = 1'b1;
    @(posedge clk);
    tx_valid_s2 = 1'b0;
  endtask

  // =========================================================================
  // TX monitor: capture one UART frame from txd_o
  //   returns 8 data bits; also captures parity bit if parity_en=1
  // =========================================================================
  task automatic tx_capture_8n1(output logic [7:0] data_out);
    @(negedge txd);
    // center of start bit + 0.5 bit = center of data bit 0
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      data_out[i] = txd;
      repeat(BIT_CLKS) @(posedge clk);
    end
    // now at center of stop bit
    chk(txd === 1'b1, "stop bit high");
  endtask

  // Capture 8N1 + 1 parity bit; returns data[7:0] and parity bit
  task automatic tx_capture_8o1(output logic [7:0] data_out, output logic par_bit);
    @(negedge txd_op);
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      data_out[i] = txd_op;
      repeat(BIT_CLKS) @(posedge clk);
    end
    par_bit = txd_op; // parity position
    repeat(BIT_CLKS) @(posedge clk);
    chk(txd_op === 1'b1, "stop bit high (parity)");
  endtask

  task automatic tx_capture_8e1(output logic [7:0] data_out, output logic par_bit);
    @(negedge txd_ep);
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      data_out[i] = txd_ep;
      repeat(BIT_CLKS) @(posedge clk);
    end
    par_bit = txd_ep;
    repeat(BIT_CLKS) @(posedge clk);
    chk(txd_ep === 1'b1, "stop bit high (even parity)");
  endtask

  // Capture 7-data-bit frame from txd_7b
  task automatic tx_capture_7n1(output logic [6:0] data_out);
    @(negedge txd_7b);
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);
    for (int i = 0; i < 7; i++) begin
      data_out[i] = txd_7b;
      repeat(BIT_CLKS) @(posedge clk);
    end
    chk(txd_7b === 1'b1, "T09 7-bit stop bit high");
  endtask

  // Capture 8-data-bit + 2 stop bits from txd_s2
  task automatic tx_capture_8n2(output logic [7:0] data_out);
    @(negedge txd_s2);
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      data_out[i] = txd_s2;
      repeat(BIT_CLKS) @(posedge clk);
    end
    chk(txd_s2 === 1'b1, "T10 stop1 high");
    repeat(BIT_CLKS) @(posedge clk);
    chk(txd_s2 === 1'b1, "T10 stop2 high");
  endtask

  // =========================================================================
  // Stimulus
  // =========================================================================
  logic [7:0] captured;
  logic [6:0] captured_7b;
  logic       par_captured;
  logic       expected_par;

  initial begin
    tx_data    = '0;
    tx_valid   = 1'b0;
    tx_data_op  = '0;
    tx_valid_op = 1'b0;
    tx_data_ep  = '0;
    tx_valid_ep = 1'b0;
    tx_data_7b  = '0;
    tx_valid_7b = 1'b0;
    tx_data_s2  = '0;
    tx_valid_s2 = 1'b0;

    // ---------- reset ----------
    repeat(4) @(posedge clk);
    rstn = 1'b1;
    repeat(2) @(posedge clk);

    // ------------------------------------------------------------------
    // T01: idle = 1 after reset
    // ------------------------------------------------------------------
    chk(txd === 1'b1, "T01 TX idle=1 after reset");
    chk(tx_ready === 1'b1, "T01 ready=1 after reset");

    // ------------------------------------------------------------------
    // T02: 0x55 (01010101b) LSB-first = 1,0,1,0,1,0,1,0
    // ------------------------------------------------------------------
    tx_send(8'h55);
    tx_capture_8n1(captured);
    chk(captured === 8'h55, "T02 0x55 loopback");

    // ------------------------------------------------------------------
    // T03: 0x00
    // ------------------------------------------------------------------
    tx_send(8'h00);
    tx_capture_8n1(captured);
    chk(captured === 8'h00, "T03 0x00 loopback");

    // ------------------------------------------------------------------
    // T04: 0xFF
    // ------------------------------------------------------------------
    tx_send(8'hFF);
    tx_capture_8n1(captured);
    chk(captured === 8'hFF, "T04 0xFF loopback");

    // ------------------------------------------------------------------
    // T05: back-to-back 0xAA then 0x55
    //   fire byte 2 while byte 1 is still being transmitted
    // ------------------------------------------------------------------
    // Fire byte 1 (TX goes busy after fire)
    while (!tx_ready) @(posedge clk);
    tx_data  = 8'hAA;
    tx_valid = 1'b1;
    @(posedge clk); // fire byte 1
    tx_valid = 1'b0;
    // TX now busy; queue byte 2.
    // One extra posedge before checking tx_ready: the fork starts in the
    // same active region as byte 1's fire, where state_q is still UART_IDLE
    // (NBA hasn't applied yet).  Without the extra clock, tx_ready reads 1
    // and fires byte 2 before the TX core registers byte 1's start.
    fork
      begin
        @(posedge clk);   // let byte 1 fire NBA apply (state -> UART_START)
        tx_send(8'h55);
      end
      begin
        tx_capture_8n1(captured);
        chk(captured === 8'hAA, "T05 back-to-back byte1 = 0xAA");
        tx_capture_8n1(captured);
        chk(captured === 8'h55, "T05 back-to-back byte2 = 0x55");
      end
    join

    // ------------------------------------------------------------------
    // T06: ready_o = 0 while busy; tx_valid ignored when not ready
    //   Fork/join: monitor must start before fire so @(negedge txd) is
    //   evaluated while txd is still 1 (start-bit negedge arrives in the
    //   NBA region of the fire clock, which is already past if we wait).
    // ------------------------------------------------------------------
    while (!tx_ready) @(posedge clk);
    tx_data  = 8'hA5;
    tx_valid = 1'b1;
    fork
      begin  // sender: fire, then verify ready=0
        @(posedge clk);              // fire
        @(posedge clk);              // TX now busy
        chk(tx_ready === 1'b0, "T06 ready=0 during TX");
        tx_valid = 1'b0;
      end
      begin  // monitor: @(negedge txd) catches start-bit negedge in fire's NBA
        tx_capture_8n1(captured);
        chk(captured === 8'hA5, "T06 byte received correctly after busy");
      end
    join

    // ------------------------------------------------------------------
    // T07: odd parity -- 0xAA has 4 ones, parity bit = 1 for odd count=5
    // ------------------------------------------------------------------
    // 0xAA = 10101010 -> number of 1s = 4 -> odd parity bit = 1 (makes total 5, odd)
    tx_send_op(8'hAA);
    tx_capture_8o1(captured, par_captured);
    chk(captured === 8'hAA, "T07 odd-parity data = 0xAA");
    // calc_parity for ODD: result such that data+par has odd total 1s
    // 0xAA has 4 ones -> parity = 1 (total 5 = odd) -> matches UART_PARITY state
    chk(par_captured === 1'b1, "T07 odd parity bit for 0xAA = 1");

    // 0x55 = 01010101 -> 4 ones -> same result
    tx_send_op(8'h55);
    tx_capture_8o1(captured, par_captured);
    chk(captured === 8'h55, "T07 odd-parity data = 0x55");
    chk(par_captured === 1'b1, "T07 odd parity bit for 0x55 = 1");

    // 0xFF = 11111111 -> 8 ones -> parity = 1 (total 9 = odd)
    tx_send_op(8'hFF);
    tx_capture_8o1(captured, par_captured);
    chk(captured === 8'hFF, "T07 odd-parity data = 0xFF");
    chk(par_captured === 1'b1, "T07 odd parity bit for 0xFF = 1");

    // 0x81 = 10000001 -> 2 ones -> parity = 1 (total 3 = odd)
    tx_send_op(8'h81);
    tx_capture_8o1(captured, par_captured);
    chk(captured === 8'h81, "T07 odd-parity data = 0x81");
    chk(par_captured === 1'b1, "T07 odd parity bit for 0x81 = 1");

    // 0x07 = 00000111 -> 3 ones -> parity = 0 (total 3 = odd, already odd)
    tx_send_op(8'h07);
    tx_capture_8o1(captured, par_captured);
    chk(captured === 8'h07, "T07 odd-parity data = 0x07");
    chk(par_captured === 1'b0, "T07 odd parity bit for 0x07 = 0");

    // ------------------------------------------------------------------
    // T08: even parity
    // ------------------------------------------------------------------
    // 0xAA = 10101010 -> 4 ones -> even parity bit = 0 (total 4 = even)
    tx_send_ep(8'hAA);
    tx_capture_8e1(captured, par_captured);
    chk(captured === 8'hAA, "T08 even-parity data = 0xAA");
    chk(par_captured === 1'b0, "T08 even parity bit for 0xAA = 0");

    // 0x07 = 00000111 -> 3 ones -> even parity bit = 1 (total 4 = even)
    tx_send_ep(8'h07);
    tx_capture_8e1(captured, par_captured);
    chk(captured === 8'h07, "T08 even-parity data = 0x07");
    chk(par_captured === 1'b1, "T08 even parity bit for 0x07 = 1");

    // ------------------------------------------------------------------
    // T09: 7-bit data mode
    //   0xFE = 8'b1111_1110; lower 7 bits = 7'b111_1110 = 7'h7E
    // ------------------------------------------------------------------
    tx_send_7b(8'hFE);
    tx_capture_7n1(captured_7b);
    chk(captured_7b === 7'h7E, "T09 7-bit data = 7'h7E (0xFE & 0x7F)");

    // 0x55 = 0101_0101; lower 7 bits = 7'b101_0101 = 7'h55
    tx_send_7b(8'h55);
    tx_capture_7n1(captured_7b);
    chk(captured_7b === 7'h55, "T09 7-bit data = 7'h55");

    // ------------------------------------------------------------------
    // T10: 2 stop bits
    //   Frame: start + 8 data bits + stop1 + stop2
    // ------------------------------------------------------------------
    tx_send_s2(8'hA5);
    tx_capture_8n2(captured);
    chk(captured === 8'hA5, "T10 2-stop data = 0xA5");

    tx_send_s2(8'h3C);
    tx_capture_8n2(captured);
    chk(captured === 8'h3C, "T10 2-stop data = 0x3C");

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    if (fails == 0)
      $display("PASS tb_uart_core_tx: all tests passed");
    else
      $display("FAIL tb_uart_core_tx: %0d test(s) failed", fails);

    $finish;
  end

  // Timeout watchdog
  initial begin
    repeat(200_000) @(posedge clk);
    $display("FAIL tb_uart_core_tx: TIMEOUT");
    $finish;
  end

endmodule : tb_uart_core_tx
