`timescale 1ns/1ps

// Testbench for xfcp_uart_mmio_top.
//
// XFCP protocol (xfcp_axil_bridge): SOP=0xFE, READ=0x10, WRITE=0x11.
// Byte order: addr big-endian, data MSB-first (LITTLE_ENDIAN=0, no swap).
//
// Request format:
//   WRITE: [0xFE][0x11][COUNT_HI][COUNT_LO][addr BE 4B][data MSB-first 4B]
//   READ:  [0xFE][0x10][COUNT_HI][COUNT_LO][addr BE 4B]
//   COUNT = 4 (one 32-bit word)
//
// Response format (xfcp_tx_packetizer):
//   WRITE: [0xFD][0x13][DEV_TYPE 2B][DEV_STR 16B][0x00+TLAST] = 21 bytes
//   READ:  [0xFD][0x12][DEV_TYPE 2B][DEV_STR 16B][data 4B MSB-first][0x00+TLAST] = 25 bytes
// Note: SOP_RESP=0xFD != SOP_REQ=0xFE to prevent TX->RX coupling issues.
//
// Tests:
//   T1: WRITE 0x3F to LED register (0xFF020004) -> led_o = 6'h3F
//   T2: READ LED register (0xFF020004) -> response data = 0x0000003F
//   T3: READ SYSC COMPONENT_ID (0xFF000000) -> "SYSC" = 0x53595343
//   T4: WRITE 0 to LED -> led_o = 0
//
// UART timing: BAUD_DIV=16 clocks/bit. One byte = 10 bits * 16 = 160 clocks.
// CLK_FREQ_HZ=1000 keeps axil_seven_seg_adapter TicksPerDigit >= 1 (>= DIGIT_REFRESH_HZ=250).
// A background monitor captures all bytes emitted on uart_tx_o without
// racing with the DUT response start time.
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) $(UART_COMMON) $(AXIS_UART) \
//        $(AXIL_COMMON) $(SEG_COMMON) $(XFCP_COMMON) \
//        ../rtl/xfcp_uart_mmio_top.sv \
//        tb_xfcp_uart_mmio_top.sv
//   vsim -c -do "run -all; quit" tb_xfcp_uart_mmio_top

module tb_xfcp_uart_mmio_top;

  localparam int BAUD_DIV    = 16;    // clocks per UART bit
  localparam int CLK_FREQ_HZ = 1000;  // must be >= DIGIT_REFRESH_HZ (250)

  logic clk, rst_ni;
  logic uart_rx_i;
  logic uart_tx_o;
  logic [5:0] led_00_o;
  logic [7:0] led_01_o;
  logic [7:0] led_02_o;
  logic [7:0] seg_o;
  logic [2:0] dig_o;

  xfcp_uart_mmio_top #(
    .CLOCK_FREQ_HZ        (CLK_FREQ_HZ),
    .UART_DEFAULT_BAUD_DIV(BAUD_DIV)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rst_ni),
    .uart_rx_i    (uart_rx_i),
    .uart_tx_o    (uart_tx_o),
    .led_00_o     (led_00_o),
    .led_01_o     (led_01_o),
    .led_02_o     (led_02_o),
    .onboard_seg_o(seg_o),
    .onboard_dig_o(dig_o)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ========================================================================
  // Background UART TX monitor — runs in parallel, never races with test.
  // Captures each byte emitted by uart_tx_o into rx_buf[].
  // ========================================================================
  logic [7:0] rx_buf [0:31];
  int unsigned rx_wptr;
  int unsigned rx_rptr;

  initial begin : uart_rx_monitor
    rx_wptr = 0;
    rx_rptr = 0;
    @(posedge rst_ni);
    repeat(4) @(posedge clk);
    forever begin
      logic [7:0] cap;
      cap = 8'h0;
      // Wait for falling edge = start bit
      @(negedge uart_tx_o);
      // Advance to centre of bit 0 (1 start + 0.5 data bit = 1.5 bit periods)
      repeat(BAUD_DIV + BAUD_DIV/2) @(posedge clk);
      // Sample 8 data bits LSB first
      for (int i = 0; i < 8; i++) begin
        cap[i] = uart_tx_o;
        if (i < 7) repeat(BAUD_DIV) @(posedge clk);
      end
      rx_buf[rx_wptr & 31] = cap;
      rx_wptr++;
      // Consume stop bit
      repeat(BAUD_DIV) @(posedge clk);
    end
  end

  // ========================================================================
  // Debug monitor — UART RX internal signals
  // ========================================================================
  initial begin : debug_monitor
    @(posedge rst_ni);
    repeat(2) @(posedge clk);
    $display("[%0t] DBG config_w=%05b baud_div=%0d",
             $time, dut.config_w, dut.baud_div_w);
    forever begin
      @(posedge clk);
      // Print start edge detection (new byte start bit)
      if (dut.u_uart_rx.i_core.rx_start_pulse_o) begin
        $display("[%0t] DBG start_pulse: uart_state=%s",
                 $time,
                 dut.u_uart_rx.i_core.state_q.name());
      end
      // Print when entering UART_DATA (bit_cnt just set)
      if (dut.u_uart_rx.i_core.state_q == uart_pkg::UART_START &&
          dut.u_uart_rx.i_baud_gen.end_tick_o) begin
        $display("[%0t] DBG START->DATA: bit_cnt=%0d dbits=%0b",
                 $time,
                 dut.u_uart_rx.i_core.bit_cnt_q,
                 dut.u_uart_rx.i_core.cfg_i.dbits);
      end
      // Print every UART valid pulse
      if (dut.u_uart_rx.i_core.valid_o) begin
        $display("[%0t] DBG UART valid: data=0x%02h shreg=0x%02h",
                 $time,
                 dut.u_uart_rx.i_core.data_o,
                 dut.u_uart_rx.i_core.shreg_q);
      end
    end
  end

  // ---- UART TX ----------------------------------------------------------------

  // Send one byte over UART RX input (LSB first, 8N1)
  task automatic uart_send(input logic [7:0] b);
    $display("[%0t] TB SEND 0x%02h", $time, b);
    @(negedge clk); uart_rx_i = 1'b0;          // start bit
    repeat(BAUD_DIV) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      @(negedge clk); uart_rx_i = b[i];
      repeat(BAUD_DIV) @(posedge clk);
    end
    @(negedge clk); uart_rx_i = 1'b1;          // stop bit
    repeat(BAUD_DIV) @(posedge clk);
  endtask

  // Get one captured byte from the monitor buffer (polls with timeout)
  task automatic uart_recv(output logic [7:0] b);
    int unsigned timeout_cnt;
    timeout_cnt = 0;
    while (rx_rptr == rx_wptr) begin
      @(posedge clk);
      timeout_cnt++;
      if (timeout_cnt > 200_000)
        $fatal(1, "uart_recv timeout after %0d clocks — DUT did not respond", timeout_cnt);
    end
    b = rx_buf[rx_rptr & 31];
    rx_rptr++;
  endtask

  // ---- XFCP helpers -----------------------------------------------------------

  // WRITE request: [0xFE][0x11][count=4 BE][addr BE][data MSB-first]
  task automatic xfcp_write(
    input logic [31:0] addr,
    input logic [31:0] data
  );
    uart_send(8'hFE);                           // SOP
    uart_send(8'h11);                           // XFCP_OP_WRITE
    uart_send(8'h00); uart_send(8'h04);         // COUNT = 4 (big-endian)
    uart_send(addr[31:24]); uart_send(addr[23:16]);  // addr big-endian
    uart_send(addr[15:8]);  uart_send(addr[7:0]);
    uart_send(data[31:24]); uart_send(data[23:16]);  // data MSB-first (LE=0)
    uart_send(data[15:8]);  uart_send(data[7:0]);
  endtask

  // Drain WRITE response: [0xFD][0x13][DEV_TYPE 2B][DEV_STR 16B][0x00] = 21 bytes
  // Wait 3000 extra cycles after last byte so post_tx_hold expires before next send.
  task automatic xfcp_drain_write_resp();
    logic [7:0] b;
    for (int i = 0; i < 21; i++) uart_recv(b);
    repeat(3000) @(posedge clk);
  endtask

  // READ request: [0xFE][0x10][count=4 BE][addr BE]
  task automatic xfcp_read(input logic [31:0] addr);
    uart_send(8'hFE);                           // SOP
    uart_send(8'h10);                           // XFCP_OP_READ
    uart_send(8'h00); uart_send(8'h04);         // COUNT = 4
    uart_send(addr[31:24]); uart_send(addr[23:16]);
    uart_send(addr[15:8]);  uart_send(addr[7:0]);
  endtask

  // Receive READ response: [0xFD][0x12][DEV_TYPE 2B][DEV_STR 16B][data 4B MSB-first][0x00]
  // = 25 bytes total; data reconstructed MSB-first (LITTLE_ENDIAN=0)
  task automatic xfcp_recv_read(output logic [31:0] rdata);
    logic [7:0] b;
    // Check SOP_RESP = 0xFD and TYPE = 0x12 (RESP_READ)
    uart_recv(b);
    if (b !== 8'hFD) $error("[%0t] xfcp_recv_read: bad SOP_RESP 0x%02h (exp 0xFD)", $time, b);
    uart_recv(b);
    if (b !== 8'h12) $error("[%0t] xfcp_recv_read: bad TYPE 0x%02h (exp 0x12)", $time, b);
    // Remaining header: DEV_TYPE(2) + DEV_STR(16) = 18 bytes
    for (int i = 0; i < 18; i++) uart_recv(b);
    // Data MSB-first
    uart_recv(b); rdata[31:24] = b;
    uart_recv(b); rdata[23:16] = b;
    uart_recv(b); rdata[15:8]  = b;
    uart_recv(b); rdata[7:0]   = b;
    // Terminator 0x00
    uart_recv(b);
    // Wait for post_tx_hold to expire before caller sends next request.
    repeat(3000) @(posedge clk);
  endtask

  // ---- Check helper -----------------------------------------------------------

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

  // ---- Main stimulus ----------------------------------------------------------

  logic [31:0] rdata;

  initial begin
    uart_rx_i = 1'b1;
    rst_ni    = 1'b0;
    repeat(8) @(posedge clk);
    rst_ni = 1'b1;
    repeat(4) @(posedge clk);

    // ---- T1: WRITE 0x3F to LED register (slot2 offset 0x04) ----
    xfcp_write(32'hFF020004, 32'h0000_003F);
    xfcp_drain_write_resp();
    chk32(32'(led_00_o), 32'h3F, "T1 led_00_o after write 0x3F");

    // ---- T2: READ LED register back ----
    xfcp_read(32'hFF020004);
    xfcp_recv_read(rdata);
    chk32(rdata, 32'h0000_003F, "T2 LED readback");

    // ---- T3: READ SYSC COMPONENT_ID (slot0 offset 0x00) ----
    xfcp_read(32'hFF000000);
    xfcp_recv_read(rdata);
    chk32(rdata, 32'h5359_5343, "T3 SYSC COMPONENT_ID");

    // ---- T4: Write 0 to LED, confirm led_o clears ----
    xfcp_write(32'hFF020004, 32'h0);
    xfcp_drain_write_resp();
    chk32(32'(led_00_o), 32'h0, "T4 led_00_o cleared");

    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
