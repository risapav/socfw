/**
 * @file  xfcp_axi_engine.sv
 * @brief AXI4-Lite Engine pre XFCP protokol.
 *
 * @details
 *   Prekladá XFCP príkazy (READ/WRITE) na AXI4-Lite transakcie.
 *   Jeden engine obsluhuje jeden AXI slave – fabric inštanciuje
 *   N engineov pre N slaveov.
 *
 * ╔══════════════════════════════════════════════════════════════╗
 * ║  OPRAVY oproti predchádzajúcej verzii                        ║
 * ║                                                              ║
 * ║  FIX 1 – ST_IDLE: req_valid&&packetizer_idle → req_valid&&req_ready
 * ║    Pôvodná podmienka v kombinačnej a sekvenčnej logike       ║
 * ║    ST_IDLE nekontrolovala req_ready. Pre WRITE: req_ready    ║
 * ║    závisí od wfifo_valid, ale FSM prechod sa riadil len      ║
 * ║    req_valid&&packetizer_idle_i. Keď wfifo_valid=0:          ║
 * ║      - state_n = ST_WR_ADDR (engine štartuje WRITE)          ║
 * ║      - wfifo prázdna → ST_WR_DATA čaká navždy na WVALID     ║
 * ║      - výsledok: WATCHDOG TIMEOUT v stave 0x04              ║
 * ║    Oprava: oba bloky (comb + seq) používajú req_valid&&req_ready.║
 * ║                                                              ║
 * ║  Zachované vylepšenia z predchádzajúcich verzií:             ║
 * ║    - Sekvenčný WRITE FSM (AW pred W, eliminácia AW/W bug)    ║
 * ║    - Odstránenie aw_done_q/w_done_q/ar_done_q registrov      ║
 * ║    - Pipelined READ (AR pre N+1 kým čakáme na R pre N)       ║
 * ╚══════════════════════════════════════════════════════════════╝
 *
 * FSM stavy:
 *   WRITE: IDLE → ST_WR_ADDR → ST_WR_DATA → ST_WR_B → ST_NEXT → ST_DONE → IDLE
 *   READ:  IDLE → ST_RD_ADDR → ST_RD_WAIT → ST_NEXT → ST_DONE → IDLE
 *   Spoločné: ST_NEXT rozhoduje ďalší word alebo ST_DONE.
 */

`ifndef XFCP_AXI_ENGINE_SV
`define XFCP_AXI_ENGINE_SV

`default_nettype none

import axi_pkg::*;
import xfcp_pkg::*;

module xfcp_axi_engine #(
  parameter bit  LITTLE_ENDIAN  = 1'b1,   // 1 = byte-swap RDATA/WDATA
  parameter int  AXI_ADDR_WIDTH = 32,
  parameter int  AXI_DATA_WIDTH = 32,
  parameter int  COUNT_WIDTH    = 16,
  parameter int  FIFO_DEPTH     = 32,
  parameter int  TIMEOUT_VAL    = 1000    // watchdog v taktoch
) (

  input  wire                        clk,
  input  wire                        rst_n,

  axi4lite_if.master                 m_axil,

  // Request od parsera (cez fabric dispatch)
  input  wire [55:0]                 req_hdr,
  input  wire                        req_valid,
  output logic                       req_ready,

  // Write payload FIFO (parser → engine)
  input  wire [AXI_DATA_WIDTH-1:0]   write_data,
  input  wire                        write_data_valid,
  output logic                       write_data_ready,

  // Read data FIFO (engine → packetizer)
  output logic [AXI_DATA_WIDTH-1:0]  read_data,
  output logic                       read_data_valid,
  input  wire                        read_data_ready,

  // Riadiace signály pre packetizer/arbiter
  output logic                       resp_start,       // 1-takt pulz pri štarte
  output logic [7:0]                  resp_type,        // typ odpovede (xfcp_op_e)
  output logic                       resp_done,        // 1-takt pulz po poslednom slove
  input  wire                        packetizer_idle_i, // od eng_pkt_idle v endpointe

  output logic                       error_timeout     // watchdog prekročený
);

  localparam int ADDR_INC = AXI_DATA_WIDTH / 8;  // bajtový inkrement adresy (4 pre 32b)

  // Cast: port req_hdr (logic[55:0]) -> struct for field access inside module body
  xfcp_req_hdr_t req_hdr_s;
  assign req_hdr_s = xfcp_req_hdr_t'(req_hdr);

  // ============================================================
  // ONE-HOT FSM
  // ============================================================
  typedef enum logic [7:0] {
    ST_IDLE     = 8'b00000001,  // čakanie na request
    ST_WR_ADDR  = 8'b00000010,  // WRITE: AW channel handshake
    ST_WR_DATA  = 8'b00000100,  // WRITE: W channel handshake (po AW)
    ST_WR_B     = 8'b00001000,  // WRITE: čakanie na B response
    ST_RD_ADDR  = 8'b00010000,  // READ: AR channel handshake
    ST_RD_WAIT  = 8'b00100000,  // READ: čakanie na R + pipeline next AR
    ST_NEXT     = 8'b01000000,  // aktualizácia addr/rem, rozhodnutie ďalší word
    ST_DONE     = 8'b10000000   // čakanie na packetizer idle → IDLE
  } state_e;

  (* fsm_encoding = "one_hot" *) state_e state_q, state_n;

  // ============================================================
  // Registre
  // ============================================================
  logic [COUNT_WIDTH-1:0]    rem_q;   // zostatok bajtov na spracovanie
  logic [AXI_ADDR_WIDTH-1:0] addr_q;  // aktuálna AXI adresa
  xfcp_op_e                  op_q;   // zachytená operácia
  logic [15:0]               watchdog_q;

  // ============================================================
  // Byte-swap funkcia (LE ↔ BE konverzia)
  // ============================================================
  function automatic logic [AXI_DATA_WIDTH-1:0] byte_swap(
    input logic [AXI_DATA_WIDTH-1:0] d
  );
    logic [AXI_DATA_WIDTH-1:0] r;
    for (int i = 0; i < ADDR_INC; i++)
      r[i*8 +: 8] = d[(ADDR_INC-1-i)*8 +: 8];
    return r;
  endfunction

  // ============================================================
  // Write FIFO a Read FIFO
  //
  // wfifo: parser zapísuje payload, engine číta pri W handshake.
  // rfifo: engine zapísuje RDATA po AR/R, packetizer číta cez arbiter.
  // ============================================================
  logic [AXI_DATA_WIDTH-1:0] wfifo_raw;
  logic [AXI_DATA_WIDTH-1:0] wfifo_swapped;
  logic [AXI_DATA_WIDTH-1:0] rdata_swapped;
  logic                      wfifo_valid;
  logic                      wfifo_rd_en;

  // Byte-swap: aplikovaný iba ak LITTLE_ENDIAN=1
  assign wfifo_swapped = LITTLE_ENDIAN ? byte_swap(wfifo_raw)    : wfifo_raw;
  assign rdata_swapped = LITTLE_ENDIAN ? byte_swap(m_axil.RDATA) : m_axil.RDATA;

  // Write buffer FIFO: parser → engine (cez fabric wdata_valid gating)
  xfcp_fifo #(.DATA_WIDTH(AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) i_write_buffer (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .w_valid(write_data_valid), .w_data(write_data),  .w_ready(write_data_ready),
    .r_valid(wfifo_valid),      .r_data(wfifo_raw),   .r_ready(wfifo_rd_en)
  );

  // Read buffer FIFO: engine → packetizer
  // flush=0: packetizer číta asynchrónne cez arbiter;
  // flush by mohol zmazať dáta pred ich prečítaním.
  xfcp_fifo #(.DATA_WIDTH(AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) i_read_buffer (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .w_valid(m_axil.RVALID && m_axil.RREADY), .w_data(rdata_swapped), .w_ready(),
    .r_valid(read_data_valid), .r_data(read_data), .r_ready(read_data_ready)
  );

  // ============================================================
  // Sekvenčná logika
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= ST_IDLE;
      watchdog_q    <= '0;
      error_timeout <= 1'b0;
      addr_q        <= '0;
      rem_q         <= '0;
      op_q          <= XFCP_OP_ID;
    end else begin
      state_q <= state_n;

      case (state_q)

        // ── ST_IDLE ──────────────────────────────────────────────
        // FIX 1: Podmienka zmenená z (req_valid && packetizer_idle_i)
        // na (req_valid && req_ready).
        //
        // Pôvodná chyba: pre WRITE platí req_ready = ST_IDLE &&
        // packetizer_idle_i && wfifo_valid. Ak wfifo_valid=0,
        // req_ready=0 ale pôvodná podmienka bola stále true →
        // engine štartoval WRITE bez dát → ST_WR_DATA deadlock.
        //
        // Oprava: req_valid&&req_ready je štandardný AXI handshake
        // a implicitne obsahuje wfifo_valid pre WRITE.
        ST_IDLE: begin
          watchdog_q    <= '0;
          error_timeout <= 1'b0;
          if (req_valid && req_ready) begin       // ← FIX 1
            rem_q  <= req_hdr_s.count;
            addr_q <= req_hdr_s.addr;
            op_q   <= req_hdr_s.opcode;
          end
        end

        // Watchdog beží vo všetkých AXI čakacích stavoch
        ST_WR_ADDR,
        ST_WR_DATA,
        ST_WR_B,
        ST_RD_ADDR,
        ST_RD_WAIT: begin
          watchdog_q <= watchdog_q + 1'b1;
          if (watchdog_q >= 16'(TIMEOUT_VAL)) error_timeout <= 1'b1;
        end

        // ── ST_NEXT ───────────────────────────────────────────────
        // Posun na ďalší word: dekrementuj rem, inkrementuj addr.
        // Watchdog reset: nový word = nová transakcia.
        ST_NEXT: begin
          rem_q  <= (rem_q > COUNT_WIDTH'(ADDR_INC))
                    ? rem_q - COUNT_WIDTH'(ADDR_INC) : '0;
          addr_q <= addr_q + AXI_ADDR_WIDTH'(ADDR_INC);
          watchdog_q <= '0;
        end

        default: begin end
      endcase
    end
  end

  // ============================================================
  // Kombinačná logika – FSM prechody + AXI výstupy
  // ============================================================
  always_comb begin
    state_n        = state_q;
    resp_start     = 1'b0;
    wfifo_rd_en    = 1'b0;

    // AXI predvolené hodnoty:
    // VALID kanály = 0 (engine neposiela nič ak nie je v správnom stave)
    // READY pre response kanály = 1 (engine vždy akceptuje B a R)
    m_axil.AWVALID = 1'b0;
    m_axil.AWADDR  = addr_q;
    m_axil.AWPROT  = 3'b000;
    m_axil.WVALID  = 1'b0;
    m_axil.WDATA   = wfifo_swapped;
    m_axil.WSTRB   = {ADDR_INC{1'b1}};  // all-ones: zápis všetkých bajtov
    m_axil.BREADY  = 1'b1;
    m_axil.ARVALID = 1'b0;
    m_axil.ARADDR  = addr_q;
    m_axil.ARPROT  = 3'b000;
    m_axil.RREADY  = 1'b1;

    // ── req_ready ─────────────────────────────────────────────
    // WRITE: vyžaduje wfifo_valid aby fabric nedispatchoval request
    //        pred príchodom payload dát z parsera.
    // READ:  bez podmienky na FIFO (žiadny payload).
    // Spoločne: ST_IDLE && packetizer_idle_i (engine nesmie začať
    //           kým packetizer odosiela predchádzajúcu odpoveď).
    if (req_hdr_s.opcode == XFCP_OP_WRITE)
      req_ready = (state_q == ST_IDLE) && packetizer_idle_i && wfifo_valid;
    else
      req_ready = (state_q == ST_IDLE) && packetizer_idle_i;

    if (error_timeout) begin
      // Watchdog: ukončíme transakciu, engine sa resyncuje cez ST_DONE
      state_n = ST_DONE;

    end else begin
      case (state_q)

        // ── ST_IDLE ───────────────────────────────────────────────
        // FIX 1 (kombinačná časť): prechod riadený req_valid&&req_ready.
        // Pôvod: (req_valid && packetizer_idle_i) – bez wfifo_valid →
        // state_n=ST_WR_ADDR aj keď req_ready=0. Opravené na req_ready.
        ST_IDLE: begin
          if (req_valid && req_ready) begin       // ← FIX 1
            resp_start = 1'b1;
            if (req_hdr_s.opcode == XFCP_OP_WRITE)
              state_n = ST_WR_ADDR;
            else
              state_n = ST_RD_ADDR;
          end
        end

        // ── ST_WR_ADDR: AW channel ────────────────────────────────
        // AXI4-Lite: AW MUSÍ predchádzať W. Slave nie je povinný
        // akceptovať W pred AW. Sekvenčné stavy eliminujú AW/W bug.
        ST_WR_ADDR: begin
          m_axil.AWVALID = 1'b1;
          if (m_axil.AWREADY)
            state_n = ST_WR_DATA;
        end

        // ── ST_WR_DATA: W channel ─────────────────────────────────
        // AW handshake zaručene prebehol (predchádzajúci stav).
        // WVALID aktívny iba ak FIFO má dáta (wfifo_valid).
        // Pop FIFO (wfifo_rd_en) viazaný na W handshake.
        ST_WR_DATA: begin
          m_axil.WVALID = wfifo_valid;
          if (m_axil.WVALID && m_axil.WREADY) begin
            wfifo_rd_en = 1'b1;   // pop: dáta sú teraz na drôte
            state_n     = ST_WR_B;
          end
        end

        // ── ST_WR_B: čakanie na write response ───────────────────
        // BREADY = 1 (defaultné). Slave môže zdržať BVALID.
        ST_WR_B: begin
          if (m_axil.BVALID)
            state_n = ST_NEXT;
        end

        // ── ST_RD_ADDR: AR channel ────────────────────────────────
        ST_RD_ADDR: begin
          m_axil.ARVALID = 1'b1;
          if (m_axil.ARREADY)
            state_n = ST_RD_WAIT;
        end

        // ── ST_RD_WAIT: čakanie na R + pipeline next AR ───────────
        //
        // PIPELINING: Pri multi-word READ posielame AR pre slovo N+1
        // kým čakáme na RDATA slova N. Tým sa prekryje AR latencia.
        //
        // Podmienky pre pipeline AR:
        //   1. RVALID=1 (dostávame aktuálne RDATA)
        //   2. rem_q > ADDR_INC (zostáva ďalší word)
        //   3. ARREADY: overujeme v rovnakom cykle
        //
        // ARADDR = addr_q + ADDR_INC (next word).
        // addr_q sa inkrementuje až v ST_NEXT, preto explicitne
        // addujeme ADDR_INC tu.
        //
        // Ak ARREADY=1: ST_NEXT → ST_RD_WAIT (preskočí ST_RD_ADDR)
        // Ak ARREADY=0: ST_NEXT → ST_RD_ADDR (AR sa zopakuje)
        ST_RD_WAIT: begin
          if (m_axil.RVALID) begin
            state_n = ST_NEXT;

            // Pipeline: AR pre nasledujúci word
            if (rem_q > COUNT_WIDTH'(ADDR_INC)) begin
              m_axil.ARVALID = 1'b1;
              m_axil.ARADDR  = addr_q + AXI_ADDR_WIDTH'(ADDR_INC);
            end
          end
        end

        // ── ST_NEXT: aktualizácia addr/rem + rozhodnutie ─────────
        // rem_q a addr_q sa aktualizujú v sekvenčnej logike.
        // Tu rozhodujeme stav pre nasledujúci cyklus.
        ST_NEXT: begin
          if (rem_q <= COUNT_WIDTH'(ADDR_INC)) begin
            // Posledný word – koniec transakcie
            state_n = ST_DONE;
          end else begin
            // Ďalší word
            if (op_q == XFCP_OP_WRITE) begin
              state_n = ST_WR_ADDR;
            end else begin
              // READ pipeline: ak AR pre nasledujúci word prebehol
              // (ARVALID && ARREADY v predchádzajúcom takte),
              // preskočíme ST_RD_ADDR.
              if (m_axil.ARVALID && m_axil.ARREADY)
                state_n = ST_RD_WAIT;
              else
                state_n = ST_RD_ADDR;
            end
          end
        end

        // ── ST_DONE: čakaj kým packetizer spracuje response ───────
        // Engine zostáva tu kým arbiter neodošle celý paket.
        // packetizer_idle_i = 1 keď packetizer je v ST_IDLE.
        ST_DONE: begin
          if (packetizer_idle_i) state_n = ST_IDLE;
        end

        default: state_n = ST_IDLE;
      endcase
    end
  end

  // ============================================================
  // resp_done: 1-takt pulz pri vstupe do ST_DONE
  //
  // Generovaný kombinačne z ST_NEXT keď je posledný word
  // (rem_q <= ADDR_INC). Arbiter použije tento pulz na
  // inkrementovanie eng_done_cnt a spustenie packetizera.
  // ============================================================
  assign resp_done = (state_q == ST_NEXT) &&
                     (rem_q <= COUNT_WIDTH'(ADDR_INC)) &&
                     !error_timeout;

  // ============================================================
  // resp_type: určuje typ response paketu
  //
  // READ aj ID vracajú RESP_READ (payload s dátami).
  // WRITE vracia RESP_WRITE (len header, bez payloadu).
  // ============================================================
  assign resp_type = (op_q == XFCP_OP_READ ||
                      op_q == XFCP_OP_ID)
                     ? XFCP_OP_RESP_READ
                     : XFCP_OP_RESP_WRITE;

  // ============================================================
  // Simulačné správy
  // ============================================================
  // synthesis translate_off
  logic error_timeout_q;

  always_ff @(posedge clk) begin
    if (rst_n) begin

      // 1. Watchdog – loguj len pri nástupe (edge detect)
      if (error_timeout && !error_timeout_q)
        $error("[%0t] %m: WATCHDOG TIMEOUT stav=0x%02h", $time, 8'(state_q));

      // 2. Koniec transakcie
      if (state_q == ST_DONE && state_n == ST_IDLE)
        $display("[%0t] %m: Transakcia dokončená | op=0x%02h | addr=0x%08h",
                $time, 8'(op_q), addr_q);

      // 3. Štart novej transakcie
      if (state_q == ST_IDLE && state_n != ST_IDLE)
        $display("[%0t] %m: START op=0x%02h addr=0x%08h pkt_idle=%0b wfifo=%0b",
                $time, 8'(req_hdr_s.opcode), req_hdr_s.addr,
                packetizer_idle_i, wfifo_valid);

      // 4. AXI handshaky – len pri reálnom handshake (VALID && READY)
      if ((m_axil.AWVALID && m_axil.AWREADY) ||
          (m_axil.WVALID  && m_axil.WREADY)  ||
          (m_axil.ARVALID && m_axil.ARREADY))
        $display("[%0t] %m: AXI REQ HS | AW(V=%b,R=%b) W(V=%b,R=%b) AR(V=%b,R=%b)",
                $time, m_axil.AWVALID, m_axil.AWREADY,
                m_axil.WVALID, m_axil.WREADY,
                m_axil.ARVALID, m_axil.ARREADY);

      // 5. AXI responses – len keď prídu
      if ((state_q == ST_WR_B    && m_axil.BVALID) ||
          (state_q == ST_RD_WAIT && m_axil.RVALID))
        $display("[%0t] %m: AXI RESP RCV | BVALID=%0b RVALID=%0b RDATA=0x%08h",
                $time, m_axil.BVALID, m_axil.RVALID, m_axil.RDATA);

      // Edge detect register
      error_timeout_q <= error_timeout;

    end else begin
      error_timeout_q <= 1'b0;
    end
  end
  // synthesis translate_on

endmodule : xfcp_axi_engine

`endif // XFCP_AXI_ENGINE_SV
