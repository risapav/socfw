`timescale 1ns/1ps

// Testbench for eth_udp_echo_test.sv
//
// MAX_PAYLOAD_BYTES overridden to 8 so overflow fires on the 9th byte.
// UDP TX side (meta_ready, tx_ready) held high throughout -- no stack backpressure.
//
// Tests:
//   T1: register reset values (ID, VERSION, CONTROL, LOCAL_IP, UDP_PORT)
//   T2: echo 4-byte packet -- payload returned verbatim, counters verified
//   T3: port mismatch drop -- RX_DROP_COUNT++, no TX meta_valid
//   T4: CLEAR_COUNTERS pulse -- all saturating counters reset to 0
//   T5: disable (CONTROL[0]=0) -- correct port but enable=0, packet dropped
//   T6: re-enable + echo 3 bytes -- verify TX_FRAME_COUNT increments
//   T7: overflow (9 bytes > MAX_PL=8) -- RX_ERROR_COUNT++, LAST_ERROR=2, no echo
//   T8: consecutive packets -- FSM returns to IDLE, second echo payload correct
//
// Run:
//   vlog -sv -suppress 2892 \
//        ../../../rtl/axi/axi_pkg.sv \
//        ../../../rtl/axi/axi_interfaces.sv \
//        ../../../rtl/axil/axil_regfile.sv \
//        ../rtl/eth_udp_echo_test.sv \
//        unit/tb_eth_udp_echo_test.sv
//   vsim -c -do "run -all; quit" tb_eth_udp_echo_test

module tb_eth_udp_echo_test;
  import axi_pkg::*;

  localparam int          MAX_PL   = 8;
  localparam logic [31:0] MY_IP    = 32'hC0A8_0132;  // 192.168.1.50
  localparam logic [15:0] MY_PORT  = 16'd50000;
  localparam logic [31:0] PC_IP    = 32'hC0A8_0101;  // 192.168.1.1
  localparam logic [15:0] PC_PORT  = 16'd12345;
  localparam logic [15:0] BAD_PORT = 16'd60000;

  // ---------------------------------------------------------------------------
  // Clock / reset
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_ni;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // AXI-Lite interface
  // ---------------------------------------------------------------------------
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_if (
    .ACLK(clk), .ARESETn(rst_ni)
  );

  // ---------------------------------------------------------------------------
  // DUT port signals
  // ---------------------------------------------------------------------------
  logic        udp_rx_meta_valid, udp_rx_meta_ready;
  logic [31:0] udp_rx_src_ip,    udp_rx_dst_ip;
  logic [15:0] udp_rx_src_port,  udp_rx_dst_port, udp_rx_length;
  logic        udp_rx_valid,     udp_rx_ready;
  logic [7:0]  udp_rx_data;
  logic        udp_rx_last;

  logic        udp_tx_meta_valid, udp_tx_meta_ready;
  logic [31:0] udp_tx_dst_ip;
  logic [15:0] udp_tx_dst_port,  udp_tx_src_port, udp_tx_length;
  logic        udp_tx_valid,     udp_tx_ready;
  logic [7:0]  udp_tx_data;
  logic        udp_tx_last;

  logic        link_up, irq;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  eth_udp_echo_test #(
    .DEFAULT_IP       (MY_IP),
    .DEFAULT_UDP_PORT (MY_PORT),
    .MAX_PAYLOAD_BYTES(MAX_PL)
  ) dut (
    .clk_i              (clk),
    .rst_ni             (rst_ni),
    .s_axil             (axil_if.slave),
    .udp_rx_meta_valid_i(udp_rx_meta_valid),
    .udp_rx_meta_ready_o(udp_rx_meta_ready),
    .udp_rx_src_ip_i    (udp_rx_src_ip),
    .udp_rx_dst_ip_i    (udp_rx_dst_ip),
    .udp_rx_src_port_i  (udp_rx_src_port),
    .udp_rx_dst_port_i  (udp_rx_dst_port),
    .udp_rx_length_i    (udp_rx_length),
    .udp_rx_valid_i     (udp_rx_valid),
    .udp_rx_ready_o     (udp_rx_ready),
    .udp_rx_data_i      (udp_rx_data),
    .udp_rx_last_i      (udp_rx_last),
    .udp_tx_meta_valid_o(udp_tx_meta_valid),
    .udp_tx_meta_ready_i(udp_tx_meta_ready),
    .udp_tx_dst_ip_o    (udp_tx_dst_ip),
    .udp_tx_dst_port_o  (udp_tx_dst_port),
    .udp_tx_src_port_o  (udp_tx_src_port),
    .udp_tx_length_o    (udp_tx_length),
    .udp_tx_valid_o     (udp_tx_valid),
    .udp_tx_ready_i     (udp_tx_ready),
    .udp_tx_data_o      (udp_tx_data),
    .udp_tx_last_o      (udp_tx_last),
    .link_up_i          (link_up),
    .irq_o              (irq)
  );

  // ---------------------------------------------------------------------------
  // TX capture state (written by udp_collect, read by tests)
  // ---------------------------------------------------------------------------
  logic [7:0]  rx_buf  [MAX_PL];
  int          rx_n;
  logic [31:0] rx_dst_ip;
  logic [15:0] rx_dst_port, rx_src_port, rx_length;

  int fails = 0;

  // ---------------------------------------------------------------------------
  // AXI-Lite master tasks
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // UDP RX driver
  // Drives n bytes from pkt[] into the DUT RX port.
  // Returns at negedge after the last byte is clocked in.
  // Post-condition: DUT is in ST_SEND_META (echo) or ST_DONE (drop/overflow).
  // ---------------------------------------------------------------------------
  task automatic udp_send(
    input logic [31:0] src_ip_v,
    input logic [15:0] src_port_v,
    input logic [31:0] dst_ip_v,
    input logic [15:0] dst_port_v,
    input int          n,
    input logic [7:0]  pkt [MAX_PL]
  );
    @(negedge clk);
    udp_rx_src_ip     = src_ip_v;
    udp_rx_dst_ip     = dst_ip_v;
    udp_rx_src_port   = src_port_v;
    udp_rx_dst_port   = dst_port_v;
    udp_rx_length     = 16'(n);
    udp_rx_meta_valid = 1'b1;
    @(posedge clk);
    while (!udp_rx_meta_ready) @(posedge clk);
    @(negedge clk);
    udp_rx_meta_valid = 1'b0;
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      udp_rx_data  = pkt[i];
      udp_rx_valid = 1'b1;
      udp_rx_last  = (i == n - 1) ? 1'b1 : 1'b0;
      @(posedge clk);
      while (!udp_rx_ready) @(posedge clk);
    end
    @(negedge clk);
    udp_rx_valid = 1'b0;
    udp_rx_last  = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // UDP TX collector
  // Must be called right after udp_send (at negedge).
  // DUT should be entering ST_SEND_META; meta_valid is captured immediately.
  // Advances two posedges to reach first TX byte, then collects into rx_buf[].
  // ---------------------------------------------------------------------------
  task automatic udp_collect(output int status);
    int timeout;
    status = 0;

    // Meta should already be valid (DUT moved to ST_SEND_META in the last NBA)
    if (!udp_tx_meta_valid) begin
      timeout = 0;
      @(posedge clk);
      while (!udp_tx_meta_valid && timeout < 50) begin
        @(posedge clk); timeout++;
      end
      if (timeout >= 50) begin
        $display("FAIL udp_collect: meta_valid timeout"); fails++; status = 1; return;
      end
    end
    rx_dst_ip   = udp_tx_dst_ip;
    rx_dst_port = udp_tx_dst_port;
    rx_src_port = udp_tx_src_port;
    rx_length   = udp_tx_length;

    // Two posedges: meta consumed (N+1) → first TX byte ready (N+2)
    @(posedge clk);
    @(posedge clk);
    timeout = 0;
    while (!udp_tx_valid && timeout < 50) begin
      @(posedge clk); timeout++;
    end
    if (timeout >= 50) begin
      $display("FAIL udp_collect: tx_valid timeout"); fails++; status = 1; return;
    end

    rx_n = 0;
    while (1) begin
      if (udp_tx_valid) begin
        if (rx_n < MAX_PL) rx_buf[rx_n] = udp_tx_data;
        rx_n++;
        if (udp_tx_last) break;
      end
      @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Wait n cycles and assert no TX meta_valid fired
  // ---------------------------------------------------------------------------
  task automatic wait_no_tx(input int n);
    for (int i = 0; i < n; i++) @(posedge clk);
    if (udp_tx_meta_valid) begin
      $display("FAIL wait_no_tx: unexpected udp_tx_meta_valid (expected drop)");
      fails++;
    end else
      $display("PASS wait_no_tx: no TX as expected");
  endtask

  // ---------------------------------------------------------------------------
  // Main test sequence
  // ---------------------------------------------------------------------------
  logic [31:0] rdata;
  logic [7:0]  pkt [MAX_PL];
  int          cs;       // udp_collect status
  int          mm;       // mismatch counter

  initial begin
    // Init AXI-Lite
    axil_if.AWVALID = 0; axil_if.AWADDR = 0; axil_if.AWPROT = 0;
    axil_if.WVALID  = 0; axil_if.WDATA  = 0; axil_if.WSTRB  = 0;
    axil_if.BREADY  = 0;
    axil_if.ARVALID = 0; axil_if.ARADDR = 0; axil_if.ARPROT = 0;
    axil_if.RREADY  = 0;
    // Init UDP RX
    udp_rx_meta_valid = 1'b0;
    udp_rx_src_ip = '0; udp_rx_dst_ip = '0;
    udp_rx_src_port = '0; udp_rx_dst_port = '0; udp_rx_length = '0;
    udp_rx_valid = 1'b0; udp_rx_data = '0; udp_rx_last = 1'b0;
    // TX side: stack always ready
    udp_tx_meta_ready = 1'b1;
    udp_tx_ready      = 1'b1;
    link_up           = 1'b1;

    // Reset
    rst_ni = 1'b0;
    repeat(4) @(posedge clk);
    rst_ni = 1'b1;
    repeat(2) @(posedge clk);

    // ------------------------------------------------------------------
    // T1: Register reset values
    // ------------------------------------------------------------------
    $display("-- T1: Register reset values --");
    axi_read(32'h00, rdata); chk32(rdata, 32'h4554_485F,     "T1 ID");
    axi_read(32'h04, rdata); chk32(rdata, 32'h0001_0000,     "T1 VERSION");
    axi_read(32'h08, rdata); chk32(rdata, 32'h0000_0003,     "T1 CONTROL");
    axi_read(32'h10, rdata); chk32(rdata, MY_IP,              "T1 LOCAL_IP");
    axi_read(32'h14, rdata); chk32(rdata, {16'd0, MY_PORT},  "T1 UDP_PORT");

    // ------------------------------------------------------------------
    // T2: Echo 4-byte packet
    // ------------------------------------------------------------------
    $display("-- T2: Echo 4 bytes --");
    pkt = '{8'h11, 8'h22, 8'h33, 8'h44, 8'h00, 8'h00, 8'h00, 8'h00};
    udp_send(PC_IP, PC_PORT, MY_IP, MY_PORT, 4, pkt);
    udp_collect(cs);
    if (!cs) begin
      chk32(rx_dst_ip,             PC_IP,             "T2 tx_dst_ip");
      chk32({16'd0, rx_dst_port}, {16'd0, PC_PORT},  "T2 tx_dst_port");
      chk32({16'd0, rx_src_port}, {16'd0, MY_PORT},  "T2 tx_src_port");
      if (rx_n !== 4) begin
        $display("FAIL T2 length: got=%0d exp=4", rx_n); fails++;
      end else
        $display("PASS T2 length: 4");
      mm = 0;
      for (int i = 0; i < 4; i++)
        if (rx_buf[i] !== pkt[i]) mm++;
      if (mm) begin
        $display("FAIL T2 payload: %0d byte(s) mismatch", mm); fails++;
      end else
        $display("PASS T2 payload: match");
    end
    axi_read(32'h18, rdata); chk32(rdata, 32'd1, "T2 RX_FRAME_COUNT");
    axi_read(32'h1C, rdata); chk32(rdata, 32'd1, "T2 TX_FRAME_COUNT");
    axi_read(32'h34, rdata); chk32(rdata, PC_IP,  "T2 LAST_SRC_IP");
    axi_read(32'h40, rdata); chk32(rdata, 32'd4,  "T2 LAST_PAYLOAD_LEN");
    axi_read(32'h44, rdata); chk32(rdata, 32'd0,  "T2 LAST_ERROR=OK");

    // ------------------------------------------------------------------
    // T3: Port mismatch -- packet dropped
    // ------------------------------------------------------------------
    $display("-- T3: Port mismatch drop --");
    pkt[0] = 8'hAA;
    udp_send(PC_IP, PC_PORT, MY_IP, BAD_PORT, 1, pkt);
    wait_no_tx(20);
    axi_read(32'h28, rdata); chk32(rdata, 32'd1, "T3 RX_DROP_COUNT");
    axi_read(32'h1C, rdata); chk32(rdata, 32'd1, "T3 TX_FRAME_COUNT unchanged");

    // ------------------------------------------------------------------
    // T4: CLEAR_COUNTERS pulse
    // ------------------------------------------------------------------
    $display("-- T4: CLEAR_COUNTERS --");
    axi_write(32'h48, 32'h1);
    repeat(2) @(posedge clk);
    axi_read(32'h18, rdata); chk32(rdata, 32'd0, "T4 RX_FRAME_COUNT cleared");
    axi_read(32'h1C, rdata); chk32(rdata, 32'd0, "T4 TX_FRAME_COUNT cleared");
    axi_read(32'h28, rdata); chk32(rdata, 32'd0, "T4 RX_DROP_COUNT cleared");

    // ------------------------------------------------------------------
    // T5: Disable (CONTROL[0]=0) -- correct port but dropped
    // ------------------------------------------------------------------
    $display("-- T5: Disable --");
    axi_write(32'h08, 32'h02);  // echo_en=1, enable=0
    pkt[0] = 8'h55;
    udp_send(PC_IP, PC_PORT, MY_IP, MY_PORT, 1, pkt);
    wait_no_tx(20);
    axi_read(32'h28, rdata); chk32(rdata, 32'd1, "T5 dropped when disabled");

    // ------------------------------------------------------------------
    // T6: Re-enable + echo 3 bytes
    // ------------------------------------------------------------------
    $display("-- T6: Re-enable + echo 3 bytes --");
    axi_write(32'h08, 32'h03);  // enable=1, echo_en=1
    axi_write(32'h48, 32'h1);   // clear counters
    repeat(2) @(posedge clk);
    pkt = '{8'hAA, 8'hBB, 8'hCC, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
    udp_send(PC_IP, PC_PORT, MY_IP, MY_PORT, 3, pkt);
    udp_collect(cs);
    if (!cs) begin
      if (rx_n !== 3) begin
        $display("FAIL T6 length: got=%0d exp=3", rx_n); fails++;
      end else
        $display("PASS T6 length: 3");
      mm = 0;
      for (int i = 0; i < 3; i++)
        if (rx_buf[i] !== pkt[i]) mm++;
      if (mm) begin
        $display("FAIL T6 payload: %0d byte(s) mismatch", mm); fails++;
      end else
        $display("PASS T6 payload: match");
    end
    axi_read(32'h18, rdata); chk32(rdata, 32'd1, "T6 RX_FRAME_COUNT");
    axi_read(32'h1C, rdata); chk32(rdata, 32'd1, "T6 TX_FRAME_COUNT");

    // ------------------------------------------------------------------
    // T7: Overflow -- 9 bytes into 8-byte buffer
    // Byte 8 (i=8) arrives when overflow_r=1 and last=1 -> ST_DONE, error
    // ------------------------------------------------------------------
    $display("-- T7: Overflow (%0d bytes > MAX_PL=%0d) --", MAX_PL + 1, MAX_PL);
    axi_write(32'h48, 32'h1);
    repeat(2) @(posedge clk);
    @(negedge clk);
    udp_rx_src_ip    = PC_IP;   udp_rx_dst_ip   = MY_IP;
    udp_rx_src_port  = PC_PORT; udp_rx_dst_port = MY_PORT;
    udp_rx_length    = 16'd9;
    udp_rx_meta_valid = 1'b1;
    @(posedge clk); while (!udp_rx_meta_ready) @(posedge clk);
    @(negedge clk); udp_rx_meta_valid = 1'b0;
    for (int i = 0; i < 9; i++) begin
      @(negedge clk);
      udp_rx_data  = 8'(i + 1);
      udp_rx_valid = 1'b1;
      udp_rx_last  = (i == 8) ? 1'b1 : 1'b0;
      @(posedge clk); while (!udp_rx_ready) @(posedge clk);
    end
    @(negedge clk); udp_rx_valid = 1'b0; udp_rx_last = 1'b0;
    wait_no_tx(20);
    axi_read(32'h2C, rdata); chk32(rdata, 32'd1, "T7 RX_ERROR_COUNT");
    axi_read(32'h44, rdata); chk32(rdata, 32'd2, "T7 LAST_ERROR=TOO_LONG");

    // ------------------------------------------------------------------
    // T8: Consecutive packets -- FSM must return to IDLE between them
    // ------------------------------------------------------------------
    $display("-- T8: Consecutive packets --");
    axi_write(32'h48, 32'h1);
    repeat(2) @(posedge clk);

    // Packet A: 3 bytes
    pkt = '{8'hA1, 8'hA2, 8'hA3, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
    udp_send(PC_IP, PC_PORT, MY_IP, MY_PORT, 3, pkt);
    udp_collect(cs);
    if (!cs) begin
      if (rx_n !== 3) begin
        $display("FAIL T8a length: got=%0d exp=3", rx_n); fails++;
      end else
        $display("PASS T8a length: 3");
      mm = 0;
      for (int i = 0; i < 3; i++)
        if (rx_buf[i] !== pkt[i]) mm++;
      if (mm) begin
        $display("FAIL T8a payload: %0d byte(s) mismatch", mm); fails++;
      end else
        $display("PASS T8a payload: match");
    end

    // Packet B: 2 bytes (udp_send blocks until ST_IDLE via meta_ready handshake)
    pkt = '{8'hB1, 8'hB2, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
    udp_send(PC_IP, PC_PORT, MY_IP, MY_PORT, 2, pkt);
    udp_collect(cs);
    if (!cs) begin
      if (rx_n !== 2) begin
        $display("FAIL T8b length: got=%0d exp=2", rx_n); fails++;
      end else
        $display("PASS T8b length: 2");
      mm = 0;
      for (int i = 0; i < 2; i++)
        if (rx_buf[i] !== pkt[i]) mm++;
      if (mm) begin
        $display("FAIL T8b payload: %0d byte(s) mismatch", mm); fails++;
      end else
        $display("PASS T8b payload: match");
    end
    axi_read(32'h18, rdata); chk32(rdata, 32'd2, "T8 RX_FRAME_COUNT=2");
    axi_read(32'h1C, rdata); chk32(rdata, 32'd2, "T8 TX_FRAME_COUNT=2");

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
