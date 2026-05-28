`timescale 1ns/1ps

// Unit test: udp_tx_stream_to_ram
//
// T1: 4-bajtovy payload — presne jedno slovo (adresa 1)
// T2: 5-bajtovy payload — ciastocne druhe slovo, zero-pad
// T3: tx_data_length_o a tx_total_length_o vypocet
// T4: tx_start_o je 1-cyklovy pulz

module tb_tx_stream;

  int fail_count = 0;

  logic        clk = 0;
  logic        rst_ni;
  logic        start;
  logic        valid;
  logic        ready;
  logic [7:0]  data;
  logic        last;
  logic [8:0]  ram_wr_addr;
  logic [31:0] ram_wr_data;
  logic        ram_wr_we;
  logic        tx_start;
  logic [15:0] tx_data_length;
  logic [15:0] tx_total_length;
  logic        idle;
  logic        tx_busy = 0;

  always #4 clk = ~clk;

  udp_tx_stream_to_ram dut (
    .clk_i             (clk),
    .rst_ni            (rst_ni),
    .start_i           (start),
    .valid_i           (valid),
    .ready_o           (ready),
    .data_i            (data),
    .last_i            (last),
    .ram_wr_addr_o     (ram_wr_addr),
    .ram_wr_data_o     (ram_wr_data),
    .ram_wr_we_o       (ram_wr_we),
    .tx_start_o        (tx_start),
    .tx_data_length_o  (tx_data_length),
    .tx_total_length_o (tx_total_length),
    .idle_o            (idle),
    .tx_busy_i         (tx_busy)
  );

  // Zaznamenaj RAM zapisy
  logic [31:0] ram_capture [0:511];
  always @(posedge clk) begin
    if (ram_wr_we) ram_capture[ram_wr_addr] <= ram_wr_data;
  end

  task automatic chk32(input string tag, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%08x exp=0x%08x", tag, got, exp);
      fail_count++;
    end else
      $display("PASS %s: 0x%08x", tag, got);
  endtask

  task automatic chk16(input string tag, input logic [15:0] got, input logic [15:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got=0x%04x exp=0x%04x", tag, got, exp);
      fail_count++;
    end else
      $display("PASS %s: 0x%04x", tag, got);
  endtask

  task automatic send_bytes(input byte unsigned bytes[], input int nbytes);
    for (int i = 0; i < nbytes; i++) begin
      valid = 1'b1;
      data  = bytes[i];
      last  = (i == nbytes - 1);
      @(posedge clk); while (!ready) @(posedge clk);
      #1;
    end
    valid = 1'b0;
    last  = 1'b0;
  endtask

  initial begin
    rst_ni = 0; start = 0; valid = 0; data = 0; last = 0;
    for (int i = 0; i < 512; i++) ram_capture[i] = 0;
    repeat (4) @(posedge clk); #1;
    rst_ni = 1;
    repeat (2) @(posedge clk); #1;

    // ----------------------------------------------------------------
    // T1: 4 bajty: AA BB CC DD — jedno slovo na adrese 1
    // ----------------------------------------------------------------
    $display("-- T1: 4-bajtovy payload --");
    begin
      automatic byte unsigned p4[4] = '{8'hAA, 8'hBB, 8'hCC, 8'hDD};
      start = 1; @(posedge clk); #1; start = 0;
      send_bytes(p4, 4);
    end
    // Cakaj na tx_start
    repeat (4) @(posedge clk); #1;
    chk32("T1 word@1", ram_capture[1], 32'hAABBCCDD);

    // ----------------------------------------------------------------
    // T2: 5 bajtov: 11 22 33 44 55 — 2 slova, druhe ciastocne
    // ----------------------------------------------------------------
    $display("-- T2: 5-bajtovy payload --");
    begin
      automatic byte unsigned p5[5] = '{8'h11, 8'h22, 8'h33, 8'h44, 8'h55};
      start = 1; @(posedge clk); #1; start = 0;
      send_bytes(p5, 5);
    end
    repeat (4) @(posedge clk); #1;
    chk32("T2 word@1", ram_capture[1], 32'h11223344);
    chk32("T2 word@2", ram_capture[2], 32'h55000000);

    // ----------------------------------------------------------------
    // T3: dlzky pre 5-bajtovy payload
    // ----------------------------------------------------------------
    $display("-- T3: tx_data/total length --");
    chk16("T3 tx_data_length",  tx_data_length,  16'd13);
    chk16("T3 tx_total_length", tx_total_length, 16'd33);

    // ----------------------------------------------------------------
    // T4: tx_start je 1-cyklovy pulz
    // ----------------------------------------------------------------
    $display("-- T4: tx_start pulse width --");
    begin
      automatic int pulse_count = 0;
      automatic byte unsigned p1[1] = '{8'hAB};
      start = 1; @(posedge clk); #1; start = 0;
      send_bytes(p1, 1);
      // Cakaj max 10 cyklov na pulz
      for (int c = 0; c < 10; c++) begin
        @(posedge clk); #1;
        if (tx_start) pulse_count++;
      end
      if (pulse_count == 1)
        $display("PASS T4 tx_start pulse: 1 cycle");
      else begin
        $display("FAIL T4 tx_start pulse: %0d cycles", pulse_count);
        fail_count++;
      end
    end

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
