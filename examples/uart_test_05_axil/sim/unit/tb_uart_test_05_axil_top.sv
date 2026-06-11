// tb_uart_test_05_axil_top -- integration test for uart_test_05_axil_top
//
// Verifies loopback via AXI-Lite master FSM:
//   UART RX -> uart_axil RX FIFO -> axil_uart_loopback -> uart_axil TX FIFO -> UART TX
//
// Tests:
//   T01  single byte echo: 0x55
//   T02  burst 16 bytes back-to-back
//   T03  burst 64 bytes back-to-back
//   T04  512-byte LFSR stream (fork: sender + receiver concurrent)
//
// Sim parameters: SIM_CLK=1_600_000, SIM_BAUD=12_500
//   BIT_CLKS   = 128 (128 clocks per UART bit)
//   FRAME_CLKS = 1280 (10 bits: start + 8 data + stop)
//   FIFO_DEPTH = 16  (small for faster sim)
//
// AXI-Lite loopback latency per byte: ~10-15 clocks (STATUS poll + RX read + TX write)
// Echo latency: FRAME_CLKS(RX) + ~12(AXI-Lite) + FRAME_CLKS(TX) = ~2572 clocks
//
// Run: vsim -c -do "run -all; quit" tb_uart_test_05_axil_top

`timescale 1ns/1ps

module tb_uart_test_05_axil_top;

  // =========================================================================
  // Sim parameters
  // =========================================================================
  localparam int SIM_CLK_HZ  = 1_600_000;
  localparam int SIM_BAUD    = 12_500;
  localparam int BIT_CLKS    = SIM_CLK_HZ / SIM_BAUD;  // 128
  localparam int FRAME_CLKS  = BIT_CLKS * 10;           // 1280
  localparam int FIFO_DEPTH  = 16;

  // =========================================================================
  // Clock + reset
  // =========================================================================
  logic clk  = 1'b0;
  logic rstn = 1'b0;

  always #5 clk = ~clk;

  // =========================================================================
  // DUT: uart_test_05_axil_top (pll_locked_i tied high -- no PLL in sim)
  // =========================================================================
  logic rxd_drv = 1'b1;
  wire  txd_w;
  wire  [5:0] leds_w;

  uart_test_05_axil_top #(
    .CLK_FREQ_HZ (SIM_CLK_HZ),
    .BAUD_RATE   (SIM_BAUD),
    .FIFO_DEPTH  (FIFO_DEPTH)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rstn),
    .pll_locked_i (1'b1),
    .uart_rx_i    (rxd_drv),
    .uart_tx_o    (txd_w),
    .led_o        (leds_w)
  );

  // =========================================================================
  // Check helper
  // =========================================================================
  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic chk(input logic cond, input string lbl);
    if (cond) begin $display("# PASS %s", lbl); pass_cnt++; end
    else      begin $display("# FAIL %s", lbl); fail_cnt++; end
  endtask

  // =========================================================================
  // BFM: drive rxd_drv with a UART frame (8N1)
  // =========================================================================
  task automatic uart_send(input logic [7:0] data);
    rxd_drv = 1'b0;                              // start bit
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = 1'b1;                              // stop bit
    repeat(BIT_CLKS) @(posedge clk);
    rxd_drv = 1'b1;
    repeat(2) @(posedge clk);
  endtask

  task automatic uart_send_no_gap(input logic [7:0] data);
    rxd_drv = 1'b0;
    repeat(BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rxd_drv = data[i];
      repeat(BIT_CLKS) @(posedge clk);
    end
    rxd_drv = 1'b1;
    repeat(BIT_CLKS) @(posedge clk);
  endtask

  // =========================================================================
  // BFM: receive one UART frame from txd_w (waits for start bit negedge)
  // =========================================================================
  task automatic uart_recv(output logic [7:0] data_out);
    @(negedge txd_w);
    repeat(BIT_CLKS + BIT_CLKS/2) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      data_out[i] = txd_w;
      repeat(BIT_CLKS) @(posedge clk);
    end
    chk(txd_w === 1'b1, "echo stop bit high");
  endtask

  // =========================================================================
  // Stimulus
  // =========================================================================
  logic [7:0] got;
  logic [7:0] got_arr[64];
  logic [7:0] stream_512[512];

  // Simple LFSR: poly x^8+x^6+x^5+x^1+1 = 0x61, same as uart_test_04 TB
  function automatic logic [7:0] lfsr_next(logic [7:0] s);
    return {s[6:0], s[7] ^ s[5] ^ s[4] ^ s[0]};
  endfunction

  initial begin
    repeat(4) @(posedge clk);
    rstn = 1'b1;
    // Extra cycles for axil_uart_loopback to reset and begin STATUS polling
    repeat(16) @(posedge clk);

    // ------------------------------------------------------------------
    // T01: single byte echo 0x55
    // ------------------------------------------------------------------
    fork
      uart_send(8'h55);
      uart_recv(got);
    join
    chk(got === 8'h55, "T01 echo 0x55");

    // ------------------------------------------------------------------
    // T02: burst 16 bytes back-to-back
    // ------------------------------------------------------------------
    fork
      begin
        for (int i = 0; i < 16; i++)
          uart_send_no_gap(8'hC0 + 8'(i));
        rxd_drv = 1'b1;
      end
      begin
        for (int i = 0; i < 16; i++) begin
          uart_recv(got_arr[i]);
          chk(got_arr[i] === 8'hC0 + 8'(i),
              $sformatf("T02 b2b byte[%0d] exp=0x%02h", i, 8'hC0 + 8'(i)));
        end
      end
    join

    // ------------------------------------------------------------------
    // T03: burst 64 bytes (fills FIFO, tests drain under load)
    // ------------------------------------------------------------------
    fork
      begin
        for (int i = 0; i < 64; i++)
          uart_send_no_gap(8'(i));
        rxd_drv = 1'b1;
      end
      begin
        for (int i = 0; i < 64; i++) begin
          uart_recv(got_arr[i % 64]);
          chk(got_arr[i % 64] === 8'(i),
              $sformatf("T03 bulk byte[%0d] exp=0x%02h", i, 8'(i)));
        end
      end
    join

    // ------------------------------------------------------------------
    // T04: 512-byte LFSR stream (fork: sender + receiver concurrent)
    // ------------------------------------------------------------------
    begin : blk_lfsr_init
      automatic logic [7:0] s = 8'hA5;
      for (int i = 0; i < 512; i++) begin
        stream_512[i] = s;
        s = lfsr_next(s);
      end
    end

    fork
      begin
        for (int i = 0; i < 512; i++)
          uart_send_no_gap(stream_512[i]);
        rxd_drv = 1'b1;
      end
      begin
        for (int i = 0; i < 512; i++) begin
          uart_recv(got);
          chk(got === stream_512[i],
              $sformatf("T04 byte[%0d] exp=0x%02h", i, stream_512[i]));
        end
      end
    join

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    repeat(10) @(posedge clk);
    $display("# tb_uart_test_05_axil_top: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("# tb_uart_test_05_axil_top: all tests passed");
    else
      $display("# FAIL tb_uart_test_05_axil_top: %0d failures", fail_cnt);
    $finish;
  end

endmodule
