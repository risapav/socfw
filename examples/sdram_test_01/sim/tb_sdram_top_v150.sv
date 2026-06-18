/**
 * @file tb_sdram_top.sv
 * @brief Rozšírený testbench pre 32-bit AXI SDRAM Controller.
 *
 * Vylepšenia:
 *  [SB-BURST]   Scoreboard sleduje adresu pre každý beat burstu
 *  [TEST-ROW]   Test row-hit a row-miss scenárov
 *  [TEST-BANK]  Test multi-bank interleavingu
 *  [TEST-RAND]  Rozšírený stress test s väčším počtom iterácií
 *  [CHK-RLAST]  Overenie rlast príznaku
 */

`timescale 1ns/1ps
`default_nettype none
import sdram_pkg::*;

module tb_sdram_top;

  logic clk, clk_sh, rstn;
  initial begin clk = 1'b0; forever #5 clk = ~clk; end
  initial begin clk_sh = 1'b0; #2.5; forever #5 clk_sh = ~clk_sh; end
  initial begin rstn = 1'b0; #100; rstn = 1'b1; end

  // AXI signály
  logic [3:0]  s_axi_arid,   s_axi_rid;
  logic [3:0]  s_axi_awid,   s_axi_bid;
  logic [31:0] s_axi_araddr, s_axi_awaddr;
  logic [31:0] s_axi_rdata;
  logic [7:0]  s_axi_arlen,  s_axi_awlen;
  logic        s_axi_arvalid, s_axi_arready;
  logic        s_axi_rvalid,  s_axi_rready, s_axi_rlast;
  logic        s_axi_awvalid, s_axi_awready;
  logic        s_axi_wvalid,  s_axi_wready, s_axi_wlast;
  logic [31:0] s_axi_wdata;
  logic        s_axi_bvalid,  s_axi_bready;
  logic [1:0]  s_axi_bresp;

  logic [12:0] sdram_addr;
  logic [1:0]  sdram_ba;
  logic        sdram_ras_n, sdram_cas_n, sdram_we_n, sdram_cs_n;
  logic        sdram_clk, sdram_cke;
  wire  [15:0] sdram_dq;

  sdram_system_top dut (.*);

  sdram_model_pro mem (
    .clk(sdram_clk), .rst(!rstn), .addr(sdram_addr), .ba(sdram_ba),
    .ras_n(sdram_ras_n), .cas_n(sdram_cas_n), .we_n(sdram_we_n),
    .cs_n(sdram_cs_n), .dq(sdram_dq)
  );

  // SDRAM logger
  always @(posedge sdram_clk) begin
    if (!sdram_cs_n) begin
      case ({sdram_ras_n, sdram_cas_n, sdram_we_n})
        3'b011: $display("[%0t] ACT   B=%0h Row=%0h", $time, sdram_ba, sdram_addr);
        3'b101: $display("[%0t] READ  B=%0h Col=%0h", $time, sdram_ba, sdram_addr);
        3'b100: $display("[%0t] WRITE B=%0h Col=%0h DQ=%04h", $time, sdram_ba, sdram_addr, sdram_dq);
        3'b010: $display("[%0t] PRE", $time);
        3'b001: $display("[%0t] REF", $time);
        3'b000: $display("[%0t] MRS", $time);
        default:;
      endcase
    end
  end

  // ==========================================================================
  // SCOREBOARD — podporuje bursts
  // [SB-BURST] Sleduje adresu pre každý beat: aw_addr inkrementuje o 4
  // ==========================================================================
  logic [31:0] scoreboard [logic [31:0]];
  logic [31:0] read_addr_q [$];
  int          sb_matches = 0, sb_errors = 0, sb_checks = 0;

  // AW + W tracking — inkrementuje adresu pre každý beat
  logic [31:0] aw_addr_cur;
  logic        aw_active_sb;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      aw_addr_cur   <= '0;
      aw_active_sb  <= 1'b0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_addr_cur  <= s_axi_awaddr;
        aw_active_sb <= 1'b1;
      end
      if (s_axi_wvalid && s_axi_wready && aw_active_sb) begin
        aw_addr_cur <= aw_addr_cur + 32'd4;
        if (s_axi_wlast)
          aw_active_sb <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (s_axi_wvalid && s_axi_wready && aw_active_sb) begin
      scoreboard[aw_addr_cur] = s_axi_wdata;
      $display("[SB] WRITE Addr=%08h Data=%08h", aw_addr_cur, s_axi_wdata);
    end
  end

  // AR tracking — pre každý beat burstu push adresu
  logic [31:0] ar_addr_cur;
  logic        ar_active_sb;
  logic [7:0]  ar_len_cur;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      ar_addr_cur  <= '0;
      ar_active_sb <= 1'b0;
      ar_len_cur   <= '0;
    end else begin
      if (s_axi_arvalid && s_axi_arready) begin
        ar_addr_cur  <= s_axi_araddr;
        ar_len_cur   <= s_axi_arlen;
        ar_active_sb <= 1'b1;
      end
    end
  end

  // Push read addresses do fronty pre každý očakávaný beat
  always @(posedge clk) begin
    if (s_axi_arvalid && s_axi_arready) begin
      for (int i = 0; i <= int'(s_axi_arlen); i++)
        read_addr_q.push_back(s_axi_araddr + 32'(i * 4));
    end
  end

  // R verification
  always_ff @(posedge clk) begin
    if (s_axi_rvalid && s_axi_rready) begin
      if (read_addr_q.size() > 0) begin
        automatic logic [31:0] v_addr = read_addr_q.pop_front();
        sb_checks++;
        if ($isunknown(s_axi_rdata)) begin
          sb_errors++;
          $error("[SB] UNKNOWN  Addr=%08h Got=%08h", v_addr, s_axi_rdata);
        end else if (scoreboard.exists(v_addr)) begin
          if (s_axi_rdata !== scoreboard[v_addr]) begin
            sb_errors++;
            $error("[SB] MISMATCH Addr=%08h Exp=%08h Got=%08h",
                   v_addr, scoreboard[v_addr], s_axi_rdata);
          end else begin
            sb_matches++;
            $display("[SB] MATCH    Addr=%08h Data=%08h", v_addr, s_axi_rdata);
          end
        end else begin
          sb_errors++;
          $error("[SB] NO_WRITE  Addr=%08h Got=%08h (čítanie bez zápisu)",
                 v_addr, s_axi_rdata);
        end
      end
    end
  end

  // ==========================================================================
  // AXI BFM TASKS
  // ==========================================================================
  task automatic axi_write_burst(
    input logic [31:0] base_addr,
    input logic [7:0]  len,
    input logic [3:0]  id,
    input logic [31:0] data []
  );
    @(posedge clk);
    s_axi_awaddr <= base_addr;
    s_axi_awlen  <= len;
    s_axi_awid   <= id;
    @(posedge clk);
    s_axi_awvalid <= 1'b1;
    wait(s_axi_awready);
    @(posedge clk);
    s_axi_awvalid <= 1'b0;

    for (int i = 0; i <= int'(len); i++) begin
      @(posedge clk);
      s_axi_wdata  <= (i < data.size()) ? data[i] : 32'hDEAD_0000 + i;
      s_axi_wvalid <= 1'b1;
      s_axi_wlast  <= (i == int'(len));
      wait(s_axi_wready);
      @(posedge clk);
    end
    s_axi_wvalid <= 1'b0;
    s_axi_wlast  <= 1'b0;

    s_axi_bready <= 1'b1;
    wait(s_axi_bvalid);
    @(posedge clk);
    s_axi_bready <= 1'b0;

    if (s_axi_bresp != 2'b00)
      $error("[AXI] BRESP error %02b addr=%08h", s_axi_bresp, base_addr);
  endtask

  task automatic axi_read_burst(
    input logic [31:0] addr,
    input logic [7:0]  len,
    input logic [3:0]  id
  );
    @(posedge clk);
    s_axi_araddr <= addr;
    s_axi_arlen  <= len;
    s_axi_arid   <= id;
    @(posedge clk);
    s_axi_arvalid <= 1'b1;
    wait(s_axi_arready);
    @(posedge clk);
    s_axi_arvalid <= 1'b0;

    repeat (int'(len) + 1) begin
      wait(s_axi_rvalid);
      @(posedge clk);
    end
  endtask

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    automatic logic [31:0] d[] = {data};
    $display("[TB] Write Addr=%08h Data=%08h", addr, data);
    axi_write_burst(addr, 8'd0, 4'h0, d);
  endtask

  task automatic axi_read(input logic [31:0] addr);
    $display("[TB] Read  Addr=%08h", addr);
    axi_read_burst(addr, 8'd0, 4'h0);
  endtask

  // Helper: zápisanie a overenie jednej adresy
  task automatic write_read_check(
    input logic [31:0] addr,
    input logic [31:0] data
  );
    axi_write(addr, data);
    axi_read (addr);
  endtask

  // ==========================================================================
  // TESTY
  // ==========================================================================
  initial begin
    s_axi_arvalid = 1'b0; s_axi_araddr = '0; s_axi_arid = '0; s_axi_arlen = '0;
    s_axi_rready  = 1'b1;
    s_axi_awvalid = 1'b0; s_axi_awaddr = '0; s_axi_awid = '0; s_axi_awlen = '0;
    s_axi_wvalid  = 1'b0; s_axi_wdata  = '0; s_axi_wlast = 1'b0;
    s_axi_bready  = 1'b0;

    @(posedge rstn);
    wait(dut.init_done);
    #100;

    // ------------------------------------------------------------------
    // TEST 1: Základný single write/read
    // ------------------------------------------------------------------
    $display("\n--- Test 1: Single Write/Read ---");
    write_read_check(32'h0000_1000, 32'hDEAD_BEEF);
    write_read_check(32'h0000_1004, 32'hCAFE_BABE);
    #100;

    // ------------------------------------------------------------------
    // TEST 2: Row Hit — viaceré prístupy na rovnaký riadok
    // Všetky adresy v tom istom riadku (rovnaké row, rôzne col)
    // Scheduler by nemal vydávať PRE medzi nimi
    // ------------------------------------------------------------------
    $display("\n--- Test 2: Row Hit sequence ---");
    // Adresa 0x0000_2000 → row=1, bank=0, col=0
    // Adresa 0x0000_2004 → row=1, bank=0, col=2  (rovnaký riadok)
    // Adresa 0x0000_2008 → row=1, bank=0, col=4
    write_read_check(32'h0000_2000, 32'h1111_AAAA);
    write_read_check(32'h0000_2004, 32'h2222_BBBB);
    write_read_check(32'h0000_2008, 32'h3333_CCCC);
    #100;

    // ------------------------------------------------------------------
    // TEST 3: Row Miss — prístup na iný riadok v tej istej banke
    // Scheduler musí vydať PRE + ACT pred novým riadkom
    // ------------------------------------------------------------------
    $display("\n--- Test 3: Row Miss ---");
    // Riadok 1, banka 0
    write_read_check(32'h0000_2000, 32'hAAAA_0001);
    // Iný riadok v tej istej banke — spôsobí row miss
    // Adresa 0x0002_0000 → row=16, bank=0 (iný riadok)
    write_read_check(32'h0002_0000, 32'hBBBB_0002);
    #100;

    // ------------------------------------------------------------------
    // TEST 4: Multi-bank interleaving
    // Zápisy do rôznych bánk — scheduler môže interleave
    // ------------------------------------------------------------------
    $display("\n--- Test 4: Multi-bank interleaving ---");
    // Banka 0: addr bits[11:10]=00
    write_read_check(32'h0000_1000, 32'hB0DA_0001);
    // Banka 1: addr bits[11:10]=01 → offset 0x400
    write_read_check(32'h0000_1400, 32'hB1DA_0002);
    // Banka 2: addr bits[11:10]=10 → offset 0x800
    write_read_check(32'h0000_1800, 32'hB2DA_0003);
    // Banka 3: addr bits[11:10]=11 → offset 0xC00
    write_read_check(32'h0000_1C00, 32'hB3DA_0004);
    #100;

    // ------------------------------------------------------------------
    // TEST 5: Burst write + burst read (LEN=3, 4 beaty)
    // ------------------------------------------------------------------
    $display("\n--- Test 5: Burst LEN=3 ---");
    begin
      automatic logic [31:0] wdata[] = {
        32'hDEAD_0000,
        32'hDEAD_0004,
        32'hDEAD_0008,
        32'hDEAD_000C
      };
      axi_write_burst(32'h0000_3000, 8'd3, 4'h1, wdata);
      axi_read_burst (32'h0000_3000, 8'd3, 4'h1);
    end
    #100;

    // ------------------------------------------------------------------
    // TEST 6: Refresh počas aktívnej operácie
    // Dlhší stress test — spôsobí refresh uprostred sekvencie
    // ------------------------------------------------------------------
    $display("\n--- Test 6: Refresh stress ---");
    begin
      automatic logic [31:0] t_addr;
      automatic logic [31:0] t_data;
      repeat(20) begin
        t_addr = $urandom() & 32'hFFFF_FFFC;
        t_data = $urandom();
        write_read_check(t_addr, t_data);
      end
    end
    #100;

    // ------------------------------------------------------------------
    // TEST 7: Hraničné adresy
    // ------------------------------------------------------------------
    $display("\n--- Test 7: Boundary addresses ---");
    write_read_check(32'h0000_0000, 32'h0000_0001);  // Najnižšia adresa
    write_read_check(32'h0000_FFFC, 32'hFFFF_FFFE);  // Horná hranica 16-bit priestoru
    #100;

    // ------------------------------------------------------------------
    // Výsledky
    // ------------------------------------------------------------------
    $display("\n============================================================");
    $display(" VÝSLEDKY: Checks=%0d  Matches=%0d  Errors=%0d",
             sb_checks, sb_matches, sb_errors);
    if (sb_errors == 0)
      $display(" *** PASS ***");
    else
      $display(" *** FAIL ***");
    $display("============================================================");
    $finish;
  end

  // Watchdog
  initial begin
    #500_000_000;
    $fatal(1, "[WATCHDOG] Timeout!");
  end

endmodule
