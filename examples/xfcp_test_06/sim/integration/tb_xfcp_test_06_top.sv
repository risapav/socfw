`timescale 1ns/1ps

// tb_xfcp_test_06_top -- integration test for xfcp_test_06_top (v0.9+STATUS).
//
// Overuje UART XFCP cestu (T1-T10) a ETH-UDP XFCP cestu (T11-T12).
//
// Zmeny oproti tb_xfcp_test_05_top:
//   - drain_write_resp: 22 -> 5 bajtov (SOP+TYPE+SEQ+STATUS+TERM)
//   - recv_read: po SEQ sa cita 1 STATUS bajt (nie 18 DEV_TYPE+DEV_STR)
//     a kontroluje sa STATUS == 0x00
//   - T11/T12: kontrola cap[53] == 0x00 (STATUS byte v 4-bajtovom headeri)
//   - T11 frame check: n >= 59 (namiesto 76)
//   - T12 frame check: n >= 55 (namiesto 72)
//
// XFCP v0.9+STATUS response format:
//   Bajt 0: SOP_RESP (0xFD)
//   Bajt 1: TYPE (0x12=READ, 0x13=WRITE)
//   Bajt 2: SEQ (echo)
//   Bajt 3: STATUS (0x00=OK, 0x04=SLVERR, ...)
//   Bajt 4+: PAYLOAD (len pre READ)
//   end:     0x00 + TLAST

module tb_xfcp_test_06_top;
  import tb_eth_pkg::*;

  // BAUD_DIV=32: uart_fifo_os potebuje PRESCALE_RX_OS>=2 -> min BAUD_DIV=32
  localparam int BAUD_DIV    = 32;
  localparam int CLOCK_HZ    = 1000;

  localparam logic [47:0] PC_MAC        = 48'hAA_BB_CC_DD_EE_FF;
  localparam logic [31:0] PC_IP         = 32'hC0A8_0064;
  localparam logic [15:0] PC_SPORT      = 16'h1234;
  localparam logic [47:0] DUT_MAC       = 48'h00_0A_35_01_FE_C5;
  localparam logic [31:0] DUT_IP        = 32'hC0A8_0005;
  localparam logic [15:0] XFCP_UDP_PORT = 16'hC350;  // 50000

  // =========================================================================
  // Clocks
  // =========================================================================
  logic clk_i, eth_rx_clk_i;
  logic rst_ni;

  initial clk_i = 1'b0;
  always  #5  clk_i = ~clk_i;

  initial eth_rx_clk_i = 1'b0;
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
  // DUT
  // =========================================================================
  xfcp_test_06_top #(
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
  logic [7:0] rx_buf [0:63];
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
      rx_buf[rx_wptr & 63] = cap;
      rx_wptr++;
      repeat (BAUD_DIV) @(posedge clk_i);
    end
  end

  // =========================================================================
  // Test helpers
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

  task automatic chk_bool(input logic cond, input string lbl);
    if (!cond) begin $display("FAIL %s", lbl); fails++; end
    else             $display("PASS %s", lbl);
  endtask

  // =========================================================================
  // UART send/receive
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
      if (timeout_cnt > 500_000)
        $fatal(1, "uart_recv timeout -- DUT did not respond");
    end
    b = rx_buf[rx_rptr & 63];
    rx_rptr++;
  endtask

  // =========================================================================
  // XFCP UART request helpers
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

  // Drains WRITE response: SOP(1)+TYPE(1)+SEQ(1)+STATUS(1)+TERM(1) = 5 bytes
  task automatic drain_write_resp();
    logic [7:0] b;
    for (int i = 0; i < 5; i++) uart_recv(b);
    repeat (3000) @(posedge clk_i);
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

  // READ response: SOP(1)+TYPE(1)+SEQ(1)+STATUS(1)+DATA(4)+TERM(1) = 9 bytes
  task automatic recv_read(output logic [31:0] rdata);
    logic [7:0] b;
    uart_recv(b);  // SOP_RESP = 0xFD
    if (b !== 8'hFD)
      $display("WARN recv_read: expected SOP_RESP=0xFD, got 0x%02X", b);
    uart_recv(b);  // OP = 0x12
    if (b !== 8'h12)
      $display("WARN recv_read: expected OP=0x12, got 0x%02X", b);
    uart_recv(b);  // SEQ echo
    uart_recv(b);  // STATUS -- must be 0x00 (XFCP_ST_OK)
    if (b !== 8'h00)
      $display("WARN recv_read: STATUS=0x%02X (expected 0x00=OK)", b);
    uart_recv(b); rdata[31:24] = b;
    uart_recv(b); rdata[23:16] = b;
    uart_recv(b); rdata[15:8]  = b;
    uart_recv(b); rdata[7:0]   = b;
    uart_recv(b); // terminator 0x00
    repeat (3000) @(posedge clk_i);
  endtask

  // =========================================================================
  // ETH helpers
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

    ip_hdr[ 0] = 8'h45;                    ip_hdr[ 1] = 8'h00;
    ip_hdr[ 2] = n_ip_total[15:8];         ip_hdr[ 3] = n_ip_total[7:0];
    ip_hdr[ 4] = 8'h00;                    ip_hdr[ 5] = 8'h01;
    ip_hdr[ 6] = 8'h00;                    ip_hdr[ 7] = 8'h00;
    ip_hdr[ 8] = 8'h40;                    ip_hdr[ 9] = 8'h11;
    ip_hdr[10] = 8'h00;                    ip_hdr[11] = 8'h00;
    ip_hdr[12] = PC_IP[31:24];             ip_hdr[13] = PC_IP[23:16];
    ip_hdr[14] = PC_IP[15:8];              ip_hdr[15] = PC_IP[7:0];
    ip_hdr[16] = DUT_IP[31:24];            ip_hdr[17] = DUT_IP[23:16];
    ip_hdr[18] = DUT_IP[15:8];             ip_hdr[19] = DUT_IP[7:0];
    chk = ip_chk(ip_hdr);
    ip_hdr[10] = chk[15:8];
    ip_hdr[11] = chk[7:0];

    udp_hdr[0] = PC_SPORT[15:8];           udp_hdr[1] = PC_SPORT[7:0];
    udp_hdr[2] = XFCP_UDP_PORT[15:8];      udp_hdr[3] = XFCP_UDP_PORT[7:0];
    udp_hdr[4] = udp_total[15:8];          udp_hdr[5] = udp_total[7:0];
    udp_hdr[6] = 8'h00;                    udp_hdr[7] = 8'h00;

    n_frame = 14 + 20 + 8 + n_pay;
    frame   = new[n_frame];
    for (int i = 0; i < 14;    i++) frame[i]      = eth_hdr[i];
    for (int i = 0; i < 20;    i++) frame[14+i]   = ip_hdr[i];
    for (int i = 0; i < 8;     i++) frame[34+i]   = udp_hdr[i];
    for (int i = 0; i < n_pay; i++) frame[42+i]   = xfcp_pay[i];

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

    // -- T1: WRITE 0x3F to LED (slot 2, offset 0x04) ------------------------
    xfcp_write(32'hFF02_0004, 32'h0000_003F);
    drain_write_resp();
    chk32(32'(led_o), 32'h3F, "T1 led_o after write 0x3F");

    // -- T2: READ LED register back -----------------------------------------
    xfcp_read(32'hFF02_0004);
    recv_read(rdata);
    chk32(rdata, 32'h0000_003F, "T2 LED readback");

    // -- T3: SYSC COMPONENT_ID = "SYSC" = 0x5359_5343 ----------------------
    xfcp_read(32'hFF00_0000, 8'h03);
    recv_read(rdata);
    chk32(rdata, 32'h5359_5343, "T3 SYSC COMPONENT_ID");

    // -- T4: UART adapter COMPONENT_ID = "UART" = 0x5541_5254 --------------
    xfcp_read(32'hFF01_0000, 8'h04);
    recv_read(rdata);
    chk32(rdata, 32'h5541_5254, "T4 UART COMPONENT_ID");

    // -- T5: LED axil_regs COMPONENT_ID = "OUT_" = 0x4F55_545F -------------
    xfcp_read(32'hFF02_0000, 8'h05);
    recv_read(rdata);
    chk32(rdata, 32'h4F55_545F, "T5 LED COMPONENT_ID");

    // -- T6: PMOD J10 COMPONENT_ID = "OUT_" --------------------------------
    xfcp_read(32'hFF03_0000, 8'h06);
    recv_read(rdata);
    chk32(rdata, 32'h4F55_545F, "T6 J10 COMPONENT_ID");

    // -- T7: PMOD J11 COMPONENT_ID = "OUT_" --------------------------------
    xfcp_read(32'hFF04_0000, 8'h07);
    recv_read(rdata);
    chk32(rdata, 32'h4F55_545F, "T7 J11 COMPONENT_ID");

    // -- T8: SEG7 adapter COMPONENT_ID = "SEG7" = 0x5345_4737 -------------
    xfcp_read(32'hFF05_0000, 8'h08);
    recv_read(rdata);
    chk32(rdata, 32'h5345_4737, "T8 SEG7 COMPONENT_ID");

    // -- T9: DIAG ctrl COMPONENT_ID = "DIAG" = 0x4449_4147 ----------------
    xfcp_read(32'hFF06_0000, 8'h09);
    recv_read(rdata);
    chk32(rdata, 32'h4449_4147, "T9 DIAG COMPONENT_ID");

    // -- T10: WRITE 0 to LED, verify clear ---------------------------------
    xfcp_write(32'hFF02_0004, 32'h0000_0000, 8'h0A);
    drain_write_resp();
    chk32(32'(led_o), 32'h0, "T10 led_o cleared");

    // ======================================================================
    // ETH-UDP XFCP tests (T11-T12)
    //
    // Frame layout captured on GMII TX (preamble included):
    //   bytes  0- 6 : preamble (0x55)
    //   byte   7    : SFD (0xD5)
    //   bytes  8-13 : ETH dst_mac
    //   bytes 14-19 : ETH src_mac
    //   bytes 20-21 : ethertype (0x0800)
    //   bytes 22-41 : IPv4 header
    //   bytes 42-43 : UDP src_port (XFCP_UDP_PORT)
    //   bytes 44-45 : UDP dst_port (PC_SPORT)
    //   bytes 46-47 : UDP length
    //   bytes 48-49 : UDP checksum
    //   bytes 50+   : XFCP response (4-byte header: SOP/TYPE/SEQ/STATUS)
    // ======================================================================

    // -- T11: ETH XFCP READ of SYSC COMPONENT_ID --------------------------
    $display("--- T11: ETH-UDP XFCP READ SYSC ---");
    begin
      automatic logic [7:0] req[9] = '{
        8'hFE, 8'h10, 8'hBB, 8'h00, 8'h04, 8'hFF, 8'h00, 8'h00, 8'h00
      };
      automatic logic [7:0] cap[];
      automatic int n;
      automatic logic [47:0] got_dst_mac;
      automatic logic [15:0] got_etype;
      automatic logic [15:0] got_udp_src, got_udp_dst;
      automatic logic [7:0]  xfcp_sop, xfcp_op, xfcp_seq, xfcp_status;

      drive_xfcp_gmii(req, 9);
      capture_gmii_tx(cap, n);

      // Minimum: preamble(8)+ETH(14)+IPv4(20)+UDP(8)+XFCP_HDR(4)+DATA(4)+TERM(1) = 59
      chk_bool(n >= 59, "T11.frame_received");
      if (n >= 59) begin
        got_dst_mac = {cap[8], cap[9], cap[10], cap[11], cap[12], cap[13]};
        got_etype   = {cap[20], cap[21]};
        chk_bool(got_dst_mac == PC_MAC,   "T11.dst_mac==PC_MAC");
        chk_bool(got_etype   == 16'h0800, "T11.ethertype==0x0800");
        got_udp_src = {cap[42], cap[43]};
        got_udp_dst = {cap[44], cap[45]};
        chk_bool(got_udp_src == XFCP_UDP_PORT, "T11.udp_src==50000");
        chk_bool(got_udp_dst == PC_SPORT,       "T11.udp_dst==PC_SPORT");
        xfcp_sop    = cap[50];
        xfcp_op     = cap[51];
        xfcp_seq    = cap[52];
        xfcp_status = cap[53];
        chk_bool(xfcp_sop    == 8'hFD, "T11.xfcp_sop==0xFD");
        chk_bool(xfcp_op     == 8'h12, "T11.xfcp_op==READ_RESP");
        chk_bool(xfcp_seq    == 8'hBB, "T11.xfcp_seq_echo");
        chk_bool(xfcp_status == 8'h00, "T11.xfcp_status==OK");
      end
    end

    // -- T12: ETH XFCP WRITE to LED register, verify led_o ----------------
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
        xfcp_sop    = cap[50];
        xfcp_op     = cap[51];
        xfcp_seq    = cap[52];
        xfcp_status = cap[53];
        chk_bool(xfcp_sop    == 8'hFD, "T12.xfcp_sop==0xFD");
        chk_bool(xfcp_op     == 8'h13, "T12.xfcp_op==WRITE_RESP");
        chk_bool(xfcp_seq    == 8'hCC, "T12.xfcp_seq_echo");
        chk_bool(xfcp_status == 8'h00, "T12.xfcp_status==OK");
      end
      repeat (50) @(posedge clk_i);
      chk32(32'(led_o), 32'h15, "T12.led_o==0x15");
    end

    // ======================================================================
    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
