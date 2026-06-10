// tb_uart_core_rx -- unit tests for uart_core_rx via uart wrapper
//
// Tests:
//   T01  idle -- valid_o stays 0 with no data
//   T02  0x55  8N1
//   T03  0x00  8N1
//   T04  0xFF  8N1
//   T05  rx_ready_i = 0 -- valid/data held until ready
//   T06  overrun: second byte before first consumed
//   T07  frame error: stop bit low
//   T08  parity error: wrong parity bit (odd parity DUT)
//   T09  back-to-back: two bytes with no inter-frame gap
//   T10  pending_start_q: start edge arrives before stop end_tick
//   T11  even parity: wrong parity -> error; correct parity -> data OK
//   T12  false start: short glitch rejected, no byte, no frame error
//   T13  7-bit data mode (DBITS=01): 7 bits received, MSB=0 padded
//   T14  2 stop bits (STOP2=1): frame received correctly with 2 stop bits
//
// Simulation parameters:
//   SIM_CLK_HZ=1_600_000, SIM_BAUD=100_000 -> PRESCALE=16, BIT_CLKS=16
//
// Run: vsim -c -do "run -all; quit" tb_uart_core_rx

`timescale 1ns/1ps

module tb_uart_core_rx;
  import uart_pkg::*;

  // =========================================================================
  // Sim parameters
  // =========================================================================
  localparam int SIM_CLK_HZ = 1_600_000;
  localparam int SIM_BAUD   = 100_000;
  localparam int BIT_CLKS   = (SIM_CLK_HZ + SIM_BAUD/2) / SIM_BAUD; // 16

  // =========================================================================
  // Clock + reset
  // =========================================================================
  logic clk  = 1'b0;
  logic rstn = 1'b0;

  always #5 clk = ~clk;

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic       rxd_drv    = 1'b1; // BFM drives this
  logic       rx_ready   = 1'b1; // consumer backpressure
  logic       err_clear  = 1'b0;

  wire [7:0]  rx_data;
  wire        rx_valid;
  wire        overrun_err;
  wire        frame_err;
  wire        parity_err;

  // =========================================================================
  // DUT: 8N1
  // =========================================================================
  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD)
  ) dut (
    .clk           (clk),
    .rstn          (rstn),
    .rx_i          (rxd_drv),
    .tx_o          (),
    .tx_data_i     ('0),
    .tx_valid_i    (1'b0),
    .tx_ready_o    (),
    .tx_done_o     (),
    .rx_data_o     (rx_data),
    .rx_valid_o    (rx_valid),
    .rx_ready_i    (rx_ready),
    .err_clear_i   (err_clear),
    .tx_busy_o     (),
    .rx_busy_o     (),
    .overrun_err_o (overrun_err),
    .frame_err_o   (frame_err),
    .parity_err_o  (parity_err)
  );

  // =========================================================================
  // DUT: odd parity (for T08)
  // =========================================================================
  logic       rxd_drv_op = 1'b1;
  logic       rx_ready_op = 1'b1;

  wire [7:0]  rx_data_op;
  wire        rx_valid_op;
  wire        parity_err_op;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .PARITY      (2'b01)
  ) dut_op (
    .clk           (clk),
    .rstn          (rstn),
    .rx_i          (rxd_drv_op),
    .tx_o          (),
    .tx_data_i     ('0),
    .tx_valid_i    (1'b0),
    .tx_ready_o    (),
    .tx_done_o     (),
    .rx_data_o     (rx_data_op),
    .rx_valid_o    (rx_valid_op),
    .rx_ready_i    (rx_ready_op),
    .err_clear_i   (1'b0),
    .tx_busy_o     (),
    .rx_busy_o     (),
    .overrun_err_o (),
    .frame_err_o   (),
    .parity_err_o  (parity_err_op)
  );

  // =========================================================================
  // DUT: even parity (for T11)
  // =========================================================================
  logic       rxd_drv_ep = 1'b1;
  logic       rx_ready_ep = 1'b1;

  wire [7:0]  rx_data_ep;
  wire        rx_valid_ep;
  wire        parity_err_ep;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .PARITY      (2'b10)
  ) dut_ep (
    .clk           (clk),
    .rstn          (rstn),
    .rx_i          (rxd_drv_ep),
    .tx_o          (),
    .tx_data_i     ('0),
    .tx_valid_i    (1'b0),
    .tx_ready_o    (),
    .tx_done_o     (),
    .rx_data_o     (rx_data_ep),
    .rx_valid_o    (rx_valid_ep),
    .rx_ready_i    (rx_ready_ep),
    .err_clear_i   (1'b0),
    .tx_busy_o     (),
    .rx_busy_o     (),
    .overrun_err_o (),
    .frame_err_o   (),
    .parity_err_o  (parity_err_ep)
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
  // BFM: send one UART byte on rxd_drv (8N1)
  //   frame_err_force: drive stop bit low to trigger frame error
  // =========================================================================
  task automatic rx_send(input logic [7:0] data,
                         input bit frame_err_force = 0);
    rxd_drv = 1'b0;                                        // start bit
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = frame_err_force ? 1'b0 : 1'b1;              // stop bit
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv = 1'b1;                                        // idle
    repeat(2) @(posedge clk);                              // settle
  endtask

  // Send byte without trailing idle gap (for back-to-back tests)
  task automatic rx_send_no_gap(input logic [7:0] data);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = 1'b1;                                        // stop bit only
    repeat(BIT_CLKS) @(posedge clk);
    // no trailing idle -- caller decides next action
  endtask

  // Send byte with truncated stop bit to force early start edge (pending_start_q path)
  // stop_clks < BIT_CLKS causes the next start edge to arrive before end_tick fires
  task automatic rx_send_fast_stop(input logic [7:0] data,
                                   input int stop_clks);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = 1'b1;                                        // stop bit (high)
    repeat(stop_clks) @(posedge clk);
    // stop bit truncated -- next start bit follows immediately
  endtask

  // Send on the odd-parity DUT
  task automatic rx_send_op(input logic [7:0] data, input logic parity_bit);
    rxd_drv_op = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv_op = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv_op = parity_bit;                               // parity
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv_op = 1'b1;                                     // stop bit
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv_op = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  // Wait for rx_valid to assert (up to max_clks); fail on timeout
  task automatic wait_valid(input int max_clks = 400);
    int cnt = 0;
    while (!rx_valid && cnt < max_clks) begin
      @(posedge clk);
      cnt++;
    end
    if (cnt >= max_clks)
      $display("FAIL wait_valid: TIMEOUT after %0d clocks", max_clks);
  endtask

  task automatic wait_valid_op(input int max_clks = 400);
    int cnt = 0;
    while (!rx_valid_op && cnt < max_clks) begin
      @(posedge clk);
      cnt++;
    end
  endtask

  task automatic rx_send_ep(input logic [7:0] data, input logic parity_bit);
    rxd_drv_ep = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv_ep = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv_ep = parity_bit;
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv_ep = 1'b1;                                     // stop bit
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv_ep = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  task automatic wait_valid_ep(input int max_clks = 400);
    int cnt = 0;
    while (!rx_valid_ep && cnt < max_clks) begin
      @(posedge clk);
      cnt++;
    end
  endtask

  // =========================================================================
  // DUT: 7-bit data mode (for T13)
  // =========================================================================
  logic       rxd_drv_7b = 1'b1;

  wire [7:0]  rx_data_7b;
  wire        rx_valid_7b;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .DBITS       (2'b01)
  ) dut_7b (
    .clk           (clk),
    .rstn          (rstn),
    .rx_i          (rxd_drv_7b),
    .tx_o          (),
    .tx_data_i     ('0),
    .tx_valid_i    (1'b0),
    .tx_ready_o    (),
    .tx_done_o     (),
    .rx_data_o     (rx_data_7b),
    .rx_valid_o    (rx_valid_7b),
    .rx_ready_i    (1'b1),
    .err_clear_i   (1'b0),
    .tx_busy_o     (),
    .rx_busy_o     (),
    .overrun_err_o (),
    .frame_err_o   (),
    .parity_err_o  ()
  );

  // =========================================================================
  // DUT: 2 stop bits (for T14)
  // =========================================================================
  logic       rxd_drv_s2 = 1'b1;

  wire [7:0]  rx_data_s2;
  wire        rx_valid_s2;

  uart #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .STOP2       (1'b1)
  ) dut_s2 (
    .clk           (clk),
    .rstn          (rstn),
    .rx_i          (rxd_drv_s2),
    .tx_o          (),
    .tx_data_i     ('0),
    .tx_valid_i    (1'b0),
    .tx_ready_o    (),
    .tx_done_o     (),
    .rx_data_o     (rx_data_s2),
    .rx_valid_o    (rx_valid_s2),
    .rx_ready_i    (1'b1),
    .err_clear_i   (1'b0),
    .tx_busy_o     (),
    .rx_busy_o     (),
    .overrun_err_o (),
    .frame_err_o   (),
    .parity_err_o  ()
  );

  // Send 7-data-bit frame to dut_7b
  task automatic rx_send_7n1(input logic [6:0] data_7b);
    rxd_drv_7b = 1'b0;                                     // start bit
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 7; i++) begin
      rxd_drv_7b = data_7b[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv_7b = 1'b1;                                     // stop bit
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv_7b = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  // Send 8-data-bit + 2 stop-bit frame to dut_s2
  task automatic rx_send_8n2(input logic [7:0] data);
    rxd_drv_s2 = 1'b0;                                     // start bit
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv_s2 = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv_s2 = 1'b1;                                     // stop1
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv_s2 = 1'b1;                                     // stop2
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv_s2 = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  task automatic wait_valid_7b(input int max_clks = 400);
    int cnt = 0;
    while (!rx_valid_7b && cnt < max_clks) begin
      @(posedge clk);
      cnt++;
    end
  endtask

  task automatic wait_valid_s2(input int max_clks = 500);
    int cnt = 0;
    while (!rx_valid_s2 && cnt < max_clks) begin
      @(posedge clk);
      cnt++;
    end
  endtask

  // Consume one byte (assert rx_ready for one clock)
  task automatic rx_consume(output logic [7:0] data_out);
    wait_valid();
    data_out  = rx_data;
    rx_ready  = 1'b1;
    @(posedge clk);
    rx_ready  = 1'b1;  // hold ready (default)
  endtask

  // =========================================================================
  // Stimulus
  // =========================================================================
  logic [7:0] got;
  logic       got_par;

  initial begin
    rx_ready  = 1'b1;
    err_clear = 1'b0;

    repeat(4) @(posedge clk);
    rstn = 1'b1;
    repeat(2) @(posedge clk);

    // ------------------------------------------------------------------
    // T01: idle -- valid stays 0 with no data
    // ------------------------------------------------------------------
    repeat(BIT_CLKS * 4) @(posedge clk);
    chk(rx_valid === 1'b0, "T01 idle valid=0");

    // ------------------------------------------------------------------
    // T02: 0x55
    // ------------------------------------------------------------------
    rx_send(8'h55);
    wait_valid();
    chk(rx_valid === 1'b1, "T02 valid after 0x55");
    chk(rx_data  === 8'h55, "T02 data = 0x55");
    @(posedge clk); // consume
    rx_ready = 1'b1;

    // ------------------------------------------------------------------
    // T03: 0x00
    // ------------------------------------------------------------------
    rx_send(8'h00);
    wait_valid();
    chk(rx_data === 8'h00, "T03 data = 0x00");
    @(posedge clk);

    // ------------------------------------------------------------------
    // T04: 0xFF
    // ------------------------------------------------------------------
    rx_send(8'hFF);
    wait_valid();
    chk(rx_data === 8'hFF, "T04 data = 0xFF");
    @(posedge clk);

    // ------------------------------------------------------------------
    // T05: rx_ready = 0 -- valid/data held until ready asserted
    // ------------------------------------------------------------------
    rx_ready = 1'b0;                 // block consumer
    rx_send(8'hA5);
    wait_valid();
    chk(rx_valid === 1'b1,    "T05 valid held when ready=0");
    chk(rx_data  === 8'hA5,  "T05 data stable when ready=0");
    // hold a few cycles
    repeat(BIT_CLKS * 3) @(posedge clk);
    chk(rx_valid === 1'b1,    "T05 valid still held after 3 bit periods");
    chk(rx_data  === 8'hA5,  "T05 data still stable");
    // release -- wait 2 clocks: NBA applies rx_valid_q=0 at 1st posedge,
    // readable at 2nd posedge
    rx_ready = 1'b1;
    repeat(2) @(posedge clk);
    chk(rx_valid === 1'b0,    "T05 valid cleared after ready=1");

    // ------------------------------------------------------------------
    // T06: overrun -- send byte2 before byte1 consumed
    // ------------------------------------------------------------------
    err_clear = 1'b0;
    rx_ready  = 1'b0;               // hold consumer
    rx_send(8'h11);
    wait_valid();
    // byte 1 in holding register -- now send byte 2 without consuming byte 1
    rx_send(8'h22);
    // overrun_err should be set, byte 1 still present
    repeat(4) @(posedge clk);
    chk(overrun_err === 1'b1, "T06 overrun_err set");
    chk(rx_valid    === 1'b1, "T06 valid still set (byte1 intact)");
    chk(rx_data     === 8'h11, "T06 byte1 intact after overrun");
    // clear error + consume byte 1
    err_clear = 1'b1; @(posedge clk); err_clear = 1'b0;
    rx_ready  = 1'b1; @(posedge clk); rx_ready  = 1'b1;
    repeat(2) @(posedge clk);
    chk(overrun_err === 1'b0, "T06 overrun_err cleared");

    // ------------------------------------------------------------------
    // T07: frame error -- stop bit forced low
    // ------------------------------------------------------------------
    rx_ready  = 1'b1;
    err_clear = 1'b0;
    rx_send(8'h5A, .frame_err_force(1));
    repeat(BIT_CLKS * 2) @(posedge clk);
    chk(frame_err === 1'b1, "T07 frame_err set");
    err_clear = 1'b1; @(posedge clk); err_clear = 1'b0;
    repeat(2) @(posedge clk);
    chk(frame_err === 1'b0, "T07 frame_err cleared");

    // ------------------------------------------------------------------
    // T08: parity error -- send wrong parity bit
    // ------------------------------------------------------------------
    // 0x55 = 4 ones; odd parity should be 1; send 0 (wrong)
    rx_ready_op = 1'b1;
    rx_send_op(8'h55, 1'b0); // wrong parity (correct would be 1 for odd)
    wait_valid_op();
    @(posedge clk);
    repeat(4) @(posedge clk);
    chk(parity_err_op === 1'b1, "T08 parity_err set on wrong parity");
    // send correct parity -- no error
    rx_send_op(8'h55, 1'b1); // correct parity
    wait_valid_op();
    @(posedge clk);
    repeat(4) @(posedge clk);
    chk(rx_data_op === 8'h55, "T08 data correct when parity OK");

    // ------------------------------------------------------------------
    // T09: back-to-back -- two bytes, no inter-frame gap
    //   sender and receiver must run concurrently: byte1 is auto-consumed
    //   (rx_ready=1) before the second send completes, so a serial
    //   send-then-check would see byte2 where it expects byte1.
    // ------------------------------------------------------------------
    rx_ready = 1'b1;
    fork
      begin : t09_send
        rx_send_no_gap(8'hAB);
        rx_send_no_gap(8'hCD);
        rxd_drv = 1'b1;               // idle after second byte
      end
      begin : t09_recv
        wait_valid();
        chk(rx_data === 8'hAB, "T09 back-to-back byte1 = 0xAB");
        @(posedge clk);               // consume byte 1
        wait_valid();
        chk(rx_data === 8'hCD, "T09 back-to-back byte2 = 0xCD");
        @(posedge clk);               // consume byte 2
      end
    join

    // ------------------------------------------------------------------
    // T10: pending_start_q -- early start edge during stop bit
    //   stop bit truncated to BIT_CLKS/2 clocks; falling edge of the next
    //   start bit arrives before the stop bit's end_tick fires, so it must
    //   be latched by pending_start_q to avoid losing the second byte.
    //   Fork/join required: byte1 is auto-consumed before send completes.
    // ------------------------------------------------------------------
    rx_ready = 1'b1;
    fork
      begin : t10_send
        // stop_clks must exceed (BIT_CLKS/2 + 2FF_delay) so the half_tick
        // sample still sees rxd_sync_w=1; BIT_CLKS/2=8 is too short.
        rx_send_fast_stop(8'hE5, .stop_clks(BIT_CLKS * 3 / 4)); // 12 clocks
        rx_send_no_gap(8'h1A);        // falling edge while still in UART_STOP
        rxd_drv = 1'b1;               // return to idle
      end
      begin : t10_recv
        wait_valid();
        chk(rx_data === 8'hE5, "T10 pending_start_q byte1 = 0xE5");
        @(posedge clk);               // consume byte 1
        wait_valid();
        chk(rx_data === 8'h1A, "T10 pending_start_q byte2 = 0x1A");
        @(posedge clk);               // consume byte 2
      end
    join

    // ------------------------------------------------------------------
    // T11: even parity -- send wrong parity bit to dut_ep
    // ------------------------------------------------------------------
    // 0x55 = 01010101 -> 4 ones; even parity should be 0; send 1 (wrong)
    rx_ready_ep = 1'b1;
    rx_send_ep(8'h55, 1'b1); // wrong parity (correct would be 0 for even)
    wait_valid_ep();
    @(posedge clk);
    repeat(4) @(posedge clk);
    chk(parity_err_ep === 1'b1, "T11 parity_err set on wrong even parity");
    // send correct even parity -- data OK
    rx_send_ep(8'h55, 1'b0); // correct even parity
    wait_valid_ep();
    @(posedge clk);
    repeat(4) @(posedge clk);
    chk(rx_data_ep === 8'h55, "T11 data correct when even parity OK");

    // ------------------------------------------------------------------
    // T12: false start -- short glitch on rxd, no byte received
    //   Glitch = BIT_CLKS/4 clocks; rxd_sync_w restores to 1 before
    //   half_tick samples (clock 12 from start_i), so FSM returns to
    //   UART_IDLE without latching a byte or raising frame_err.
    // ------------------------------------------------------------------
    rx_ready  = 1'b1;
    err_clear = 1'b0;
    rxd_drv   = 1'b0;                              // glitch: rxd low
    repeat(BIT_CLKS / 4) @(posedge clk);          // 4 clocks
    rxd_drv   = 1'b1;                              // restore before half_tick
    repeat(BIT_CLKS * 4) @(posedge clk);          // let FSM settle
    chk(rx_valid  === 1'b0, "T12 no valid after false start");
    chk(frame_err === 1'b0, "T12 no frame error after false start");

    // ------------------------------------------------------------------
    // T13: 7-bit data mode
    //   Send 7'h7E (0111_1110); expect rx_data_7b = 8'h7E (MSB=0 padded).
    //   Then 7'h2B (010_1011); expect 8'h2B.
    // ------------------------------------------------------------------
    rx_send_7n1(7'h7E);
    wait_valid_7b();
    chk(rx_valid_7b === 1'b1,  "T13 valid after 7-bit 0x7E");
    chk(rx_data_7b  === 8'h7E, "T13 data = 0x7E (MSB=0 padded)");
    @(posedge clk);

    rx_send_7n1(7'h2B);
    wait_valid_7b();
    chk(rx_data_7b === 8'h2B, "T13 data = 0x2B");
    @(posedge clk);

    // ------------------------------------------------------------------
    // T14: 2 stop bits
    //   Frame: start + 8 data bits + stop1 + stop2.
    //   RX accepts both stop bits; data received correctly.
    // ------------------------------------------------------------------
    rx_send_8n2(8'hA5);
    wait_valid_s2();
    chk(rx_valid_s2 === 1'b1,  "T14 valid after 8N2 0xA5");
    chk(rx_data_s2  === 8'hA5, "T14 data = 0xA5");
    @(posedge clk);

    rx_send_8n2(8'h3C);
    wait_valid_s2();
    chk(rx_data_s2 === 8'h3C, "T14 data = 0x3C");
    @(posedge clk);

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(4) @(posedge clk);
    if (fails == 0)
      $display("PASS tb_uart_core_rx: all tests passed");
    else
      $display("FAIL tb_uart_core_rx: %0d test(s) failed", fails);

    $finish;
  end

  // Timeout watchdog
  initial begin
    repeat(600_000) @(posedge clk);
    $display("FAIL tb_uart_core_rx: TIMEOUT");
    $finish;
  end

endmodule : tb_uart_core_rx
