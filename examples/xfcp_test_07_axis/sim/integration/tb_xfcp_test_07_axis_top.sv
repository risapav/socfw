`timescale 1ns/1ps

// tb_xfcp_test_07_axis_top -- integration test for xfcp_test_07_axis_top.
//
// T01-T12: AXIL read/write + ETH-UDP paths (same as xfcp_test_06).
// T13-T15: STREAM_WRITE then STREAM_READ loopback (sid=0, 4/16/64 bytes).
// T16:     STREAM_READ count=0  -> BAD_LENGTH (error, 5-byte response, no payload).
// T17:     STREAM_WRITE sid=1   -> UNSUPPORTED (5-byte response after drain).
// T18:     STREAM_READ  sid=1   -> UNSUPPORTED (5-byte error response).
// T19:     Mixed: AXIL WRITE then STREAM 16B loopback, then AXIL READ verify.

module tb_xfcp_test_07_axis_top;
  import tb_eth_pkg::*;

  // BAUD_DIV=32: uart_fifo_os needs PRESCALE_RX_OS>=2 -> min BAUD_DIV=32
  localparam int BAUD_DIV = 32;
  localparam int CLOCK_HZ = 1000;

  localparam logic [47:0] PC_MAC        = 48'hAA_BB_CC_DD_EE_FF;
  localparam logic [31:0] PC_IP         = 32'hC0A8_0064;
  localparam logic [15:0] PC_SPORT      = 16'h1234;
  localparam logic [47:0] DUT_MAC       = 48'h00_0A_35_01_FE_C5;
  localparam logic [31:0] DUT_IP        = 32'hC0A8_0005;
  localparam logic [15:0] XFCP_UDP_PORT = 16'hC350;  // 50000

  // =========================================================================
  // Clocks / reset
  // =========================================================================
  logic clk_i, eth_rx_clk_i, rst_ni;

  initial clk_i       = 1'b0;
  always  #5  clk_i   = ~clk_i;

  initial eth_rx_clk_i  = 1'b0;
  always  #5.5 eth_rx_clk_i = ~eth_rx_clk_i;

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic       eth_rxdv_i, eth_rxer_i;
  logic [7:0] eth_rxd_i;
  logic       eth_gtx_clk_o, eth_txen_o, eth_txer_o;
  logic [7:0] eth_txd_o;
  logic       eth_phyrstb_o, eth_mdc_o;
  wire        eth_mdio_io;

  logic       uart_rx_i, uart_tx_o;
  logic [5:0] led_o;
  logic [7:0] pmod_j10_o, pmod_j11_o;
  logic [7:0] seg_o;
  logic [2:0] dig_o;
  logic [3:0] btn_i;

  // =========================================================================
  // DUT instantiation
  // =========================================================================
  xfcp_test_07_axis_top #(
    .CLOCK_HZ       (CLOCK_HZ),
    .UART_BAUD_RATE (CLOCK_HZ / BAUD_DIV)
  ) dut (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .eth_rx_clk_i  (eth_rx_clk_i),
    .eth_rxdv_i    (eth_rxdv_i),
    .eth_rxer_i    (eth_rxer_i),
    .eth_rxd_i     (eth_rxd_i),
    .eth_gtx_clk_o (eth_gtx_clk_o),
    .eth_txen_o    (eth_txen_o),
    .eth_txer_o    (eth_txer_o),
    .eth_txd_o     (eth_txd_o),
    .eth_phyrstb_o (eth_phyrstb_o),
    .eth_mdc_o     (eth_mdc_o),
    .eth_mdio_io   (eth_mdio_io),
    .uart_rx_i     (uart_rx_i),
    .uart_tx_o     (uart_tx_o),
    .led_o         (led_o),
    .pmod_j10_o    (pmod_j10_o),
    .pmod_j11_o    (pmod_j11_o),
    .seg_o         (seg_o),
    .dig_o         (dig_o),
    .btn_i         (btn_i)
  );

  // =========================================================================
  // Background UART TX monitor
  // =========================================================================
  logic [7:0]  rx_buf [0:255];
  int unsigned rx_wptr;
  int unsigned rx_rptr;

  initial begin : uart_tx_monitor
    rx_wptr = 0;
    rx_rptr = 0;
    @(posedge rst_ni);
    repeat (4) @(posedge clk_i);
    forever begin
      logic [7:0] cap;
      cap = 8'h0;
      @(negedge uart_tx_o);
      repeat (BAUD_DIV + BAUD_DIV/2) @(posedge clk_i);
      for (int i = 0; i < 8; i++) begin
        cap[i] = uart_tx_o;
        if (i < 7) repeat (BAUD_DIV) @(posedge clk_i);
      end
      rx_buf[rx_wptr & 255] = cap;
      rx_wptr++;
      repeat (BAUD_DIV) @(posedge clk_i);
    end
  end

  // =========================================================================
  // Check helpers
  // =========================================================================
  int fails;

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

  task automatic chk8(
    input logic [7:0] got,
    input logic [7:0] exp,
    input string      lbl
  );
    if (got !== exp) begin
      $display("FAIL %s: got=0x%02X exp=0x%02X", lbl, got, exp);
      fails++;
    end else
      $display("PASS %s: 0x%02X", lbl, got);
  endtask

  task automatic chk_bool(input logic cond, input string lbl);
    if (!cond) begin $display("FAIL %s", lbl); fails++; end
    else             $display("PASS %s", lbl);
  endtask

  // =========================================================================
  // UART send / receive
  // =========================================================================
  task automatic uart_send(input logic [7:0] b);
    @(negedge clk_i); uart_rx_i = 1'b0;
    repeat (BAUD_DIV) @(posedge clk_i);
    for (int i = 0; i < 8; i++) begin
      @(negedge clk_i); uart_rx_i = b[i];
      repeat (BAUD_DIV) @(posedge clk_i);
    end
    @(negedge clk_i); uart_rx_i = 1'b1;
    repeat (BAUD_DIV) @(posedge clk_i);
  endtask

  task automatic uart_recv(output logic [7:0] b);
    int unsigned timeout_cnt;
    timeout_cnt = 0;
    while (rx_rptr == rx_wptr) begin
      @(posedge clk_i);
      timeout_cnt++;
      if (timeout_cnt > 1_000_000)
        $fatal(1, "uart_recv timeout -- DUT did not respond");
    end
    b = rx_buf[rx_rptr & 255];
    rx_rptr++;
  endtask

  // =========================================================================
  // AXIL XFCP helpers
  // =========================================================================
  task automatic xfcp_write(
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [7:0]  seq = 8'h00
  );
    uart_send(8'hFE); uart_send(8'h11); uart_send(seq);
    uart_send(8'h00); uart_send(8'h04);
    uart_send(addr[31:24]); uart_send(addr[23:16]);
    uart_send(addr[15:8]);  uart_send(addr[7:0]);
    uart_send(data[31:24]); uart_send(data[23:16]);
    uart_send(data[15:8]);  uart_send(data[7:0]);
  endtask

  task automatic drain_write_resp();
    logic [7:0] b;
    for (int i = 0; i < 5; i++) uart_recv(b);
    repeat (2000) @(posedge clk_i);
  endtask

  task automatic xfcp_read(
    input logic [31:0] addr,
    input logic [7:0]  seq = 8'h00
  );
    uart_send(8'hFE); uart_send(8'h10); uart_send(seq);
    uart_send(8'h00); uart_send(8'h04);
    uart_send(addr[31:24]); uart_send(addr[23:16]);
    uart_send(addr[15:8]);  uart_send(addr[7:0]);
  endtask

  task automatic recv_read(output logic [31:0] rdata);
    logic [7:0] b;
    uart_recv(b);
    if (b !== 8'hFD)
      $display("WARN recv_read: expected SOP_RESP=0xFD, got 0x%02X", b);
    uart_recv(b);
    if (b !== 8'h12)
      $display("WARN recv_read: expected OP=0x12, got 0x%02X", b);
    uart_recv(b);               // SEQ echo
    uart_recv(b);               // STATUS (must be 0x00)
    if (b !== 8'h00)
      $display("WARN recv_read: STATUS=0x%02X (expected 0x00=OK)", b);
    uart_recv(b); rdata[31:24] = b;
    uart_recv(b); rdata[23:16] = b;
    uart_recv(b); rdata[15:8]  = b;
    uart_recv(b); rdata[7:0]   = b;
    uart_recv(b);               // terminator 0x00
    repeat (2000) @(posedge clk_i);
  endtask

  // =========================================================================
  // STREAM XFCP helpers
  // =========================================================================

  // STREAM_WRITE: SOP(FE) + OP(20) + SEQ + COUNT(2) + ADDR(4,sid) + DATA
  task automatic xfcp_stream_write(
    input logic [7:0]  seq,
    input logic [7:0]  stream_id,
    input logic [15:0] count,
    input logic [7:0]  data[256]
  );
    uart_send(8'hFE); uart_send(8'h20); uart_send(seq);
    uart_send(count[15:8]); uart_send(count[7:0]);
    uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(stream_id);
    for (int i = 0; i < int'(count); i++) uart_send(data[i]);
  endtask

  // Drain STREAM_WRITE response: SOP + 0x22 + SEQ + STATUS + TERM = 5 bytes.
  // Returns STATUS byte.
  task automatic drain_stream_write_resp(output logic [7:0] status);
    logic [7:0] b;
    uart_recv(b);  // SOP 0xFD
    if (b !== 8'hFD) $display("WARN drain_sw_resp: SOP=0x%02X", b);
    uart_recv(b);  // OP 0x22
    if (b !== 8'h22) $display("WARN drain_sw_resp: OP=0x%02X", b);
    uart_recv(b);  // SEQ echo
    uart_recv(status);
    uart_recv(b);  // terminator
    repeat (2000) @(posedge clk_i);
  endtask

  // STREAM_READ request: SOP(FE) + OP(21) + SEQ + COUNT(2) + ADDR(4,sid)
  task automatic xfcp_stream_read(
    input logic [7:0]  seq,
    input logic [7:0]  stream_id,
    input logic [15:0] count
  );
    uart_send(8'hFE); uart_send(8'h21); uart_send(seq);
    uart_send(count[15:8]); uart_send(count[7:0]);
    uart_send(8'h00); uart_send(8'h00); uart_send(8'h00); uart_send(stream_id);
  endtask

  // Receive STREAM_READ response. count = expected bytes in payload.
  // Returns data in dout[0..count-1] and STATUS byte.
  // For error responses (STATUS != 0), payload is empty (5 bytes total).
  task automatic recv_stream_read(
    input  logic [15:0] count,
    output logic [7:0]  dout[256],
    output logic [7:0]  status
  );
    logic [7:0] b;
    uart_recv(b);  // SOP 0xFD
    if (b !== 8'hFD) $display("WARN recv_sr: SOP=0x%02X", b);
    uart_recv(b);  // OP 0x23
    if (b !== 8'h23) $display("WARN recv_sr: OP=0x%02X", b);
    uart_recv(b);  // SEQ echo
    uart_recv(status);
    if (status == 8'h00) begin
      for (int i = 0; i < int'(count); i++) uart_recv(dout[i]);
    end
    uart_recv(b);  // terminator 0x00
    repeat (2000) @(posedge clk_i);
  endtask

  // =========================================================================
  // ETH helpers (unchanged from xfcp_test_06)
  // =========================================================================
  function automatic logic [15:0] ip_chk(input logic [7:0] h[20]);
    logic [31:0] s;
    s = '0;
    for (int i = 0; i < 20; i += 2) s += {h[i], h[i+1]};
    s = (s >> 16) + (s & 32'hFFFF);
    s = (s >> 16) + s;
    return ~s[15:0];
  endfunction

  task automatic drive_xfcp_gmii(
    input logic [7:0] xfcp_pay[],
    input int         n_pay
  );
    automatic logic [7:0] eth_hdr[14];
    automatic logic [7:0] ip_hdr[20];
    automatic logic [7:0] udp_hdr[8];
    automatic logic [7:0] frame[];
    automatic logic [7:0] fcs_b[4];
    automatic logic [31:0] fcs;
    automatic int n_ip_total = 20 + 8 + n_pay;
    automatic int udp_total  = 8 + n_pay;
    automatic int n_frame;
    automatic logic [15:0] chk;

    build_eth_hdr(DUT_MAC, PC_MAC, 16'h0800, eth_hdr);

    ip_hdr[ 0] = 8'h45;              ip_hdr[ 1] = 8'h00;
    ip_hdr[ 2] = n_ip_total[15:8];   ip_hdr[ 3] = n_ip_total[7:0];
    ip_hdr[ 4] = 8'h00;              ip_hdr[ 5] = 8'h01;
    ip_hdr[ 6] = 8'h00;              ip_hdr[ 7] = 8'h00;
    ip_hdr[ 8] = 8'h40;              ip_hdr[ 9] = 8'h11;
    ip_hdr[10] = 8'h00;              ip_hdr[11] = 8'h00;
    ip_hdr[12] = PC_IP[31:24];       ip_hdr[13] = PC_IP[23:16];
    ip_hdr[14] = PC_IP[15:8];        ip_hdr[15] = PC_IP[7:0];
    ip_hdr[16] = DUT_IP[31:24];      ip_hdr[17] = DUT_IP[23:16];
    ip_hdr[18] = DUT_IP[15:8];       ip_hdr[19] = DUT_IP[7:0];
    chk = ip_chk(ip_hdr);
    ip_hdr[10] = chk[15:8];
    ip_hdr[11] = chk[7:0];

    udp_hdr[0] = PC_SPORT[15:8];         udp_hdr[1] = PC_SPORT[7:0];
    udp_hdr[2] = XFCP_UDP_PORT[15:8];    udp_hdr[3] = XFCP_UDP_PORT[7:0];
    udp_hdr[4] = udp_total[15:8];        udp_hdr[5] = udp_total[7:0];
    udp_hdr[6] = 8'h00;                  udp_hdr[7] = 8'h00;

    n_frame = 14 + 20 + 8 + n_pay;
    frame   = new[n_frame];
    for (int i = 0; i < 14;    i++) frame[i]    = eth_hdr[i];
    for (int i = 0; i < 20;    i++) frame[14+i] = ip_hdr[i];
    for (int i = 0; i < 8;     i++) frame[34+i] = udp_hdr[i];
    for (int i = 0; i < n_pay; i++) frame[42+i] = xfcp_pay[i];

    fcs = crc32(frame, n_frame);
    fcs_b[0] = fcs[7:0];   fcs_b[1] = fcs[15:8];
    fcs_b[2] = fcs[23:16]; fcs_b[3] = fcs[31:24];

    for (int i = 0; i < 7; i++) begin
      @(negedge eth_rx_clk_i);
      eth_rxd_i = 8'h55; eth_rxdv_i = 1'b1; eth_rxer_i = 1'b0;
    end
    @(negedge eth_rx_clk_i); eth_rxd_i = 8'hD5;
    for (int i = 0; i < n_frame; i++) begin
      @(negedge eth_rx_clk_i); eth_rxd_i = frame[i];
    end
    for (int i = 0; i < 4; i++) begin
      @(negedge eth_rx_clk_i); eth_rxd_i = fcs_b[i];
    end
    @(negedge eth_rx_clk_i); eth_rxd_i = 8'h00; eth_rxdv_i = 1'b0;
  endtask

  task automatic capture_gmii_tx(output logic [7:0] cap[], output int n);
    automatic logic [7:0] tmp[$];
    automatic int timeout;

    tmp     = {};
    timeout = 0;

    while (!eth_txen_o && timeout < 8000) begin
      @(posedge clk_i);
      timeout++;
    end

    if (!eth_txen_o) begin
      n   = 0;
      cap = {};
      return;
    end

    while (eth_txen_o) begin
      tmp.push_back(eth_txd_o);
      @(posedge clk_i);
    end

    n   = tmp.size();
    cap = new[n];
    for (int i = 0; i < n; i++) cap[i] = tmp[i];
  endtask

  // =========================================================================
  // Main test sequence
  // =========================================================================
  logic [31:0] rdata;

  initial begin
    fails     = 0;
    uart_rx_i = 1'b1;
    btn_i     = 4'b1000;
    eth_rxdv_i = 1'b0; eth_rxer_i = 1'b0; eth_rxd_i = 8'h0;

    rst_ni = 1'b0;
    repeat (8) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (4) @(posedge clk_i);

    // ==============================================================
    // AXIL tests T01-T10 (same as xfcp_test_06 T1-T10)
    // ==============================================================

    // T01: WRITE 0x3F to LED (slot 2, offset 0x04)
    xfcp_write(32'hFF02_0004, 32'h0000_003F);
    drain_write_resp();
    chk32(32'(led_o), 32'h3F, "T01 led_o after write 0x3F");

    // T02: READ LED register back
    xfcp_read(32'hFF02_0004);
    recv_read(rdata);
    chk32(rdata, 32'h0000_003F, "T02 LED readback");

    // T03: SYSC COMPONENT_ID = "SYSC" = 0x5359_5343
    xfcp_read(32'hFF00_0000, 8'h03);
    recv_read(rdata);
    chk32(rdata, 32'h5359_5343, "T03 SYSC COMPONENT_ID");

    // T04: UART adapter COMPONENT_ID = "UART" = 0x5541_5254
    xfcp_read(32'hFF01_0000, 8'h04);
    recv_read(rdata);
    chk32(rdata, 32'h5541_5254, "T04 UART COMPONENT_ID");

    // T05: LED axil_regs COMPONENT_ID = "OUT_" = 0x4F55_545F
    xfcp_read(32'hFF02_0000, 8'h05);
    recv_read(rdata);
    chk32(rdata, 32'h4F55_545F, "T05 LED COMPONENT_ID");

    // T06: PMOD J10 COMPONENT_ID = "OUT_"
    xfcp_read(32'hFF03_0000, 8'h06);
    recv_read(rdata);
    chk32(rdata, 32'h4F55_545F, "T06 J10 COMPONENT_ID");

    // T07: PMOD J11 COMPONENT_ID = "OUT_"
    xfcp_read(32'hFF04_0000, 8'h07);
    recv_read(rdata);
    chk32(rdata, 32'h4F55_545F, "T07 J11 COMPONENT_ID");

    // T08: SEG7 adapter COMPONENT_ID = "SEG7" = 0x5345_4737
    xfcp_read(32'hFF05_0000, 8'h08);
    recv_read(rdata);
    chk32(rdata, 32'h5345_4737, "T08 SEG7 COMPONENT_ID");

    // T09: DIAG ctrl COMPONENT_ID = "DIAG" = 0x4449_4147
    xfcp_read(32'hFF06_0000, 8'h09);
    recv_read(rdata);
    chk32(rdata, 32'h4449_4147, "T09 DIAG COMPONENT_ID");

    // T10: WRITE 0 to LED, verify clear
    xfcp_write(32'hFF02_0004, 32'h0000_0000, 8'h0A);
    drain_write_resp();
    chk32(32'(led_o), 32'h0, "T10 led_o cleared");

    // ==============================================================
    // ETH-UDP tests T11-T12
    // ==============================================================

    // T11: ETH XFCP READ of SYSC COMPONENT_ID
    $display("--- T11: ETH-UDP XFCP READ SYSC ---");
    begin
      automatic logic [7:0] req[9] = '{
        8'hFE, 8'h10, 8'hBB, 8'h00, 8'h04, 8'hFF, 8'h00, 8'h00, 8'h00
      };
      automatic logic [7:0] cap[];
      automatic int n;
      automatic logic [47:0] got_dst_mac;
      automatic logic [15:0] got_etype, got_udp_src, got_udp_dst;
      automatic logic [7:0]  xfcp_sop, xfcp_op, xfcp_seq, xfcp_status;

      drive_xfcp_gmii(req, 9);
      capture_gmii_tx(cap, n);

      // Minimum: preamble(8)+ETH(14)+IPv4(20)+UDP(8)+XFCP_HDR(4)+DATA(4)+TERM(1) = 59
      chk_bool(n >= 59, "T11.frame_received");
      if (n >= 59) begin
        got_dst_mac = {cap[8],cap[9],cap[10],cap[11],cap[12],cap[13]};
        got_etype   = {cap[20], cap[21]};
        chk_bool(got_dst_mac == PC_MAC,   "T11.dst_mac==PC_MAC");
        chk_bool(got_etype   == 16'h0800, "T11.ethertype==0x0800");
        got_udp_src = {cap[42], cap[43]};
        got_udp_dst = {cap[44], cap[45]};
        chk_bool(got_udp_src == XFCP_UDP_PORT, "T11.udp_src==50000");
        chk_bool(got_udp_dst == PC_SPORT,       "T11.udp_dst==PC_SPORT");
        xfcp_sop    = cap[50]; xfcp_op  = cap[51];
        xfcp_seq    = cap[52]; xfcp_status = cap[53];
        chk_bool(xfcp_sop    == 8'hFD, "T11.xfcp_sop==0xFD");
        chk_bool(xfcp_op     == 8'h12, "T11.xfcp_op==READ_RESP");
        chk_bool(xfcp_seq    == 8'hBB, "T11.xfcp_seq_echo");
        chk_bool(xfcp_status == 8'h00, "T11.xfcp_status==OK");
      end
    end

    // T12: ETH XFCP WRITE to LED register
    $display("--- T12: ETH-UDP XFCP WRITE LED ---");
    begin
      automatic logic [7:0] req[13] = '{
        8'hFE, 8'h11, 8'hCC, 8'h00, 8'h04,
        8'hFF, 8'h02, 8'h00, 8'h04,
        8'h00, 8'h00, 8'h00, 8'h15
      };
      automatic logic [7:0] cap[];
      automatic int n;
      automatic logic [7:0] xfcp_sop, xfcp_op, xfcp_seq, xfcp_status;

      drive_xfcp_gmii(req, 13);
      capture_gmii_tx(cap, n);

      // Minimum: preamble(8)+ETH(14)+IPv4(20)+UDP(8)+XFCP_HDR(4)+TERM(1) = 55
      chk_bool(n >= 55, "T12.frame_received");
      if (n >= 55) begin
        xfcp_sop    = cap[50]; xfcp_op  = cap[51];
        xfcp_seq    = cap[52]; xfcp_status = cap[53];
        chk_bool(xfcp_sop    == 8'hFD, "T12.xfcp_sop==0xFD");
        chk_bool(xfcp_op     == 8'h13, "T12.xfcp_op==WRITE_RESP");
        chk_bool(xfcp_seq    == 8'hCC, "T12.xfcp_seq_echo");
        chk_bool(xfcp_status == 8'h00, "T12.xfcp_status==OK");
      end
      repeat (50) @(posedge clk_i);
      chk32(32'(led_o), 32'h15, "T12.led_o==0x15");
    end

    // ==============================================================
    // STREAM loopback tests T13-T15 (sid=0, loopback FIFO)
    // ==============================================================

    // T13: STREAM_WRITE 4 bytes, STREAM_READ 4 bytes
    $display("--- T13: STREAM 4-byte loopback ---");
    begin
      automatic logic [7:0] wr[256] = '{default: 8'h00};
      automatic logic [7:0] rd[256];
      automatic logic [7:0] status;
      wr[0] = 8'hDE; wr[1] = 8'hAD; wr[2] = 8'hBE; wr[3] = 8'hEF;
      xfcp_stream_write(8'h30, 8'h00, 16'd4, wr);
      drain_stream_write_resp(status);
      chk8(status, 8'h00, "T13.stream_write_status");
      xfcp_stream_read(8'h31, 8'h00, 16'd4);
      recv_stream_read(16'd4, rd, status);
      chk8(status, 8'h00, "T13.stream_read_status");
      chk8(rd[0], 8'hDE, "T13.byte[0]");
      chk8(rd[1], 8'hAD, "T13.byte[1]");
      chk8(rd[2], 8'hBE, "T13.byte[2]");
      chk8(rd[3], 8'hEF, "T13.byte[3]");
    end

    // T14: STREAM_WRITE 16 bytes, STREAM_READ 16 bytes
    $display("--- T14: STREAM 16-byte loopback ---");
    begin
      automatic logic [7:0] wr[256] = '{default: 8'h00};
      automatic logic [7:0] rd[256];
      automatic logic [7:0] status;
      for (int i = 0; i < 16; i++) wr[i] = 8'(i);
      xfcp_stream_write(8'h40, 8'h00, 16'd16, wr);
      drain_stream_write_resp(status);
      chk8(status, 8'h00, "T14.stream_write_status");
      xfcp_stream_read(8'h41, 8'h00, 16'd16);
      recv_stream_read(16'd16, rd, status);
      chk8(status, 8'h00, "T14.stream_read_status");
      begin
        logic all_ok;
        all_ok = 1'b1;
        for (int i = 0; i < 16; i++) begin
          if (rd[i] !== 8'(i)) begin
            $display("FAIL T14.byte[%0d]: got=0x%02X exp=0x%02X", i, rd[i], 8'(i));
            all_ok = 1'b0;
            fails++;
          end
        end
        if (all_ok) $display("PASS T14 16-byte payload match");
      end
    end

    // T15: STREAM_WRITE 64 bytes, STREAM_READ 64 bytes
    $display("--- T15: STREAM 64-byte loopback ---");
    begin
      automatic logic [7:0] wr[256] = '{default: 8'h00};
      automatic logic [7:0] rd[256];
      automatic logic [7:0] status;
      for (int i = 0; i < 64; i++) wr[i] = 8'(i & 8'hFF);
      xfcp_stream_write(8'h50, 8'h00, 16'd64, wr);
      drain_stream_write_resp(status);
      chk8(status, 8'h00, "T15.stream_write_status");
      xfcp_stream_read(8'h51, 8'h00, 16'd64);
      recv_stream_read(16'd64, rd, status);
      chk8(status, 8'h00, "T15.stream_read_status");
      begin
        logic all_ok;
        all_ok = 1'b1;
        for (int i = 0; i < 64; i++) begin
          if (rd[i] !== 8'(i & 8'hFF)) begin
            $display("FAIL T15.byte[%0d]: got=0x%02X exp=0x%02X",
                     i, rd[i], 8'(i & 8'hFF));
            all_ok = 1'b0;
            fails++;
          end
        end
        if (all_ok) $display("PASS T15 64-byte payload match");
      end
    end

    // ==============================================================
    // Error handling tests T16-T18
    // ==============================================================

    // T16: STREAM_READ count=0 -> BAD_LENGTH (adapter-level, 5-byte resp, no payload)
    $display("--- T16: STREAM_READ count=0 -> BAD_LENGTH ---");
    begin
      automatic logic [7:0] rd[256];
      automatic logic [7:0] status;
      xfcp_stream_read(8'h60, 8'h00, 16'd0);
      recv_stream_read(16'd0, rd, status);
      chk8(status, 8'h02, "T16.status==BAD_LENGTH");
    end

    // T17: STREAM_WRITE sid=1 -> UNSUPPORTED (must drain 1 wdata word)
    $display("--- T17: STREAM_WRITE sid=1 -> UNSUPPORTED ---");
    begin
      automatic logic [7:0] wr[256] = '{default: 8'hAA};
      automatic logic [7:0] status;
      xfcp_stream_write(8'h70, 8'h01, 16'd4, wr);
      drain_stream_write_resp(status);
      chk8(status, 8'h09, "T17.status==UNSUPPORTED");
    end

    // T18: STREAM_READ sid=1 -> UNSUPPORTED (5-byte error, no payload)
    $display("--- T18: STREAM_READ sid=1 -> UNSUPPORTED ---");
    begin
      automatic logic [7:0] rd[256];
      automatic logic [7:0] status;
      xfcp_stream_read(8'h80, 8'h01, 16'd4);
      recv_stream_read(16'd4, rd, status);
      chk8(status, 8'h09, "T18.status==UNSUPPORTED");
    end

    // ==============================================================
    // T19: Mixed AXIL + STREAM — verify no cross-contamination
    // ==============================================================
    $display("--- T19: Mixed AXIL WRITE + STREAM loopback + AXIL READ ---");
    begin
      automatic logic [7:0] wr[256] = '{default: 8'h00};
      automatic logic [7:0] rd[256];
      automatic logic [7:0] status;
      // AXIL WRITE to LED
      xfcp_write(32'hFF02_0004, 32'h0000_002A, 8'h90);
      drain_write_resp();
      // STREAM 4-byte loopback
      wr[0] = 8'h11; wr[1] = 8'h22; wr[2] = 8'h33; wr[3] = 8'h44;
      xfcp_stream_write(8'h91, 8'h00, 16'd4, wr);
      drain_stream_write_resp(status);
      chk8(status, 8'h00, "T19.stream_write_status");
      xfcp_stream_read(8'h92, 8'h00, 16'd4);
      recv_stream_read(16'd4, rd, status);
      chk8(status,  8'h00, "T19.stream_read_status");
      chk8(rd[0], 8'h11, "T19.byte[0]");
      chk8(rd[1], 8'h22, "T19.byte[1]");
      chk8(rd[2], 8'h33, "T19.byte[2]");
      chk8(rd[3], 8'h44, "T19.byte[3]");
      // AXIL READ LED back — verify STREAM did not corrupt AXIL path
      xfcp_read(32'hFF02_0004, 8'h93);
      recv_read(rdata);
      chk32(rdata, 32'h0000_002A, "T19.LED_axil_readback");
    end

    // ==============================================================
    // T20: STREAM_WRITE 256 bytes, STREAM_READ 256 bytes (max payload, fills loopback FIFO)
    // ==============================================================
    $display("--- T20: STREAM 256-byte loopback ---");
    begin
      automatic logic [7:0] wr[256];
      automatic logic [7:0] rd[256];
      automatic logic [7:0] status;
      for (int i = 0; i < 256; i++) wr[i] = 8'(i & 8'hFF);
      xfcp_stream_write(8'hA0, 8'h00, 16'd256, wr);
      drain_stream_write_resp(status);
      chk8(status, 8'h00, "T20.stream_write_status");
      xfcp_stream_read(8'hA1, 8'h00, 16'd256);
      recv_stream_read(16'd256, rd, status);
      chk8(status, 8'h00, "T20.stream_read_status");
      begin
        logic all_ok;
        all_ok = 1'b1;
        for (int i = 0; i < 256; i++) begin
          if (rd[i] !== 8'(i & 8'hFF)) begin
            $display("FAIL T20.byte[%0d]: got=0x%02X exp=0x%02X",
                     i, rd[i], 8'(i & 8'hFF));
            all_ok = 1'b0;
            fails++;
          end
        end
        if (all_ok) $display("PASS T20 256-byte payload match");
      end
    end

    // ==============================================================
    // T21: ETH-UDP STREAM_WRITE 256 bytes — ack must come back with status=OK
    // T22: ETH-UDP STREAM_READ 256 bytes — verify all 256 data bytes via Ethernet
    // (Tests MAX_PKT_BYTES >= 265 in udp_xfcp_server)
    // ==============================================================
    $display("--- T21: ETH-UDP STREAM_WRITE 256-byte ---");
    begin
      automatic logic [7:0] req[265];
      automatic logic [7:0] cap[];
      automatic int n;
      automatic logic [7:0] xfcp_sop, xfcp_op, xfcp_seq, xfcp_status;
      // Build: FE 20 seq COUNT_H COUNT_L stream_id[3:0] data[256]
      req[0] = 8'hFE; req[1] = 8'h20; req[2] = 8'hA2;
      req[3] = 8'h01; req[4] = 8'h00;           // COUNT = 256 (0x0100)
      req[5] = 8'h00; req[6] = 8'h00; req[7] = 8'h00; req[8] = 8'h00; // sid=0
      for (int i = 0; i < 256; i++) req[9+i] = 8'(i);
      drive_xfcp_gmii(req, 265);
      capture_gmii_tx(cap, n);
      // STREAM_WRITE ack: preamble(8)+ETH(14)+IP(20)+UDP(8)+XFCP(5) = 55
      chk_bool(n >= 55, "T21.frame_received");
      if (n >= 55) begin
        xfcp_sop    = cap[50]; xfcp_op  = cap[51];
        xfcp_seq    = cap[52]; xfcp_status = cap[53];
        chk_bool(xfcp_sop    == 8'hFD, "T21.xfcp_sop==0xFD");
        chk_bool(xfcp_op     == 8'h22, "T21.xfcp_op==STREAM_WRITE_RESP");
        chk_bool(xfcp_seq    == 8'hA2, "T21.xfcp_seq_echo");
        chk_bool(xfcp_status == 8'h00, "T21.xfcp_status==OK");
      end
    end

    repeat (500) @(posedge clk_i);
    $display("--- T22: ETH-UDP STREAM_READ 256-byte ---");
    begin
      automatic logic [7:0] req[9];
      automatic logic [7:0] cap[];
      automatic int n;
      automatic logic [7:0] xfcp_sop, xfcp_op, xfcp_seq, xfcp_status;
      // Build: FE 21 seq COUNT_H COUNT_L stream_id[3:0]
      req[0] = 8'hFE; req[1] = 8'h21; req[2] = 8'hA3;
      req[3] = 8'h01; req[4] = 8'h00;           // COUNT = 256
      req[5] = 8'h00; req[6] = 8'h00; req[7] = 8'h00; req[8] = 8'h00; // sid=0
      drive_xfcp_gmii(req, 9);
      capture_gmii_tx(cap, n);
      // STREAM_READ resp: preamble(8)+ETH(14)+IP(20)+UDP(8)+XFCP(FD+op+seq+status+256data+term)
      // = 50 + 4 + 256 + 1 = 311 bytes (no FCS in capture)
      chk_bool(n >= 311, "T22.frame_received");
      if (n >= 311) begin
        xfcp_sop    = cap[50]; xfcp_op  = cap[51];
        xfcp_seq    = cap[52]; xfcp_status = cap[53];
        chk_bool(xfcp_sop    == 8'hFD, "T22.xfcp_sop==0xFD");
        chk_bool(xfcp_op     == 8'h23, "T22.xfcp_op==STREAM_READ_RESP");
        chk_bool(xfcp_seq    == 8'hA3, "T22.xfcp_seq_echo");
        chk_bool(xfcp_status == 8'h00, "T22.xfcp_status==OK");
        begin
          logic all_ok;
          all_ok = 1'b1;
          for (int i = 0; i < 256; i++) begin
            if (cap[54+i] !== 8'(i)) begin
              $display("FAIL T22.byte[%0d]: got=0x%02X exp=0x%02X",
                       i, cap[54+i], 8'(i));
              all_ok = 1'b0;
              fails++;
            end
          end
          if (all_ok) $display("PASS T22 256-byte ETH payload match");
        end
      end
    end

    // ==============================================================
    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
