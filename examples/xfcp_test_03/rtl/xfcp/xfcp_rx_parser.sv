/**
 * @file  xfcp_rx_parser.sv
 * @brief Streaming parser pre XFCP request packet.
 *
 * Formát paketu:
 *   Bajt  | Pole
 *   ------|---------------------
 *     0   | SOP (0xFE = request)
 *     1   | OPCODE
 *    2-3  | COUNT (Big-Endian, počet bajtov payloadu)
 *    4-7  | ADDR  (Big-Endian)
 *   8..N  | PAYLOAD (len pre WRITE)
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  HYBRIDNÁ ARCHITEKTÚRA: PARALLEL HEADER DECODE + PAYLOAD FSM    ║
 * ║                                                                  ║
 * ║  STAGE 1 – HEADER SHIFT REGISTER (bajty 0-7):                   ║
 * ║    64-bit posuvný register hdr_shift_q zachytáva bajty SOP-ADDR  ║
 * ║    bez akéhokoľvek FSM. Po 8. bajte je celý header dostupný      ║
 * ║    kombinačne v jednom takte.                                    ║
 * ║    Latency: 8 → 2 takty (zber + decode).                         ║
 * ║                                                                  ║
 * ║  STAGE 2 – PARALLEL DECODE (kombinačný):                         ║
 * ║    opcode = hdr_shift_q[55:48]                                   ║
 * ║    count  = hdr_shift_q[47:32]                                   ║
 * ║    addr   = hdr_shift_q[31:0]                                    ║
 * ║    Validácia (alignment, opcode) prebieha v tom istom takte.     ║
 * ║                                                                  ║
 * ║  STAGE 3 – PAYLOAD FSM (bajty 8-N):                              ║
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

  output logic [55:0]             req_hdr,
  output logic                    req_valid,
  input  wire                     req_ready,

  output logic [AXI_DATA_WIDTH-1:0] write_data,
  output logic                      write_data_valid,
  input  wire                       write_data_ready,

  output logic      pass_valid,
  output logic [7:0] pass_data,
  output logic      pass_last,
  input  wire       pass_ready,

  output logic error_protocol
);

  // ============================================================
  // Lokálne konštanty
  // ============================================================
  // XFCP header: SOP(1) + OPCODE(1) + COUNT(2) + ADDR(4) = 8 bajtov
  // bajt 0 = SOP, nekódujeme do shift registra priamo (iba triggeruje)
  // bajty 1-7 idú do shift registra → po 7 posunoch sú všetky polia platné
  localparam int HDR_BYTES      = 8;   // celková dĺžka hlavičky
  localparam int BYTE_W        = 8;   // šírka bajtu
  localparam int HDR_SHIFT_W   = 64;  // 8 bajtov × 8 bitov
  localparam int PKT_LEN_W     = $clog2(MAX_PKT_BYTES + 1);
  // Hornaya hranica COUNT: zamedzuje spracovaniu paketu s obrovskym countom.
  // Zhoduje sa s xfcp_axi_engine FIFO_DEPTH=32 slov = 128 bajtov.
  localparam int MAX_COUNT_BYTES = 128;

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
  // Každý prijatý bajt (axis_fire v S_HDR) sa posunie do registra.
  // Po 7 posunoch (bajty 1-7, t.j. OPCODE až ADDR[7:0]) je header
  // kompletný.
  //
  // Rozlozenie hdr_shift_n_comb po 7 bajtoch (shift: {hdr_shift_q[55:0], bajt}):
  //   [63:56] = 0 (nevyuzite — shift zahadzuje hornych 8 bitov)
  //   [55:48] = bajt 1 = OPCODE
  //   [47:40] = bajt 2 = COUNT[15:8]
  //   [39:32] = bajt 3 = COUNT[7:0]
  //   [31:24] = bajt 4 = ADDR[31:24]
  //   [23:16] = bajt 5 = ADDR[23:16]
  //   [15:8]  = bajt 6 = ADDR[15:8]
  //   [7:0]   = bajt 7 = ADDR[7:0]
  //
  // Citanie poli (kombinacne, platne v S_DECODE):
  //   opcode = hdr_shift_n_comb[55:48]
  //   count  = hdr_shift_n_comb[47:32]
  //   addr   = hdr_shift_n_comb[31:0]
  // ============================================================
  logic [HDR_SHIFT_W-1:0] hdr_shift_q;
  logic [HDR_SHIFT_W-1:0] hdr_shift_n_comb; // kombinačná hodnota pre S_DECODE
  logic [2:0]             hdr_byte_cnt_q;  // počíta bajty 1-7 (0-based: 0..6)
  logic                   tlast_on_last_hdr_q; // TLAST prišiel s posledným header bajtom

  // Kombinačné polia z shift registra (platné keď hdr_byte_cnt_q == 6)
  wire [7:0]              dec_opcode = hdr_shift_n_comb[55:48];
  wire [COUNT_WIDTH-1:0]  dec_count  = hdr_shift_n_comb[47:32];
  wire [AXI_ADDR_WIDTH-1:0] dec_addr = hdr_shift_n_comb[31:0];

  // ============================================================
  // Opcode validačná funkcia – Quartus generuje menší decode logic
  // ako OR reťazec komparátorov.
  function automatic logic opcode_valid(input logic [7:0] op);
    unique case (op)
      8'(XFCP_OP_ID)   : return 1'b1;
      8'(XFCP_OP_READ) : return 1'b1;
      8'(XFCP_OP_WRITE): return 1'b1;
      default                    : return 1'b0;
    endcase
  endfunction

  // ============================================================
  // STAGE 2 – PARALLEL DECODE (kombinačný, platný v S_DECODE)
  // Validácia prebieha v rovnakom takte ako decode.
  // ============================================================
  wire dec_opcode_ok = opcode_valid(dec_opcode);
  // COUNT % 4 == 0 AND within MAX_COUNT_BYTES bound (prevents huge garbage reads)
  wire dec_count_ok  = (dec_count[1:0] == 2'b00)
                    && (dec_count <= COUNT_WIDTH'(MAX_COUNT_BYTES));
  wire dec_valid     = dec_opcode_ok && dec_count_ok;

  // Vypočítané hodnoty z decode (kombinačné)
  // dec_count je zaručene násobok 4 (COUNT alignment check).
  // Jednoduchý posun namiesto (count+3)>>2 – žiadny adder, menej LUT.
  wire [COUNT_WIDTH-1:0] dec_words      = COUNT_WIDTH'(dec_count >> 2);
  wire [COUNT_WIDTH-1:0] dec_bytes_left = dec_count;

  // ============================================================
  // Payload registre (platia po S_DECODE)
  // ============================================================
  logic [7:0]            opcode_q;
  logic [COUNT_WIDTH-1:0] count_q;
  logic [AXI_ADDR_WIDTH-1:0] addr_q;
  logic [COUNT_WIDTH-1:0] words_q,      words_n;
  logic [COUNT_WIDTH-1:0] bytes_left_q, bytes_left_n;
  logic [AXI_DATA_WIDTH-1:0] shift_q,  shift_n;
  logic [1:0]            byte_cnt_q,    byte_cnt_n;

  // ============================================================
  // Header / Payload FIFO
  // ============================================================
  logic                    hfifo_push;
  logic                    hfifo_w_ready;
  xfcp_req_hdr_t            hfifo_in;
  logic                    dfifo_w_ready;
  logic                    word_complete;

  xfcp_fifo #(
    .DATA_WIDTH ($bits(xfcp_req_hdr_t)),
    .DEPTH      (4)
  ) i_header_fifo (
    .clk     (clk),    .rst_n   (rst_n),
    .flush   (1'b0),
    .w_valid (hfifo_push),   .w_data  (hfifo_in),   .w_ready (hfifo_w_ready),
    .r_valid (req_valid),    .r_data  (req_hdr),    .r_ready (req_ready)
  );

  xfcp_fifo #(
    .DATA_WIDTH (AXI_DATA_WIDTH),
    .DEPTH      (FIFO_DEPTH)
  ) i_data_fifo (
    .clk     (clk),    .rst_n   (rst_n),
    .flush   (1'b0),
    .w_valid (word_complete),    .w_data  (shift_n),          .w_ready (dfifo_w_ready),
    .r_valid (write_data_valid), .r_data  (write_data),       .r_ready (write_data_ready)
  );

  // ============================================================
  // Pomocné signály
  // ============================================================
  wire axis_fire   = s_axis_tvalid && s_axis_tready;
  wire last_hdr_byte = (hdr_byte_cnt_q == 3'd6) && axis_fire; // 7. bajt (index 6)

  // hdr_shift_n_comb: kombinačná hodnota shift registra vrátane aktuálneho bajtu.
  // V takte last_hdr_byte, hdr_shift_q ešte neobsahuje posledný bajt (sekvenčný
  // register sa aktualizuje až na konci taktu). S_DECODE musí čítať túto
  // kombinačnú hodnotu aby videl všetkých 7 bajtov.
  always_comb begin
    if (state_q == S_HDR && axis_fire)
      hdr_shift_n_comb = {hdr_shift_q[55:0], s_axis_tdata};
    else
      hdr_shift_n_comb = hdr_shift_q;
  end

  // SOP recovery: SOP v nečakanom stave → resync
  wire sop_recovery = axis_fire                              &&
                      s_axis_tdata == XFCP_SOP_REQ &&
                      state_q != S_IDLE                     &&
                      state_q != S_RPATH;

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
    // Decode chyba (neplatný opcode alebo COUNT misalignment)
    if (state_q == S_DECODE && !dec_valid)
      go_drop = 1'b1;
    // Predčasný TLAST v S_HDR: chyba len ak príde PRED posledným
    // header bajtom. Na poslednom bajte (last_hdr_byte) je TLAST
    // legálne pre READ/ID pakety (žiadny payload). Validácia toho
    // prípadu prebieha v S_DECODE kde vieme opcode.
    if (state_q == S_HDR && axis_fire && s_axis_tlast && !last_hdr_byte)
      go_drop = 1'b1;
    // TLAST na poslednom header bajte s WRITE opcode: chyba (chýba payload).
    // Toto detekujeme v S_DECODE (opcode je dekódovaný až tam).
    // WRITE s TLAST na poslednom header bajte = chýba payload
    if (state_q == S_DECODE && tlast_on_last_hdr_q &&
        dec_opcode == 8'(XFCP_OP_WRITE))
      go_drop = 1'b1;
    // FIX D: WRITE s COUNT=0 (dec_words==0) spôsobuje deadlock v engine
    // (engine čaká na wfifo_valid ktorý nikdy nepríde). Zahodíme paket.
    if (state_q == S_DECODE && dec_opcode == 8'(XFCP_OP_WRITE) &&
        dec_words == 0)
      go_drop = 1'b1;
    // TLAST uprostred payload
    if (state_q == S_PAYLOAD && axis_fire &&
        s_axis_tlast && bytes_left_q != 1)
      go_drop = 1'b1;
  end

  // drop_with_tlast: go_drop spustený TLAST-om – paket skončil v tom istom takte
  assign drop_with_tlast = go_drop && axis_fire && s_axis_tlast;

  // ============================================================
  // Header shift register – sekvenčná logika
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hdr_shift_q          <= '0;
      hdr_byte_cnt_q       <= '0;
      tlast_on_last_hdr_q  <= 1'b0;
    end else begin
      // Reset shift registra pri IDLE alebo pri SOP recovery z iného stavu.
      // SOP recovery: sop_recovery=1 → state_n=S_HDR → v nasledujúcom takte
      // state_q=S_HDR, ale shift mohol obsahovať stale dáta. Reset tu (keď
      // state_q!=S_HDR a sop_recovery=1) zaistí čistý shift pred S_HDR.
      if (state_q == S_IDLE || sop_recovery) begin
        hdr_byte_cnt_q      <= '0;
        hdr_shift_q         <= '0;
        tlast_on_last_hdr_q <= 1'b0;
      end else if (state_q == S_DROP) begin
        hdr_byte_cnt_q <= '0;
      end else if (state_q == S_HDR && axis_fire) begin
        hdr_shift_q          <= {hdr_shift_q[55:0], s_axis_tdata};
        hdr_byte_cnt_q       <= hdr_byte_cnt_q + 1'b1;
        tlast_on_last_hdr_q  <= s_axis_tlast && (hdr_byte_cnt_q == 3'd6);
        // synthesis translate_off
        $display("[%0t] %m: S_HDR byte cnt=%0d data=0x%02h tlast=%0b last=%0b next_shift=0x%016h",
                 $time, hdr_byte_cnt_q, s_axis_tdata, s_axis_tlast,
                 (hdr_byte_cnt_q == 3'd6),
                 {hdr_shift_q[55:0], s_axis_tdata});
        // synthesis translate_on
      end
    end
  end

  // ============================================================
  // Sekvenčná logika – payload registre + error_protocol
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= S_IDLE;
      opcode_q       <= '0;
      count_q        <= '0;
      addr_q         <= '0;
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

      // Latch decode výsledkov pri prechode S_DECODE → S_PAYLOAD/S_DROP
      if (state_q == S_DECODE) begin
        opcode_q <= dec_opcode;
        count_q  <= dec_count;
        addr_q   <= dec_addr;
      end

      // error_protocol: reset pri novom SOP, set pri chybe
      if (state_q == S_IDLE && axis_fire &&
          s_axis_tdata == XFCP_SOP_REQ)
        error_protocol <= 1'b0;
      else if (go_drop)
        error_protocol <= 1'b1;
    end
  end

  // ============================================================
  // FSM – kombinačná logika
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

    // ── Globálne pravidlá (priorita) ───────────────────────────
    if (go_drop) begin
      // Ak go_drop nastáva v takte TLAST, paket skončil – S_DROP nie je
      // potrebný, ideme priamo do S_IDLE. Inak S_DROP žerie zvyšok paketu.
      state_n = drop_with_tlast ? S_IDLE : S_DROP;
    end else if (sop_recovery) begin
      state_n = S_HDR;
    end else begin

      case (state_q)

        // ── S_IDLE: čakanie na SOP ──────────────────────────────
        // S_RPATH len keď pass_ready=1: inak by 0xFF (RPATH SOP)
        // sposobil permanentny deadlock (TLAST=0 → exit nemozny,
        // TREADY=0 → watchdog/sop_recovery nemoze strelat).
        S_IDLE: begin
          if (axis_fire) begin
            if (s_axis_tdata == XFCP_SOP_REQ)
              state_n = S_HDR;
            else if (s_axis_tdata == XFCP_SOP_RPATH && pass_ready)
              state_n = S_RPATH;
          end
        end

        // ── S_RPATH: passthrough ────────────────────────────────
        S_RPATH: begin
          pass_valid = s_axis_tvalid;
          if (axis_fire && s_axis_tlast) state_n = S_IDLE;
        end

        // ── S_HDR: zbieranie 7 header bajtov (bajty 1-7) ────────
        // SOP (bajt 0) bol prijatý v S_IDLE, tu čakáme na zvyšok.
        // Po 7 bajtoch (hdr_byte_cnt_q == 6 → last_hdr_byte) prejdeme
        // do S_DECODE kde sa vykoná paralelný decode v 1 takte.
        S_HDR: begin
          if (last_hdr_byte)
            state_n = S_DECODE;
          // go_drop pre predčasný TLAST je pokrytý globálnym blokom
        end

        // ── S_DECODE: 1-taktový paralelný decode ─────────────────
        // V tomto takte:
        //   - dec_opcode / dec_count / dec_addr sú kombinačne platné
        //   - dec_valid skontroluje opcode + COUNT alignment
        //   - go_drop == 1 ak dec_valid == 0 → S_DROP (globálny blok)
        //   - inak pushujeme header FIFO a rozhodujeme ďalší stav
        //
        // s_axis_tready = 0 v S_DECODE → upstream čaká 1 takt.
        // Toto je nevyhnutné: payload bajt 8 nesmie prísť skôr ako
        // decoder skončí a nastaví words_n / bytes_left_n.
        S_DECODE: begin
          if (dec_valid) begin
            // Inicializácia payload registrov z decode výsledkov
            words_n      = dec_words;
            bytes_left_n = dec_bytes_left;
            byte_cnt_n   = '0;
            shift_n      = '0;

            if (dec_opcode == 8'(XFCP_OP_WRITE) &&
                dec_words != 0) begin
              // WRITE: pushni header PRED payload (header-first pipeline)
              hfifo_push      = hfifo_w_ready;  // push ak FIFO ready
              hfifo_in.opcode = xfcp_op_e'(dec_opcode);
              hfifo_in.addr   = dec_addr;
              hfifo_in.count  = dec_count;
              if (hfifo_w_ready)
                state_n = S_PAYLOAD;
              // ak FIFO nie je ready, zostávame v S_DECODE
              // (s_axis_tready=0 → upstream stojí)
            end else begin
              // READ/ID: pushni header a choď do IDLE
              hfifo_push      = hfifo_w_ready;
              hfifo_in.opcode = xfcp_op_e'(dec_opcode);
              hfifo_in.addr   = dec_addr;
              hfifo_in.count  = dec_count;
              if (hfifo_w_ready)
                state_n = S_IDLE;
            end
          end
          // dec_valid == 0 → go_drop == 1 → S_DROP (globálny blok)
          // WRITE + TLAST: pokryté v go_drop always_comb cez tlast_on_last_hdr_q
        end

        // ── S_PAYLOAD: akumulácia bajtov do 32-bit slov ──────────
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

        // ── S_DROP: žerieme paket po TLAST ──────────────────────
        S_DROP: begin
          if (axis_fire && s_axis_tlast) state_n = S_IDLE;
        end

        default: state_n = S_IDLE;
      endcase
    end
  end

  // ============================================================
  // Simulačné správy
  // ============================================================
  // synthesis translate_off
  xfcp_op_e dbg_opcode;
  assign dbg_opcode = xfcp_op_e'(opcode_q);

  logic error_protocol_prev;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      error_protocol_prev <= 1'b0;
    end else begin
      error_protocol_prev <= error_protocol;
      if (hfifo_push)
        $display("[%0t] %m: HDR push | op=0x%02h addr=0x%08h count=%0d | dec: op=0x%02h addr=0x%08h cnt=0x%04h shift=0x%016h",
                 $time, 8'(dbg_opcode), addr_q, count_q,
                 dec_opcode, dec_addr, dec_count, hdr_shift_n_comb);
      if (word_complete)
        $display("[%0t] %m: PAYLOAD word=0x%08h words_rem=%0d",
                 $time, shift_n, words_q);
      if (error_protocol && !error_protocol_prev)
        $error("[%0t] %m: PROTOCOL ERROR → S_DROP (stav=0x%02h op=0x%02h)",
               $time, 6'(state_q), dec_opcode);
      if (watchdog_fire && state_q != S_DROP)
        $warning("[%0t] %m: WATCHDOG – paket > %0d bajtov, drop", $time, MAX_PKT_BYTES);
      if (sop_recovery)
        $warning("[%0t] %m: SOP RECOVERY v stave 0x%02h – resync", $time, 6'(state_q));
      if (state_q == S_DECODE && !dec_count_ok)
        $warning("[%0t] %m: COUNT=0x%04h nie je násobok 4 – drop", $time, dec_count);
    end
  end

  // ── Invariant: bytes_left nesmie podtiecť ─────────────────────
  always_ff @(posedge clk) begin
    if (rst_n && state_q == S_PAYLOAD && axis_fire)
      assert (bytes_left_q > 0)
        else $fatal(1, "[%0t] %m: bytes_left podtečenie!", $time);
  end

  // ── SVA: payload FIFO overflow nemožný ────────────────────────
  no_payload_fifo_overflow: assert property (
    @(posedge clk) disable iff (!rst_n)
    word_complete |-> dfifo_w_ready
  ) else $fatal(1, "[%0t] %m: SVA FAIL – word_complete pri plnej payload FIFO!", $time);

  // ── SVA: header push len keď FIFO ready ───────────────────────
  no_header_fifo_overflow: assert property (
    @(posedge clk) disable iff (!rst_n)
    hfifo_push |-> hfifo_w_ready
  ) else $fatal(1, "[%0t] %m: SVA FAIL – hfifo_push pri plnej header FIFO!", $time);

  // ── SVA: S_DROP musí skončiť ──────────────────────────────────
  drop_state_must_end: assert property (
    @(posedge clk) disable iff (!rst_n)
    $rose(state_q == S_DROP) |-> ##[1:MAX_PKT_BYTES] (state_q == S_IDLE)
  ) else $error("[%0t] %m: SVA WARN – S_DROP trvá > %0d taktov", $time, MAX_PKT_BYTES);

  // ── SVA: S_DECODE trvá max 1-2 takty (FIFO ready guard) ───────
  decode_completes: assert property (
    @(posedge clk) disable iff (!rst_n)
    $rose(state_q == S_DECODE) |-> ##[1:4] (state_q != S_DECODE)
  ) else $error("[%0t] %m: SVA WARN – S_DECODE trvá > 4 takty (header FIFO backpressure?)",
               $time);

  // synthesis translate_on

endmodule : xfcp_rx_parser

`endif  // XFCP_RX_PARSER_SV
