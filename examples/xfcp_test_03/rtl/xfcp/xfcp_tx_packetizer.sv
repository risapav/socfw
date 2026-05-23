/**
 * @file  xfcp_tx_packetizer.sv
 * @brief XFCP Response Packetizer – serializuje 32-bit dáta do 8-bit AXI-Stream.
 *
 * Formát výstupného paketu:
 *   Bajt  | Pole
 *   ------|---------------------------
 *    0    | SOP = XFCP_SOP_RESP (0xFD)
 *    1    | TYPE (0x12=RESP_READ, 0x13=RESP_WRITE)
 *    2    | DEV_TYPE[15:8]
 *    3    | DEV_TYPE[7:0]
 *   4-19  | DEV_STR (16 bajtov, Big-Endian)
 *  20..N  | PAYLOAD (32-bit slová, MSB-first) – len pre RESP_READ
 *   end   | 0x00 + TLAST
 *
 * ╔══════════════════════════════════════════════════════════════╗
 * ║  PIPELINE ARCHITEKTÚRA v4 (priame plnenie slot0)             ║
 * ║                                                              ║
 * ║  Zmena oproti v3 (dual-slot s bootstrap blokom C):           ║
 * ║                                                              ║
 * ║  PROBLÉM v3:                                                 ║
 * ║    Blok A plnil vždy slot1. Blok C (bootstrap) presúval      ║
 * ║    slot1→slot0 keď slot0 prázdny. vopt (Questa optimalizátor)║
 * ║    analyzoval invariant assertion !(slot1=1,slot0=0) a       ║
 * ║    vymazal blok C ako "nedosiahnuteľný kód". Výsledok:       ║
 * ║    slot0 nikdy neplný → TVALID=0 → ST_PAYLOAD deadlock.     ║
 * ║                                                              ║
 * ║  RIEŠENIE v4:                                                ║
 * ║    Blok A priamo rozhoduje kam dáta ísť:                     ║
 * ║      slot0 prázdny → dáta do slot0  (priamy bootstrap)       ║
 * ║      slot0 plný, slot1 prázdny → dáta do slot1 (prefetch)    ║
 * ║    Žiadny bootstrap blok C → žiadna závislosť od invariantu. ║
 * ║    vopt nemôže eliminovať priame priradenie do slot0.        ║
 * ║                                                              ║
 * ║  read_data_ready = !slot0_valid_q || !slot1_valid_q          ║
 * ║    (FIFO môže zapisovať pokiaľ aspoň jeden slot voľný)       ║
 * ║                                                              ║
 * ║  Pipeline tok:                                               ║
 * ║    read_buffer FIFO (v engine)                               ║
 * ║       ↓  read_data_ready = !slot0_v || !slot1_v              ║
 * ║    SLOT 0 / SLOT 1  (priame plnenie)                         ║
 * ║       ↓  slot0_q[31:24] na výstup, shift po každom hs        ║
 * ║    AXI-Stream 8-bit                                          ║
 * ╚══════════════════════════════════════════════════════════════╝
 */

`ifndef XFCP_TX_PACKETIZER_SV
`define XFCP_TX_PACKETIZER_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_tx_packetizer #(
  parameter int           AXI_DATA_WIDTH = 32,
  parameter logic [15:0]  XFCP_ID_TYPE   = 16'h0001,
  parameter logic [127:0] XFCP_ID_STR    = "Hybrid AXIL"
) (
  input  wire clk,
  input  wire rst_n,

  // AXI-Stream výstup (8-bit)
  output logic [7:0] m_axis_tdata,
  output logic       m_axis_tvalid,
  input  wire        m_axis_tready,
  output logic       m_axis_tlast,

  // Riadiace signály od arbitera
  input  wire           resp_start,    // 1-takt pulz: začni odosielať paket
  input  wire [7:0]     resp_type,     // typ response (xfcp_op_e: READ/WRITE)
  input  wire [7:0]     resp_seq,      // SEQ z requestu (vrátiť v response)

  // Dátový kanál z engine read_buffer FIFO
  input  wire [AXI_DATA_WIDTH-1:0] read_data,
  input  wire                      read_data_valid,
  output logic                     read_data_ready,   // backpressure do FIFO

  // Synchronizácia s engineom
  input  wire  resp_done_i,      // engine: posledné slovo spracované
  output logic packetizer_idle,  // kombinačný: 1 keď ST_IDLE
  output logic resp_done_o       // 1-takt pulz po odoslaní TLAST
);

  // ============================================================
  // Lokálne konštanty
  // ============================================================
  // SOP(1) + TYPE(1) + SEQ(1) + DEV_TYPE(2) + DEV_STR(16) = 21 bajtov
  localparam int HEADER_BYTES = 21;

  // ============================================================
  // ONE-HOT FSM
  // ============================================================
  typedef enum logic [3:0] {
    ST_IDLE    = 4'b0001,  // čakanie na resp_start
    ST_HEADER  = 4'b0010,  // odosielanie 21-bajtového headeru
    ST_PAYLOAD = 4'b0100,  // odosielanie 32-bit slov (len RESP_READ)
    ST_DONE    = 4'b1000   // odoslanie 0x00+TLAST → IDLE
  } state_e;

  state_e state_q, state_n;

  // ============================================================
  // Registre
  // ============================================================
  logic [4:0] header_ptr_q;  // index aktuálne odosielaného bajtu (0–20)

  // ── Dual-slot buffer ──────────────────────────────────────────
  // slot0 = active: serializer odtiaľto číta (MSB-first shift)
  // slot1 = prefetch: naplní sa keď slot0 beží
  //
  // Invariant v4: slot0 sa vždy naplní PRED slot1.
  // Stav slot1=1, slot0=0 NIKDY nenastane → vopt to môže vedieť,
  // ale blok A to garantuje priamym plnením, nie cez bootstrap.
  logic [31:0] slot0_q,       slot1_q;
  logic        slot0_valid_q, slot1_valid_q;

  // Počítadlo odoslaných bajtov aktuálneho slova (0=MSB … 3=LSB)
  logic [1:0]  byte_cnt_q;

  // Latch pre resp_done_i – zachytí pulz aj keď príde skôr ako
  // posledný byte3 handshake (off-by-one scenár)
  logic done_latch_q;

  // ============================================================
  // Header ROM – packed vektor
  //
  // hdr_vec[ptr*8 +: 8] = bajt na pozícii ptr
  //   ptr=0:  SOP      (0xFD)
  //   ptr=1:  TYPE     (kombinačný z resp_type – stabilný od resp_start)
  //   ptr=2:  SEQ      (echo SEQ z requestu)
  //   ptr=3:  DEV_TYPE[15:8]
  //   ptr=4:  DEV_TYPE[7:0]
  //   ptr=5–20: DEV_STR (Big-Endian, 16 bajtov)
  // ============================================================
  logic [HEADER_BYTES*8-1:0] hdr_vec;

  always_comb begin
    hdr_vec[  0 +: 8] = XFCP_SOP_RESP;
    hdr_vec[  8 +: 8] = 8'(resp_type);
    hdr_vec[ 16 +: 8] = resp_seq;
    hdr_vec[ 24 +: 8] = XFCP_ID_TYPE[15:8];
    hdr_vec[ 32 +: 8] = XFCP_ID_TYPE[7:0];
    for (int i = 0; i < 16; i++)
      hdr_vec[(40 + i*8) +: 8] = XFCP_ID_STR[127 - i*8 -: 8];
  end

  // ============================================================
  // Pomocné signály
  // ============================================================
  wire hs        = m_axis_tvalid && m_axis_tready;
  wire done_flag = done_latch_q || resp_done_i;

  // ============================================================
  // BACKPRESSURE
  //
  // read_data_ready MUSÍ byť aktívne LEN v ST_PAYLOAD.
  //
  // Problém ktorý táto podmienka rieši:
  //   Arbiter nastavuje arb_q=ARB_WAIT_PKT už pri resp_start_pulse,
  //   čo je PRED vstupom packetizera do ST_PAYLOAD (packetizer
  //   najprv odosiela 20-bajtový header v ST_HEADER).
  //   Podmienka v endpointe (arb_q==ARB_WAIT_PKT) teda otvára
  //   read_data_ready cestu do engine FIFO počas ST_HEADER.
  //   Keď read_data_ready=1 a FIFO má dáta → FIFO popne dáta,
  //   ale packetizer je v ST_HEADER a blok A nespracuje read_data
  //   (podmienka state_q==ST_PAYLOAD je false) → dáta stratené.
  //   Pri vstupe do ST_PAYLOAD je FIFO prázdna → deadlock.
  //
  // Oprava: read_data_ready=0 mimo ST_PAYLOAD → FIFO čaká.
  //   Dáta ostanú v FIFO kým packetizer nevstúpi do ST_PAYLOAD.
  // ============================================================
  assign read_data_ready = (state_q == ST_PAYLOAD) &&
                           (!slot0_valid_q || !slot1_valid_q);

  // ============================================================
  // RESP_DONE LATCH
  //
  // resp_done_i je 1-takt pulz z enginu. Môže prísť:
  //   a) Pred posledným byte3 hs → done_latch_q zachytí a drží.
  //   b) Presne pri poslednom byte3 hs (off-by-one) → done_flag
  //      kombináciou zachytí v rovnakom takte.
  //
  // Latch sa čistí LEN keď je aj slot1 prázdny (multi-word guard).
  // Invariant (garantovaný arbitrom): resp_start_pulse sa nevystreľuje
  // kým engine nedokončí VŠETKY slová → v okamihu vstupu do ST_PAYLOAD
  // sú všetky dátové slová v read_buffer FIFO. Pre N-slovný READ má
  // slot1 word(N-1) keď sa odosiela word1 → exit condition ostáva
  // FALSE až do posledného slova, kde slot1 je prázdny → exit TRUE.
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_latch_q <= 1'b0;
    end else if (resp_done_i) begin
      done_latch_q <= 1'b1;
    end else if (state_q == ST_PAYLOAD &&
                 hs && byte_cnt_q[1] && byte_cnt_q[0] && done_flag && !slot1_valid_q) begin
      done_latch_q <= 1'b0;
    end
  end

  // ============================================================
  // DUAL-SLOT BUFFER + SHIFT SERIALIZER – sekvenčná logika
  //
  // Dve operácie každý takt (môžu nastať súčasne):
  //
  //  A) FIFO → SLOT  (priame plnenie, v4 architektúra)
  //     Ak slot0 prázdny: dáta idú do slot0.
  //     Ak slot0 plný a slot1 prázdny: dáta idú do slot1.
  //     Ak oba plné: nič (read_data_ready=0 → FIFO neassertuje valid).
  //
  //     KĽÚČOVÁ ZMENA oproti v3:
  //       v3 plnilo vždy slot1, potom bootstrap C presúval slot1→slot0.
  //       vopt vymazal bootstrap C ako "nedosiahnuteľný" (invariant).
  //       v4 plní slot0 priamo → žiadny bootstrap → vopt nezasahuje.
  //
  //  B) SERIALIZER
  //     word_consumed (hs && byte_cnt==3 && slot0 platný):
  //       slot0 ← slot1 (presun prefetch → active)
  //       slot1 ← uvoľni
  //       byte_cnt ← 0
  //     normálny hs (byte_cnt < 3):
  //       slot0_q <<= 8 (MSB-first posun)
  //       byte_cnt++
  //
  //  Súčasnosť A+B:
  //    B presúva slot1→slot0 a uvoľňuje slot1.
  //    Ak A súčasne zapisuje do slot1 (slot0 bol plný, teda
  //    read_data_ready=1 len ak slot1 prázdny):
  //    → slot1 dostane nové dáta v rovnakom takte ako sa presúva
  //    → výsledok: slot0 = starý slot1, slot1 = nové FIFO dáta ✓
  //
  //    Ak A zapisuje do slot0 (slot0 bol prázdny):
  //    → B nebeží (slot0_valid_q=0 → podmienka B false)
  //    → žiadny konflikt ✓
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      slot0_q       <= '0;
      slot0_valid_q <= 1'b0;
      slot1_q       <= '0;
      slot1_valid_q <= 1'b0;
      byte_cnt_q    <= '0;
    end else begin

      // ── Reset v IDLE ───────────────────────────────────────────
      // Čistí sloty po dokončení paketu. Zabraňuje "dirty slot"
      // pri opakovanom spustení.
      if (state_q == ST_IDLE) begin
        slot0_valid_q <= 1'b0;
        slot1_valid_q <= 1'b0;
        byte_cnt_q    <= '0;

      end else if (state_q == ST_PAYLOAD) begin

        // ── A) FIFO → SLOT (priame plnenie) ──────────────────────
        // Priorita: slot0 pred slot1.
        // Ak slot0 prázdny → priamo do slot0 (v4 kľúčová zmena).
        // Ak slot0 plný a slot1 prázdny → do slot1 (prefetch).
        if (read_data_valid) begin
          if (!slot0_valid_q) begin
            // Slot0 prázdny: priame plnenie (bootstrap bez extra bloku)
            slot0_q       <= read_data;
            slot0_valid_q <= 1'b1;
          end else if (!slot1_valid_q) begin
            // Slot0 plný, slot1 prázdny: prefetch
            slot1_q       <= read_data;
            slot1_valid_q <= 1'b1;
          end
          // Ak oba plné: read_data_ready=0 → FIFO neassertuje valid
          // → táto vetva nenastane
        end

        // ── B) Serializer ─────────────────────────────────────────
        // Guard slot0_valid_q: chráni pred posunom prázdneho slota.
        if (hs && slot0_valid_q && byte_cnt_q[1] && byte_cnt_q[0]) begin
          // word_consumed: posledný bajt odoslaný
          // Presun slot1 → slot0. Slot1 uvoľni.
          // Pozn: ak A súčasne zapísalo do slot1 (slot1 bol prázdny),
          // slot1_valid_q bude 1 z bloku A (vyhrá posledné priradenie
          // v always_ff – blok A je vyššie → blok B prepíše slot1_valid_q).
          // Riešenie: blok B explicitne kontroluje či A nastalo:
          //   A nastalo do slot1 ak: read_data_valid && slot0_valid_q && !slot1_valid_q
          //   (slot0 bol plný → A išlo do slot1)
          slot0_q       <= slot1_q;
          slot0_valid_q <= slot1_valid_q;
          // Slot1 sa uvoľní, pokiaľ A nenaplnilo v rovnakom takte
          slot1_valid_q <= (read_data_valid && slot0_valid_q && !slot1_valid_q);
          byte_cnt_q    <= '0;

        end else if (hs && slot0_valid_q) begin
          // Normálny shift: bajty 0–2
          slot0_q    <= {slot0_q[23:0], 8'h00};
          byte_cnt_q <= byte_cnt_q + 1'b1;
        end

      end // ST_PAYLOAD
    end
  end

  // ============================================================
  // Sekvenčná logika – FSM state + header pointer
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q      <= ST_IDLE;
      header_ptr_q <= '0;
    end else begin
      state_q <= state_n;
      if (state_q == ST_IDLE) begin
        header_ptr_q <= '0;
      end else if (state_q == ST_HEADER && hs) begin
        if (header_ptr_q != 5'(HEADER_BYTES - 1))
          header_ptr_q <= header_ptr_q + 1'b1;
      end
    end
  end

  // ============================================================
  // FSM – kombinačná logika
  // ============================================================
  always_comb begin
    state_n       = state_q;
    m_axis_tvalid = 1'b0;
    m_axis_tdata  = 8'h00;
    m_axis_tlast  = 1'b0;
    resp_done_o   = 1'b0;

    unique case (state_q)

      // ── ST_IDLE ───────────────────────────────────────────────
      ST_IDLE: begin
        if (resp_start) state_n = ST_HEADER;
      end

      // ── ST_HEADER: odošli 21 header bajtov ───────────────────
      // TVALID vždy 1 (header je vždy pripravený z ROM).
      // Po poslednom bajte (ptr==20): prechod podľa resp_type.
      ST_HEADER: begin
        m_axis_tvalid = 1'b1;
        m_axis_tdata  = hdr_vec[{header_ptr_q, 3'b000} +: 8];
        if (hs && header_ptr_q == 5'(HEADER_BYTES - 1)) begin
          if (resp_type == XFCP_OP_RESP_READ)
            state_n = ST_PAYLOAD;
          else
            state_n = ST_DONE;
        end
      end

      // ── ST_PAYLOAD: odošli 32-bit slová MSB-first ─────────────
      //
      // TVALID = slot0_valid_q.
      //   slot0_valid_q=0 → stall (čakáme na dáta z FIFO).
      //   Po oprave v4 nastane len ak FIFO je prázdna (engine ešte
      //   neskončil AXI READ transakciu).
      //
      // DATA = slot0_q[31:24] (aktuálny MSB, bez muxu).
      //
      // Prechod do ST_DONE: posledný bajt slova (byte_cnt==3)
      // AND done_flag=1 AND slot1 prázdny (multi-word guard).
      //
      // Multi-word guard (!slot1_valid_q):
      //   Arbiter spúšťa resp_start_pulse až keď engine dokončí VŠETKY
      //   slová → všetky dáta sú v read_buffer FIFO pred vstupom do
      //   ST_PAYLOAD. Pre N > 1 slov: slot1 obsahuje word(k+1) počas
      //   odosielania word(k) → exit FALSE. Na poslednom slove je
      //   slot1 prázdny → exit TRUE. Pre N=1: slot1 nikdy neplný → exit
      //   po prvom slove, rovnako ako predtým.
      ST_PAYLOAD: begin
        m_axis_tvalid = slot0_valid_q;
        m_axis_tdata  = slot0_q[31:24];
        if (hs && byte_cnt_q[1] && byte_cnt_q[0] && done_flag && !slot1_valid_q)
          state_n = ST_DONE;
      end

      // ── ST_DONE: odošli 0x00 + TLAST ─────────────────────────
      // Terminačný bajt XFCP protokolu.
      ST_DONE: begin
        m_axis_tvalid = 1'b1;
        m_axis_tdata  = 8'h00;
        m_axis_tlast  = 1'b1;
        if (m_axis_tready) begin
          resp_done_o = 1'b1;
          state_n     = ST_IDLE;
        end
      end

      default: state_n = ST_IDLE;
    endcase
  end

  // ============================================================
  // packetizer_idle – kombinačný
  // Arbiter vidí idle v rovnakom takte prechodu ST_DONE→ST_IDLE.
  // ============================================================
  assign packetizer_idle = (state_q == ST_IDLE);

  // ============================================================
  // Simulačné správy + assertions
  // ============================================================
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // 1. Výpisy viazané na zmenu stavu (Udalosti)
      if (state_q == ST_IDLE && state_n == ST_HEADER)
        $display("[%0t] %m: Štart paketu | type=0x%02h", $time, 8'(resp_type));

      if (state_q == ST_HEADER && state_n == ST_PAYLOAD)
        $display("[%0t] %m: Header done → ST_PAYLOAD", $time);

      if (state_q == ST_HEADER && state_n == ST_DONE)
        $display("[%0t] %m: Header done → ST_DONE (WRITE resp)", $time);

      if (resp_done_o)
        $display("[%0t] %m: Paket odoslaný (TLAST)", $time);

      // 2. Optimalizovaný DBG výpis pre Payload
      // Vypíšeme len vtedy, ak nastal AXI-Stream handshake (reálny pohyb dát)
      // ALEBO ak sa práve naplnil slot z FIFO.
      if (state_q == ST_PAYLOAD) begin
        if (hs || read_data_valid) begin
          $display("[%0t] %m: DATA hs=%b | slot0=%b/%08h slot1=%b/%08h byte=%0d done=%0b",
                   $time, hs, slot0_valid_q, slot0_q,
                   slot1_valid_q, slot1_q,
                   byte_cnt_q, done_flag);
        end
      end
    end
  end

  // Assertion v4: slot1 nesmie byť platný keď slot0 prázdny.
  // V architektúre v4 toto NIKDY nenastane (blok A plní slot0 ako prvý).
  // Ak assertion padne → chyba v logike bloku A alebo B.
  // Táto assertion je BEZPEČNÁ pre vopt: nevytvára "impossible state"
  // kontradikciu ktorá by eliminovala platné vetvy kódu.
  always_ff @(posedge clk) begin
    if (rst_n && state_q == ST_PAYLOAD)
      assert (!(slot1_valid_q && !slot0_valid_q))
        else $fatal(1, "[%0t] %m: INVARIANT FAIL – slot1 platný ale slot0 prázdny!", $time);
  end

  // TVALID nesmie byť aktívny bez platného slot0
  always_ff @(posedge clk) begin
    if (rst_n && state_q == ST_PAYLOAD && m_axis_tvalid)
      assert (slot0_valid_q)
        else $fatal(1, "[%0t] %m: INVARIANT FAIL – TVALID=1 ale slot0 prázdny!", $time);
  end
  // synthesis translate_on

endmodule : xfcp_tx_packetizer

`endif  // XFCP_TX_PACKETIZER_SV
