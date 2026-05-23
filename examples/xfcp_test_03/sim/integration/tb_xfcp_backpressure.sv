`timescale 1ns/1ps

// Testbench: xfcp_fabric_endpoint s UART TX backpressure a UART RX timing.
//
// Ciel: reprodukovat HW bug kde striedavo prichadzaju TIMEOUT/SUCCESS odpovede.
//
// Model UART TX: TREADY=0 na BAUD_CYCLES-1 cyklov po kazdom prijatom bajte
//   (simuluje uart_core_tx ktory drzi backpressure pocas serialiazacie).
//
// Model UART RX: BAUD_CYCLES medzicase medzi bajtmi (simuluje prichod cez UART).
//
// Adresna mapa (ta ista ako tb_xfcp_fabric_endpoint):
//   Slave 0 @ 0x00000000  mask 0xFFFFFFC0
//   Slave 1 @ 0x00000040  mask 0xFFFFFFC0
//   Slave 2 @ 0x00000080  mask 0xFFFFFFC0
//   Slave 3 @ 0x000000C0  mask 0xFFFFFFC0
//
// Testy:
//   SETUP: WRITEs (s TX backpressure pre response)
//   T1-T4: Sekvenčné READs po jednom (každý čaká na response pred ďalším)
//          → simuluje scanner sekvenčné skenovanie
//   T5-T8: Back-to-back READs (inject všetkých 4 requestov pred čakanim)
//          → stres test pre ofifo + arbiter + eng_done_cnt
//   T9:    Overenie integrity po stresovom teste
//
// Data ukladane do axil_slave_model musia byt bez 0xFE bajtu.
//
// Run with:
//   vlog -sv -suppress 2892 $(AXI_COMMON) $(XFCP_COMMON) \
//        $(RTL_AXIL)/axil_slave_model.sv \
//        integration/tb_xfcp_backpressure.sv
//   vsim -c -do "run -all; quit" tb_xfcp_backpressure

module tb_xfcp_backpressure;
  import axi_pkg::*;
  import xfcp_pkg::*;

  localparam int NUM_SLAVES  = 4;
  localparam int BAUD_CYCLES = 4340;  // 50 MHz / 115200 * 10 bitov/bajt

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int fails = 0;

  // ── Interfaces ────────────────────────────────────────────────────
  axi4s_if    #(.DATA_WIDTH(8))                   xfcp_in  (.TCLK(clk), .TRESETn(rst_n));
  axi4s_if    #(.DATA_WIDTH(8))                   xfcp_out (.TCLK(clk), .TRESETn(rst_n));
  axi4lite_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) axil_s [NUM_SLAVES]
      (.ACLK(clk), .ARESETn(rst_n));

  // ── DUT ───────────────────────────────────────────────────────────
  xfcp_fabric_endpoint #(
    .NUM_SLAVES     (NUM_SLAVES),
    .AXI_ADDR_WIDTH (32),
    .AXI_DATA_WIDTH (32),
    .ID_STR         ("BP-FABRIC      "),
    .SLAVE_BASE     ('{ 32'h0000_0000, 32'h0000_0040,
                        32'h0000_0080, 32'h0000_00C0 }),
    .SLAVE_MASK     ('{ 32'hFFFF_FFC0, 32'hFFFF_FFC0,
                        32'hFFFF_FFC0, 32'hFFFF_FFC0 })
  ) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .xfcp_in  (xfcp_in.slave),
    .xfcp_out (xfcp_out.master),
    .m_axil   (axil_s)
  );

  // ── AXI memory slaves ──────────────────────────────────────────────
  for (genvar i = 0; i < NUM_SLAVES; i++) begin : g_slave
    axil_slave_model #(.MEM_DEPTH(64)) u_slave (
      .clk   (clk),
      .rstn  (rst_n),
      .s_axil(axil_s[i].slave)
    );
  end : g_slave

  // ── UART TX backpressure model ─────────────────────────────────────
  // Po kazdom prijatom bajte: TREADY=0 na BAUD_CYCLES-1 cyklov.
  // Jeden bajt trvá celkovo BAUD_CYCLES cyklov (1 accept + 4339 busy).
  logic uart_tx_busy;
  int   uart_tx_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      uart_tx_busy <= 1'b0;
      uart_tx_cnt  <= 0;
    end else if (uart_tx_cnt > 0) begin
      uart_tx_cnt <= uart_tx_cnt - 1;
      if (uart_tx_cnt == 1) uart_tx_busy <= 1'b0;
    end else if (xfcp_out.TVALID && !uart_tx_busy) begin
      uart_tx_busy <= 1'b1;
      uart_tx_cnt  <= BAUD_CYCLES - 1;
    end
  end

  assign xfcp_out.TREADY = !uart_tx_busy;

  // ── Response capture ───────────────────────────────────────────────
  logic [7:0]  resp_buf [0:2047];
  int unsigned resp_wptr, resp_rptr;

  initial begin
    resp_wptr = 0;
    resp_rptr = 0;
  end

  always @(posedge clk) begin
    if (rst_n && xfcp_out.TVALID && xfcp_out.TREADY) begin
      resp_buf[resp_wptr & 2047] = xfcp_out.TDATA;
      resp_wptr++;
    end
  end

  // ── Tasks ──────────────────────────────────────────────────────────

  // axis_send: jeden bajt, bez oneskorenia (okamzite, pre setup)
  task automatic axis_send(input logic [7:0] b);
    @(negedge clk);
    xfcp_in.TDATA  = b;
    xfcp_in.TVALID = 1'b1;
    xfcp_in.TLAST  = 1'b0;
    @(posedge clk);
    while (!xfcp_in.TREADY) @(posedge clk);
    @(negedge clk);
    xfcp_in.TVALID = 1'b0;
  endtask

  // uart_send: jeden bajt s UART RX casovanim (BAUD_CYCLES medzi bajtmi)
  task automatic uart_send(input logic [7:0] b);
    axis_send(b);
    repeat(BAUD_CYCLES - 1) @(posedge clk);
  endtask

  // resp_wait: caka kym neziskame n bajt v resp_buf
  task automatic resp_wait(int unsigned n, int unsigned max_cycles = 2_000_000);
    int t = 0;
    while ((resp_wptr - resp_rptr) < n) begin
      @(posedge clk);
      if (++t > int'(max_cycles))
        $fatal(1, "resp_wait(%0d): timeout po %0d cykloch (wptr=%0d rptr=%0d)",
               n, max_cycles, resp_wptr, resp_rptr);
    end
  endtask

  task automatic resp_get(output logic [7:0] b);
    b = resp_buf[resp_rptr & 2047];
    resp_rptr++;
  endtask

  // xfcp_write_fast: WRITE bez UART RX casovani (pre rychly setup)
  // TX backpressure je stale aktivne (WRITE response trva 22*BAUD_CYCLES)
  task automatic xfcp_write_fast(input logic [31:0] addr, input logic [31:0] data);
    axis_send(8'hFE); axis_send(8'h11); axis_send(8'h00);  // SOP OP SEQ
    axis_send(8'h00); axis_send(8'h04);
    axis_send(addr[31:24]); axis_send(addr[23:16]);
    axis_send(addr[15:8]);  axis_send(addr[7:0]);
    axis_send(data[31:24]); axis_send(data[23:16]);
    axis_send(data[15:8]);  axis_send(data[7:0]);
  endtask

  // xfcp_read_uart: READ s UART RX casovanim
  task automatic xfcp_read_uart(input logic [31:0] addr);
    uart_send(8'hFE); uart_send(8'h10); uart_send(8'h00);  // SOP OP SEQ
    uart_send(8'h00); uart_send(8'h04);
    uart_send(addr[31:24]); uart_send(addr[23:16]);
    uart_send(addr[15:8]);  uart_send(addr[7:0]);
  endtask

  // xfcp_read_fast: READ bez UART RX casovani (pre back-to-back testy)
  task automatic xfcp_read_fast(input logic [31:0] addr);
    axis_send(8'hFE); axis_send(8'h10); axis_send(8'h00);  // SOP OP SEQ
    axis_send(8'h00); axis_send(8'h04);
    axis_send(addr[31:24]); axis_send(addr[23:16]);
    axis_send(addr[15:8]);  axis_send(addr[7:0]);
  endtask

  // drain_write_resp: spotrebuje 22 bajtov WRITE response
  // S UART TX backpressure: trva 22*BAUD_CYCLES = 95480 cyklov
  task automatic drain_write_resp();
    resp_wait(22, 200_000);
    resp_rptr += 22;
  endtask

  // recv_read: caka na 26 bajtov READ response a extrahuje data
  // S UART TX backpressure: trva 26*BAUD_CYCLES = 112840 cyklov
  task automatic recv_read(output logic [31:0] rdata, input string label);
    logic [7:0] b;
    resp_wait(26, 200_000);
    resp_rptr += 21;  // preskoc header (SOP+TYPE+SEQ+DEV_TYPE+DEV_STR)
    resp_get(b); rdata[31:24] = b;
    resp_get(b); rdata[23:16] = b;
    resp_get(b); rdata[15:8]  = b;
    resp_get(b); rdata[7:0]   = b;
    resp_get(b);               // terminator
    $display("[BP] recv_read done: %s = 0x%08X", label, rdata);
  endtask

  task automatic chk32(input logic [31:0] got, input logic [31:0] exp, input string lbl);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08X exp=0x%08X", lbl, got, exp);
      fails++;
    end else $display("PASS %s: 0x%08X", lbl, got);
  endtask

  // ── Stimulus ───────────────────────────────────────────────────────
  logic [31:0] rdata;
  logic [31:0] rdata1, rdata2, rdata3, rdata4;

  initial begin
    xfcp_in.TDATA  = 8'h00;
    xfcp_in.TVALID = 1'b0;
    xfcp_in.TLAST  = 1'b0;
    xfcp_in.TKEEP  = '1;
    xfcp_in.TUSER  = '0;
    xfcp_in.TID    = '0;
    xfcp_in.TDEST  = '0;

    rst_n = 1'b0;
    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);

    // ── SETUP: WRITEs do vsetkych 4 slavov ───────────────────────
    // TX backpressure aktivne → kazda WRITE response trva ~91K cyklov.
    // Data bez 0xFE bajtov.
    xfcp_write_fast(32'h0000_0004, 32'hDEAD_BEEF);  // slave 0
    drain_write_resp();
    xfcp_write_fast(32'h0000_0044, 32'h1234_5678);  // slave 1
    drain_write_resp();
    xfcp_write_fast(32'h0000_0084, 32'hABCD_0001);  // slave 2
    drain_write_resp();
    xfcp_write_fast(32'h0000_00C4, 32'h9876_DCBA);  // slave 3
    drain_write_resp();
    $display("[BP] SETUP komplet: 4 slovy zapisane.");

    // ── T1-T4: Sekvenčné READs (UART RX timing + TX backpressure) ─
    // Kazdy READ caka na response pred odoslanim dalsieho.
    // Simuluje HW scanner: sekvenčne skenovanie 4 slavov.
    // Celkovy cas: 4 * (34720 + 108500) ~= 573K cyklov ~= 11.5 ms

    xfcp_read_uart(32'h0000_0004);  // slave 0
    recv_read(rdata, "T1");
    chk32(rdata, 32'hDEAD_BEEF, "T1 slave0 UART-timed READ");

    xfcp_read_uart(32'h0000_0044);  // slave 1
    recv_read(rdata, "T2");
    chk32(rdata, 32'h1234_5678, "T2 slave1 UART-timed READ");

    xfcp_read_uart(32'h0000_0084);  // slave 2
    recv_read(rdata, "T3");
    chk32(rdata, 32'hABCD_0001, "T3 slave2 UART-timed READ");

    xfcp_read_uart(32'h0000_00C4);  // slave 3
    recv_read(rdata, "T4");
    chk32(rdata, 32'h9876_DCBA, "T4 slave3 UART-timed READ");

    $display("[BP] T1-T4 PASS: sekvenčné READs OK.");

    // ── T5-T8: Back-to-back READs (injectuj pred cakаnim) ─────────
    // Odosle vsetky 4 READ requesty rychlo (bez UART RX cakania).
    // Packetizer odosila response 1 (108500 cyklov) zatial co
    // request 2, 3, 4 su uz parsovane a cakaju v ofifo.
    // Testuje: eng_done_cnt, arbiter sequencing, rfifo izolaciu.
    // In-order responses ocakavame: slave0, slave1, slave2, slave3.

    xfcp_read_fast(32'h0000_0004);  // slave 0 – odoslane okamzite
    xfcp_read_fast(32'h0000_0044);  // slave 1 – pred prijatim response 0!
    xfcp_read_fast(32'h0000_0084);  // slave 2
    xfcp_read_fast(32'h0000_00C4);  // slave 3

    recv_read(rdata1, "T5 slave0");
    recv_read(rdata2, "T6 slave1");
    recv_read(rdata3, "T7 slave2");
    recv_read(rdata4, "T8 slave3");

    chk32(rdata1, 32'hDEAD_BEEF, "T5 back-to-back slave0");
    chk32(rdata2, 32'h1234_5678, "T6 back-to-back slave1");
    chk32(rdata3, 32'hABCD_0001, "T7 back-to-back slave2");
    chk32(rdata4, 32'h9876_DCBA, "T8 back-to-back slave3");

    $display("[BP] T5-T8: back-to-back READs vyhodnotene.");

    // ── T9: Overenie po stresovom teste – opakuj sekvenčné READs ──
    // Ak T5-T8 poskazilo stav (napr. zla rdata v ofifo), T9 to odhali.

    xfcp_read_uart(32'h0000_0004);
    recv_read(rdata, "T9");
    chk32(rdata, 32'hDEAD_BEEF, "T9 post-stress slave0 READ");

    xfcp_read_uart(32'h0000_0044);
    recv_read(rdata, "T10");
    chk32(rdata, 32'h1234_5678, "T10 post-stress slave1 READ");

    // ── Celkový výsledok ──────────────────────────────────────────
    $display("");
    $display("%s (%0d failure%s)",
      fails == 0 ? "ALL PASSED" : "FAILURES DETECTED",
      fails, fails == 1 ? "" : "s");
    if (fails != 0) $fatal(1);
    $finish;
  end

endmodule
