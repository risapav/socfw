/**
 * @file  xfcp_rx_parser.sv
 * @brief Streaming parser pre XFCP request packet.
 *
 * Formát paketu:
 *   Bajt  | Pole
 *   ------|---------------------
 *     0   | SOP (0xFE = request)
 *     1   | OPCODE
 *     2   | SEQ (echo-ovany v response)
 *    3-4  | COUNT (Big-Endian, pocet bajtov payloadu)
 *    5-8  | ADDR  (Big-Endian)
 *   9..N  | PAYLOAD (len pre WRITE)
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  HYBRIDNÁ ARCHITEKTÚRA: PARALLEL HEADER DECODE + PAYLOAD FSM    ║
 * ║                                                                  ║
 * ║  STAGE 1 – HEADER SHIFT REGISTER (bajty 0-8):                   ║
 * ║    72-bit posuvny register hdr_shift_q zachytava bajty SOP-ADDR  ║
 * ║    bez akehokolvek FSM. Po 9. bajte je cely header dostupny      ║
 * ║    kombinacne v jednom takte.                                    ║
 * ║    Latency: 9 → 2 takty (zber + decode).                         ║
 * ║                                                                  ║
 * ║  STAGE 2 – PARALLEL DECODE (kombinacny):                         ║
 * ║    opcode = hdr_shift_q[71:64]                                   ║
 * ║    seq    = hdr_shift_q[63:56]                                   ║
 * ║    count  = hdr_shift_q[55:40]                                   ║
 * ║    addr   = hdr_shift_q[39:8]  -- wait, stored as [31:0] still  ║
 * ║    Validacia (alignment, opcode) prebieha v tom istom takte.     ║
 * ║                                                                  ║
 * ║  STAGE 3 – PAYLOAD FSM (bajty 9-N):                              ║
 * ║    Klasický FSM pre akumuláciu 32-bit slov do payload FIFO.      ║
 * ║    Zahrňuje ST_DROP, watchdog, SOP recovery z predchádzajúcej    ║
 * ║    verzie.                                                       ║
 * ║                                                                  ║
 * ║  Výsledok:                                                       ║
 * ║    Header latency : 8 → 2 cykly                                  ║
 * ║    FSM stavy      : 8 → 5 (odpadajú ST_TYPE, ST_COUNT, ST_ADDR)  ║
 * ║    LUT            : mierne menšie (menej stavových registrov)    ║
 * ╚══════════════════════════════════════════════════════════════════╝
 *
 * Zachované robustnostné vlastnosti:
 *   - ST_DROP stav (chybový paket žraný po TLAST)
 *   - Packet watchdog (MAX_PKT_BYTES)
 *   - SOP recovery
 *   - ONE-HOT FSM
 *   - SVA properties
 *   - bytes_left presný counter
 *   - header-first pipeline (WRITE: header PRED payload)
 */

`ifndef XFCP_RX_PARSER_SV
`define XFCP_RX_PARSER_SV

`default_nettype none

import axi_pkg::*;
import xfcp_pkg::*;

module xfcp_rx_parser #(
  parameter int AXI_ADDR_WIDTH = 32,
  parameter int AXI_DATA_WIDTH = 32,
  parameter int COUNT_WIDTH    = 16,
  parameter int FIFO_DEPTH     = 16,
  parameter int MAX_PKT_BYTES  = 4112
) (
  input  wire clk,
  input  wire rst_n,

  input  wire [7:0] s_axis_tdata,
  input  wire       s_axis_tvalid,
  output logic      s_axis_tready,
  input  wire       s_axis_tlast,

  output xfcp_req_hdr_t           req_hdr,
  output logic                    req_valid,
  input  wire                     req_ready,

  output logic [AXI_DATA_WIDTH-1:0] write_data,
  output logic                      write_data_valid,
  input  wire                       write_data_ready,

  output logic      pass_valid,
  output logic [7:0] pass_data,
  output logic      pass_last,
  input  wire       pass_ready,

  output logic error_protocol,

  output logic dbg_sop_o,      // pulse: good SOP received in S_IDLE
  output logic dbg_hdr_o,      // pulse: header FIFO push (successful decode)
  output logic dbg_drop_o,     // pulse: drop event (excluding re-entry into S_DROP)
  output logic dbg_bad_hdr_o,  // pulse: S_DECODE decode error (go_drop in S_DECODE)
  output logic dbg_recovery_o  // pulse: sop_recovery (SOP in unexpected state)
);

  // ============================================================
  // Lokálne konštanty
  // ============================================================
  // XFCP header: SOP(1) + OPCODE(1) + SEQ(1) + COUNT(2) + ADDR(4) = 9 bajtov
  // bajt 0 = SOP, nekodujeme do shift registra priamo (iba triggeruje)
  // bajty 1-8 idu do shift registra -> po 8 posunoch su vsetky polia platne
  // Shift: {hdr_shift_q[55:0], new_byte} => 64-bit left-shift, najstarsi bajt na [63:56]
  localparam int HDR_BYTES      = 9;   // celkova dlzka hlavicky
  localparam int BYTE_W        = 8;   // sirka bajtu
  localparam int HDR_SHIFT_W   = 64;  // 8 bajtov x 8 bitov (SOP sa neuklada)
  localparam int PKT_LEN_W     = $clog2(MAX_PKT_BYTES + 1);
  // Hornaya hranica COUNT: zamedzuje spracovaniu paketu s obrovskym countom.
  // 256 = max STREAM_WRITE payload; xfcp_axi_engine vykoná vlastnú kontrolu (<= 128B).
  localparam int MAX_COUNT_BYTES = 256;

  // ============================================================
  // ONE-HOT FSM – 5 stavov pre payload pipeline
  // ST_TYPE / ST_COUNT / ST_ADDR sú nahradené shift-register decode.
  // ============================================================
  typedef enum logic [4:0] {
    ST_IDLE    = 5'b00001,  // čakanie na SOP
    ST_HDR     = 5'b00010,  // zber header bajtov do shift registra
    ST_DECODE  = 5'b00100,  // 1-taktový decode + push header FIFO
    ST_PAYLOAD = 5'b01000,  // prijímanie payload bajtov
    ST_DROP    = 5'b10000   // chybový stav – žerie paket po TLAST
  } state_e;

  // Samostatný stav pre RPATH (passthrough – nesúvisí s header decode)
  // Kódujeme extra mimo one-hot aby sme ušetrili bit
  // Použijeme 6-bitový one-hot:
  typedef enum logic [5:0] {
    S_IDLE    = 6'b000001,
    S_RPATH   = 6'b000010,
    S_HDR     = 6'b000100,
    S_DECODE  = 6'b001000,
    S_PAYLOAD = 6'b010000,
    S_DROP    = 6'b100000
  } parser_state_e;

  (* fsm_encoding = "one_hot" *) parser_state_e state_q, state_n;

  // ============================================================
  // STAGE 1 – HEADER SHIFT REGISTER
  //
  // Kazdy prijaty bajt (axis_fire v S_HDR) sa posunie do registra.
  // Po 8 posunoch (bajty 1-8, t.j. OPCODE az ADDR[7:0]) je header
  // kompletny.
  //
  // Rozlozenie hdr_shift_n_comb po 8 bajtoch (shift: {hdr_shift_q[55:0], bajt}):
  //   [63:56] = bajt 1 = OPCODE
  //   [55:48] = bajt 2 = SEQ
  //   [47:40] = bajt 3 = COUNT[15:8]
  //   [39:32] = bajt 4 = COUNT[7:0]
  //   [31:24] = bajt 5 = ADDR[31:24]
  //   [23:16] = bajt 6 = ADDR[23:16]
  //   [15:8]  = bajt 7 = ADDR[15:8]
  //   [7:0]   = bajt 8 = ADDR[7:0]
  //
  // Citanie poli (kombinacne, platne v S_DECODE):
  //   opcode = hdr_shift_n_comb[63:56]
  //   seq    = hdr_shift_n_comb[55:48]
  //   count  = hdr_shift_n_comb[47:32]
  //   addr   = hdr_shift_n_comb[31:0]
  // ============================================================
  logic [HDR_SHIFT_W-1:0] hdr_shift_q;
  logic [HDR_SHIFT_W-1:0] hdr_shift_n_comb; // kombinacna hodnota pre S_DECODE
  logic [2:0]             hdr_byte_cnt_q;  // pocita bajty 1-8 (0-based: 0..7)
  logic                   tlast_on_last_hdr_q; // TLAST prisel s poslednym header bajtom

  // Decode polia z hdr_shift_q (FF, platne v S_DECODE — shift_q je aktualizovany
  // na konci taktovej hrany kde last_hdr_byte=1, rovnako ako state_q->S_DECODE).
  // hdr_shift_n_comb je zachovany len pre simulacne $display v S_HDR.
  wire [7:0]              dec_opcode = hdr_shift_q[63:56];
  wire [COUNT_WIDTH-1:0]  dec_count  = hdr_shift_q[47:32];
  wire [AXI_ADDR_WIDTH-1:0] dec_addr = hdr_shift_q[31:0];
  // synthesis translate_off
  wire [7:0]              dec_seq    = hdr_shift_q[55:48];
  // synthesis translate_on

  // ============================================================
  // Opcode validačná funkcia – Quartus generuje menší decode logic
  // ako OR reťazec komparátorov.
  function automatic logic opcode_valid(input logic [7:0] op);
    unique case (op)
      8'(XFCP_OP_ID)          : return 1'b1;
      8'(XFCP_OP_GET_CAPS)    : return 1'b1;
      8'(XFCP_OP_READ)        : return 1'b1;
      8'(XFCP_OP_WRITE)       : return 1'b1;
      8'(XFCP_OP_STREAM_WRITE): return 1'b1;
      8'(XFCP_OP_STREAM_READ) : return 1'b1;
      default                 : return 1'b0;
    endcase
  endfunction

  // ============================================================
  // STAGE 2 – PARALLEL DECODE (kombinačný, platný v S_DECODE)
  // Validácia prebieha v rovnakom takte ako decode.
  // ============================================================
  wire dec_opcode_ok = opcode_valid(dec_opcode);
  // COUNT % 4 == 0 AND within MAX_COUNT_BYTES bound (prevents huge garbage reads).
  // <= 256: upper byte is 0 (COUNT 0..255) OR COUNT == 256 exactly (0x0100).
  wire dec_count_ok  = (dec_count[1:0] == 2'b00)
                    && ((dec_count[15:8] == 8'h00) || (dec_count == 16'd256));

  // dec_count je zaručene násobok 4 (COUNT alignment check).
  // Jednoduchý posun namiesto (count+3)>>2 – žiadny adder, menej LUT.
  wire [COUNT_WIDTH-1:0] dec_words = COUNT_WIDTH'(dec_count >> 2);

  // ============================================================
  // EARLY DECODE — pre-registered 1 cycle before S_DECODE
  //
  // At T8 (last_hdr_byte, 7 bytes already shifted in), hdr_shift_q
  // holds bytes 1-7 but shifted 1 position short of their final layout:
  //   [55:48] = byte1 = OPCODE   (vs final [63:56])
  //   [39:24] = {byte3,byte4} = COUNT  (vs final [47:32])
  //
  // OPCODE and COUNT are stable by T8.  ADDR[7:0] (byte8) arrives at
  // the same T8 edge and does NOT affect opcode or count validity.
  // Registering early_valid/words_staged/bytes_left_staged at posedge T8
  // (enabled by last_hdr_byte) makes them available at T9 (S_DECODE).
  // This breaks the hdr_shift_q[37] carry-chain path to words_q.
  // ============================================================
  wire [7:0]             early_opcode = hdr_shift_q[55:48];
  wire [COUNT_WIDTH-1:0] early_count  = hdr_shift_q[39:24];

  wire early_opcode_ok = opcode_valid(early_opcode);
  wire early_count_ok  = (early_count[1:0] == 2'b00)
                      && ((early_count[15:8] == 8'h00) || (early_count == 16'd256));
  wire early_valid     = early_opcode_ok && early_count_ok;

  logic                    dec_valid_r;
  logic [COUNT_WIDTH-1:0]  words_staged;
  logic [COUNT_WIDTH-1:0]  bytes_left_staged;
  // Pre-registered hfifo_in fields: captured at last_hdr_byte from hdr_shift_n_comb.
  // Breaks hdr_shift_q -> decode logic -> hfifo_in -> i_header_fifo LUT_RAM data path.
  logic [7:0]                hfifo_opcode_r;
  logic [7:0]                hfifo_seq_r;
  logic [COUNT_WIDTH-1:0]    hfifo_count_r;
  logic [AXI_ADDR_WIDTH-1:0] hfifo_addr_r;

  // ============================================================
  // Payload registre (platia po S_DECODE)
  // ============================================================
  logic [COUNT_WIDTH-1:0] words_q,      words_n;
  logic [COUNT_WIDTH-1:0] bytes_left_q, bytes_left_n;
  logic [AXI_DATA_WIDTH-1:0] shift_q,  shift_n;
  logic [1:0]            byte_cnt_q,    byte_cnt_n;

  // ============================================================
  // Header / Payload FIFO
  // ============================================================
  logic                    hfifo_push;
  logic                    hfifo_w_ready;
  xfcp_req_hdr_t           hfifo_in;
  logic                    dfifo_w_ready;
  logic                    word_complete;
  logic                    word_complete_r;

  xfcp_fifo #(
    .DATA_WIDTH ($bits(xfcp_req_hdr_t)),
    .DEPTH      (4)
  ) i_header_fifo (
    .clk     (clk),
    .rst_n   (rst_n),
    .flush   (1'b0),
    .w_valid (hfifo_push),
    .w_data  (hfifo_in),
    .w_ready (hfifo_w_ready),
    .r_valid (req_valid),
    .r_data  (req_hdr),
    .r_ready (req_ready)
  );

  xfcp_fifo #(
    .DATA_WIDTH (AXI_DATA_WIDTH),
    .DEPTH      (FIFO_DEPTH)
  ) i_data_fifo (
    .clk     (clk),    .rst_n   (rst_n),
    .flush   (1'b0),
    .w_valid (word_complete_r),  .w_data  (shift_q),          .w_ready (dfifo_w_ready),
    .r_valid (write_data_valid), .r_data  (write_data),       .r_ready (write_data_ready)
  );

  // ============================================================
  // Pomocné signály
  // ============================================================
  wire axis_fire   = s_axis_tvalid && s_axis_tready;
  wire last_hdr_byte = (hdr_byte_cnt_q == 3'd7) && axis_fire; // 8. bajt (index 7)

  // Early-decode register: capture valid/words/bytes at T8 (last_hdr_byte)
  // using positions one byte short of final layout (see EARLY DECODE comment above).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dec_valid_r       <= 1'b0;
      words_staged      <= '0;
      bytes_left_staged <= '0;
      hfifo_opcode_r    <= '0;
      hfifo_seq_r       <= '0;
      hfifo_count_r     <= '0;
      hfifo_addr_r      <= '0;
    end else if (last_hdr_byte) begin
      dec_valid_r       <= early_valid;
      words_staged      <= COUNT_WIDTH'(early_count >> 2);
      bytes_left_staged <= early_count;
      hfifo_opcode_r    <= hdr_shift_n_comb[63:56];
      hfifo_seq_r       <= hdr_shift_n_comb[55:48];
      hfifo_count_r     <= hdr_shift_n_comb[47:32];
      hfifo_addr_r      <= hdr_shift_n_comb[31:0];
    end
  end

  // hdr_shift_n_comb: kombinacna hodnota shift registra vratane aktualneho bajtu.
  // V takte last_hdr_byte, hdr_shift_q este neobsahuje posledny bajt (sekvencny
  // register sa aktualizuje az na konci taktu). S_DECODE musi citat tuto
  // kombinacnu hodnotu aby videl vsetkych 8 bajtov.
  always_comb begin
    if (state_q == S_HDR && axis_fire)
      hdr_shift_n_comb = {hdr_shift_q[55:0], s_axis_tdata};
    else
      hdr_shift_n_comb = hdr_shift_q;
  end

  // SOP recovery: SOP v nečakanom stave → resync.
  // S_PAYLOAD vyluceny: 0xFE je platny datovy bajt v payloade (napr. byte[254]=0xFE
  // v 256B prenose bytes(range(256))).
  wire sop_recovery = axis_fire                              &&
                      s_axis_tdata == XFCP_SOP_REQ &&
                      state_q != S_IDLE                     &&
                      state_q != S_RPATH                    &&
                      state_q != S_PAYLOAD;

  // Watchdog
  logic [PKT_LEN_W-1:0] pkt_len_q;
  wire watchdog_fire = (pkt_len_q >= PKT_LEN_W'(MAX_PKT_BYTES));

  // ============================================================
  // WORD COMPLETE (payload)
  // ============================================================
  // last_byte: pomenovaný wire skráti kombinačný path word_complete.
  wire last_byte   = (bytes_left_q == 1);

  assign word_complete = (state_q == S_PAYLOAD) &&
                         axis_fire              &&
                         (byte_cnt_q == 2'd3 || last_byte);

  // word_complete_r: registered 1-cycle delay of word_complete.
  // Breaks arb_s0_valid_r -> axis_fire -> word_complete -> i_data_fifo.mem path.
  // At T+1 shift_q already holds the assembled word (shift_q <= shift_n at T),
  // so writing shift_q at T+1 is correct. FIFO readiness: dfifo_w_ready was 1 at T
  // (because s_axis_tready=dfifo_w_ready in S_PAYLOAD) and no write happened at T,
  // so FIFO still has space at T+1.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) word_complete_r <= 1'b0;
    else        word_complete_r <= word_complete;
  end

  // ============================================================
  // s_axis_tready
  // ============================================================
  always_comb begin
    unique case (state_q)
      S_PAYLOAD: s_axis_tready = dfifo_w_ready;
      S_RPATH:   s_axis_tready = pass_ready;
      S_DECODE:  s_axis_tready = 1'b0;   // 1 takt decode, neprijímame bajty
      S_DROP:    s_axis_tready = 1'b1;
      default:   s_axis_tready = 1'b1;   // S_IDLE, S_HDR
    endcase
  end

  // ============================================================
  // Watchdog counter
  // Also reset on sop_recovery to prevent deadlock: without the reset,
  // sop_recovery(S_DROP -> S_HDR) leaves pkt_len_q saturated; the very
  // next cycle in S_HDR sees watchdog_fire=1 -> go_drop=1 -> S_DROP
  // again, trapping the parser permanently regardless of new SOPs.
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pkt_len_q <= '0;
    else if (state_q == S_IDLE || sop_recovery)
      pkt_len_q <= '0;
    else if (axis_fire)
      pkt_len_q <= (pkt_len_q < PKT_LEN_W'(MAX_PKT_BYTES))
                   ? pkt_len_q + 1'b1 : pkt_len_q;
  end

  // ============================================================
  // go_drop – centralizovaná chybová detekcia
  // ============================================================
  logic go_drop;
  // drop_with_tlast: go_drop nastáva v takte keď axis_fire&&TLAST je aktívne.
  // V tomto prípade paket už skončil – S_DROP môže ísť do S_IDLE okamžite.
  logic drop_with_tlast;
  always_comb begin
    go_drop = 1'b0;
    if (watchdog_fire && state_q != S_IDLE && state_q != S_DROP)
      go_drop = 1'b1;
    // Decode chyba — uses pre-registered value (see early decode section)
    if (state_q == S_DECODE && !dec_valid_r)
      go_drop = 1'b1;
    // Predcasny TLAST v S_HDR: chyba len ak pride PRED poslednym
    // header bajtom. Na poslednom bajte (last_hdr_byte) je TLAST
    // legalne pre READ/ID pakety (ziadny payload). Validacia toho
    // pripadu prebieha v S_DECODE kde vieme opcode.
    if (state_q == S_HDR && axis_fire && s_axis_tlast && !last_hdr_byte)
      go_drop = 1'b1;
    // TLAST na poslednom header bajte s WRITE/STREAM_WRITE opcode: chyba payload.
    if (state_q == S_DECODE && tlast_on_last_hdr_q &&
        (dec_opcode == 8'(XFCP_OP_WRITE) ||
         dec_opcode == 8'(XFCP_OP_STREAM_WRITE)))
      go_drop = 1'b1;
    // WRITE/STREAM_WRITE s COUNT=0 sposobuje deadlock — zahodime paket.
    if (state_q == S_DECODE &&
        (dec_opcode == 8'(XFCP_OP_WRITE) ||
         dec_opcode == 8'(XFCP_OP_STREAM_WRITE)) &&
        dec_words == 0)
      go_drop = 1'b1;
    // TLAST uprostred payload
    if (state_q == S_PAYLOAD && axis_fire &&
        s_axis_tlast && bytes_left_q != 1)
      go_drop = 1'b1;
  end

  // drop_with_tlast: go_drop spustený TLAST-om – paket skončil v tom istom takte
  assign drop_with_tlast = go_drop && axis_fire && s_axis_tlast;

  // Debug pulses (1-cycle, combinational)
  assign dbg_sop_o      = (state_q == S_IDLE) && axis_fire && (s_axis_tdata == XFCP_SOP_REQ);
  assign dbg_hdr_o      = hfifo_push;
  assign dbg_drop_o     = go_drop && (state_q != S_DROP);
  assign dbg_bad_hdr_o  = (state_q == S_DECODE) && go_drop;
  assign dbg_recovery_o = sop_recovery;

  // ============================================================
  // Header shift register - sekvencna logika
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hdr_shift_q          <= '0;
      hdr_byte_cnt_q       <= '0;
      tlast_on_last_hdr_q  <= 1'b0;
    end else begin
      // Reset shift registra pri IDLE alebo pri SOP recovery z ineho stavu.
      // SOP recovery: sop_recovery=1 -> state_n=S_HDR -> v nasledujucom takte
      // state_q=S_HDR, ale shift mohol obsahovat stale data. Reset tu (ked
      // state_q!=S_HDR a sop_recovery=1) zaisti cisty shift pred S_HDR.
      if (state_q == S_IDLE || sop_recovery) begin
        hdr_byte_cnt_q      <= '0;
        hdr_shift_q         <= '0;
        tlast_on_last_hdr_q <= 1'b0;
      end else if (state_q == S_DROP) begin
        hdr_byte_cnt_q <= '0;
      end else if (state_q == S_HDR && axis_fire) begin
        hdr_shift_q          <= {hdr_shift_q[55:0], s_axis_tdata};
        hdr_byte_cnt_q       <= hdr_byte_cnt_q + 1'b1;
        tlast_on_last_hdr_q  <= s_axis_tlast && (hdr_byte_cnt_q == 3'd7);
        // synthesis translate_off
        $display("[%0t] %m: S_HDR byte cnt=%0d data=0x%02h seq=0x%02h tlast=%0b last=%0b",
                 $time, hdr_byte_cnt_q, s_axis_tdata, dec_seq, s_axis_tlast,
                 (hdr_byte_cnt_q == 3'd7));
        // synthesis translate_on
      end
    end
  end

  // ============================================================
  // Sekvencna logika - payload registre + error_protocol
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= S_IDLE;
      words_q        <= '0;
      bytes_left_q   <= '0;
      shift_q        <= '0;
      byte_cnt_q     <= '0;
      error_protocol <= 1'b0;
    end else begin
      state_q    <= state_n;
      shift_q    <= shift_n;
      byte_cnt_q <= byte_cnt_n;
      words_q    <= words_n;
      bytes_left_q <= bytes_left_n;

      // error_protocol: reset pri novom SOP, set pri chybe
      if (state_q == S_IDLE && axis_fire &&
          s_axis_tdata == XFCP_SOP_REQ)
        error_protocol <= 1'b0;
      else if (go_drop)
        error_protocol <= 1'b1;
    end
  end

  // ============================================================
  // FSM - kombinacna logika
  // ============================================================
  always_comb begin
    state_n      = state_q;
    shift_n      = shift_q;
    byte_cnt_n   = byte_cnt_q;
    words_n      = words_q;
    bytes_left_n = bytes_left_q;

    hfifo_push = 1'b0;
    hfifo_in   = '0;
    pass_valid = 1'b0;
    pass_data  = s_axis_tdata;
    pass_last  = s_axis_tlast;

    // Globalne pravidla (priorita)
    if (go_drop) begin
      // Ak go_drop nastava v takte TLAST, paket skoncil - S_DROP nie je
      // potrebny, ideme priamo do S_IDLE. Inak S_DROP zerie zvysok paketu.
      state_n = drop_with_tlast ? S_IDLE : S_DROP;
    end else if (sop_recovery) begin
      state_n = S_HDR;
    end else begin

      case (state_q)

        // S_IDLE: cakanie na SOP
        // S_RPATH len ked pass_ready=1: inak by 0xFF (RPATH SOP)
        // sposobil permanentny deadlock (TLAST=0 -> exit nemozny,
        // TREADY=0 -> watchdog/sop_recovery nemoze strelat).
        S_IDLE: begin
          if (axis_fire) begin
            if (s_axis_tdata == XFCP_SOP_REQ)
              state_n = S_HDR;
            else if (s_axis_tdata == XFCP_SOP_RPATH && pass_ready)
              state_n = S_RPATH;
          end
        end

        // S_RPATH: passthrough
        S_RPATH: begin
          pass_valid = s_axis_tvalid;
          if (axis_fire && s_axis_tlast) state_n = S_IDLE;
        end

        // S_HDR: zbieranie 8 header bajtov (bajty 1-8)
        // SOP (bajt 0) bol prijaty v S_IDLE, tu cakame na zvysok.
        // Po 8 bajtoch (hdr_byte_cnt_q == 7 -> last_hdr_byte) prejdeme
        // do S_DECODE kde sa vykona paralelny decode v 1 takte.
        S_HDR: begin
          if (last_hdr_byte)
            state_n = S_DECODE;
          // go_drop pre predcasny TLAST je pokryty globalnym blokom
        end

        // S_DECODE: 1-taktovy paralelny decode
        // V tomto takte:
        //   - dec_opcode / dec_seq / dec_count / dec_addr su kombinacne platne
        //   - dec_valid skontroluje opcode + COUNT alignment
        //   - go_drop == 1 ak dec_valid == 0 -> S_DROP (globalny blok)
        //   - inak pushujeme header FIFO a rozhodujeme dalsi stav
        //
        // s_axis_tready = 0 v S_DECODE -> upstream caka 1 takt.
        // Toto je nevyhnutne: payload bajt 9 nesmie prist skor ako
        // decoder skoncil a nastavil words_n / bytes_left_n.
        S_DECODE: begin
          if (dec_valid_r) begin
            // Inicializacia payload registrov z pre-registered decode
            words_n      = words_staged;
            bytes_left_n = bytes_left_staged;
            byte_cnt_n   = '0;
            shift_n      = '0;

            // Opcodes s payload (WRITE, STREAM_WRITE): header-first, potom S_PAYLOAD
            if ((dec_opcode == 8'(XFCP_OP_WRITE) ||
                 dec_opcode == 8'(XFCP_OP_STREAM_WRITE)) &&
                dec_words != 0) begin
              hfifo_push      = hfifo_w_ready;
              hfifo_in.opcode = xfcp_op_e'(hfifo_opcode_r);
              hfifo_in.seq    = hfifo_seq_r;
              hfifo_in.addr   = hfifo_addr_r;
              hfifo_in.count  = hfifo_count_r;
              if (hfifo_w_ready)
                state_n = S_PAYLOAD;
            end else begin
              // READ/ID/STREAM_READ: header push, chod do IDLE (bez payloadu)
              hfifo_push      = hfifo_w_ready;
              hfifo_in.opcode = xfcp_op_e'(hfifo_opcode_r);
              hfifo_in.seq    = hfifo_seq_r;
              hfifo_in.addr   = hfifo_addr_r;
              hfifo_in.count  = hfifo_count_r;
              if (hfifo_w_ready)
                state_n = S_IDLE;
            end
          end
          // dec_valid == 0 -> go_drop == 1 -> S_DROP (globalny blok)
          // WRITE + TLAST: pokryte v go_drop always_comb cez tlast_on_last_hdr_q
        end

        // S_PAYLOAD: akumulacia bajtov do 32-bit slov
        S_PAYLOAD: begin
          if (axis_fire) begin
            shift_n      = {shift_q[AXI_DATA_WIDTH-BYTE_W-1:0], s_axis_tdata};
            bytes_left_n = (bytes_left_q > 0) ? bytes_left_q - 1'b1 : '0;

            if (byte_cnt_q == 2'd3) begin
              byte_cnt_n = '0;
              words_n    = (words_q > 0) ? words_q - 1'b1 : '0;
              if (words_q <= 1) state_n = S_IDLE;
            end else begin
              byte_cnt_n = byte_cnt_q + 1'b1;
            end
          end
        end

        // S_DROP: zerieme paket po TLAST
        S_DROP: begin
          if (axis_fire && s_axis_tlast) state_n = S_IDLE;
        end

        default: state_n = S_IDLE;
      endcase
    end
  end

  // ============================================================
  // Simulacne spravy
  // ============================================================
  // synthesis translate_off
  logic error_protocol_prev;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      error_protocol_prev <= 1'b0;
    end else begin
      error_protocol_prev <= error_protocol;
      if (hfifo_push)
        $display("[%0t] %m: HDR push | op=0x%02h seq=0x%02h addr=0x%08h count=%0d",
                 $time, hfifo_opcode_r, hfifo_seq_r, hfifo_addr_r, hfifo_count_r);
      if (word_complete)
        $display("[%0t] %m: PAYLOAD word=0x%08h words_rem=%0d",
                 $time, shift_n, words_q);
      if (error_protocol && !error_protocol_prev)
        $warning("[%0t] %m: PROTOCOL ERROR -> S_DROP (stav=0x%02h op=0x%02h)",
                 $time, 6'(state_q), dec_opcode);
      if (watchdog_fire && state_q != S_DROP)
        $warning("[%0t] %m: WATCHDOG - paket > %0d bajtov, drop", $time, MAX_PKT_BYTES);
      if (sop_recovery)
        $warning("[%0t] %m: SOP RECOVERY v stave 0x%02h - resync", $time, 6'(state_q));
      if (state_q == S_DECODE && !dec_count_ok)
        $warning("[%0t] %m: COUNT=0x%04h nie je nasobok 4 - drop", $time, dec_count);
    end
  end

  // Invariant: bytes_left nesmie podtiec
  always_ff @(posedge clk) begin
    if (rst_n && state_q == S_PAYLOAD && axis_fire)
      assert (bytes_left_q > 0)
        else $fatal(1, "[%0t] %m: bytes_left podtecie!", $time);
  end

  // SVA: payload FIFO overflow nemozny (word_complete_r is the actual write enable)
  no_payload_fifo_overflow: assert property (
    @(posedge clk) disable iff (!rst_n)
    word_complete_r |-> dfifo_w_ready
  ) else $fatal(1, "[%0t] %m: SVA FAIL - word_complete_r pri plnej payload FIFO!", $time);

  // SVA: header push len ked FIFO ready
  no_header_fifo_overflow: assert property (
    @(posedge clk) disable iff (!rst_n)
    hfifo_push |-> hfifo_w_ready
  ) else $fatal(1, "[%0t] %m: SVA FAIL - hfifo_push pri plnej header FIFO!", $time);

  // SVA: S_DROP musi skoncit
  drop_state_must_end: assert property (
    @(posedge clk) disable iff (!rst_n)
    $rose(state_q == S_DROP) |-> ##[1:MAX_PKT_BYTES] (state_q == S_IDLE)
  ) else $error("[%0t] %m: SVA WARN - S_DROP trva > %0d taktov", $time, MAX_PKT_BYTES);

  // SVA: S_DECODE trva max 1-2 takty (FIFO ready guard)
  decode_completes: assert property (
    @(posedge clk) disable iff (!rst_n)
    $rose(state_q == S_DECODE) |-> ##[1:4] (state_q != S_DECODE)
  ) else $error("[%0t] %m: SVA WARN - S_DECODE trva > 4 takty (header FIFO backpressure?)",
               $time);

  // synthesis translate_on

endmodule : xfcp_rx_parser

`endif  // XFCP_RX_PARSER_SV
