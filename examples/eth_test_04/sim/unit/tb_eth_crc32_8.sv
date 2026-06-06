`timescale 1ns/1ps
/**
 * @file tb_eth_crc32_8.sv
 * @brief Unit test: eth_crc32_8 combinatorial CRC32 wrapper.
 * @details Tests:
 *   T1: "123456789" -> CRC32 = 32'hCBF43926  (ISO 3309 standard vector)
 *   T2: Single all-zero byte matches golden function
 *   T3: Known Ethernet frame FCS (2-byte payload 0xDE,0xAD after 14-byte header)
 */
`ifndef TB_ETH_CRC32_8_SV
`define TB_ETH_CRC32_8_SV

module tb_eth_crc32_8;
  import tb_eth_pkg::*;

  // DUT: purely combinatorial, no clock needed; we drive sequentially in initial
  logic [7:0]  data_w;
  logic [31:0] crc_in_w;
  logic [31:0] crc_out_w;

  eth_crc32_8 u_crc (
    .data_i  (data_w),
    .crc_i   (crc_in_w),
    .crc_o   (crc_out_w)
  );

  int fails = 0;

  localparam logic [7:0] MSG9 [9] =
    '{8'h31,8'h32,8'h33,8'h34,8'h35,8'h36,8'h37,8'h38,8'h39};
  localparam logic [31:0] GOLDEN_STD = 32'hCBF4_3926;

  // Chain n bytes through the combinatorial CRC; result = ~state.
  task automatic chain_crc(
    input  logic [7:0]  data [],
    input  int          n,
    output logic [31:0] result
  );
    logic [31:0] st;
    st = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin
      data_w   = data[i];
      crc_in_w = st;
      #1;  // combinatorial settle
      st = crc_out_w;
    end
    result = ~st;
  endtask

  initial begin
    data_w   = 8'h00;
    crc_in_w = 32'hFFFF_FFFF;

    // --- T1: standard vector "123456789" ---
    begin
      logic [7:0]  msg[9];
      logic [31:0] got;
      for (int i = 0; i < 9; i++) msg[i] = MSG9[i];
      chain_crc(msg, 9, got);
      if (got !== GOLDEN_STD) begin
        $error("T1 FAIL: CRC32('123456789')=0x%08X want 0x%08X", got, GOLDEN_STD);
        fails++;
      end else $display("T1 PASS: CRC32('123456789')=0x%08X", got);
    end

    // --- T2: single byte matches golden function ---
    begin
      logic [7:0]  b1[1];
      logic [31:0] got, exp;
      b1[0] = 8'hA5;
      chain_crc(b1, 1, got);
      exp   = crc32(b1, 1);
      if (got !== exp) begin
        $error("T2 FAIL: single byte 0xA5 CRC=0x%08X want 0x%08X", got, exp);
        fails++;
      end else $display("T2 PASS: single byte CRC=0x%08X", got);
    end

    // --- T3: Ethernet frame CRC matches frame_fcs() helper ---
    begin
      localparam logic [47:0] DST = 48'hFF_FF_FF_FF_FF_FF;
      localparam logic [47:0] SRC = 48'h00_0A_35_01_FE_C0;
      localparam logic [15:0] ET  = 16'h9000;
      logic [7:0]  pl[2];
      logic [7:0]  hdr[14];
      logic [7:0]  d[16]; // 14 hdr + 2 payload
      logic [31:0] got, exp;

      pl[0] = 8'hDE; pl[1] = 8'hAD;
      build_eth_hdr(DST, SRC, ET, hdr);
      for (int i = 0; i < 14; i++) d[i]    = hdr[i];
      for (int i = 0; i < 2;  i++) d[14+i] = pl[i];
      // Note: 2-byte payload < 46, but FCS covers only header+payload in TB helper
      // (padding not added by chain_crc — we test the raw CRC engine here)
      chain_crc(d, 16, got);
      exp = crc32(d, 16);
      if (got !== exp) begin
        $error("T3 FAIL: frame CRC=0x%08X want 0x%08X", got, exp);
        fails++;
      end else $display("T3 PASS: frame CRC engine matches golden=0x%08X", got);
    end

    if (fails == 0) $display("tb_eth_crc32_8: ALL PASS");
    else            $fatal(1, "tb_eth_crc32_8: %0d FAILURES", fails);
    $finish;
  end

endmodule

`endif // TB_ETH_CRC32_8_SV
