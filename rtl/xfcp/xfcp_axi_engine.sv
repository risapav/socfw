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
 * ║                                                              ║
 * ║  FIX 2 – READ pipeline odstránená (bola mŕtvy kód):          ║
 * ║    ST_RD_WAIT nastavoval ARVALID kombinačne; ST_NEXT videl    ║
 * ║    ARVALID=0 (reset na začiatku always_comb) → vždy ST_RD_ADDR║
 * ║    READ je teraz čisto sekvenčný: ST_RD_ADDR→ST_RD_WAIT→ST_NEXT║
 * ║                                                              ║
 * ║  FIX 3 – RREADY viazaný na rfifo_w_ready_w:                  ║
 * ║    Predtým RREADY=1 vždy → pri plnom rfifo boli RDATA stratené║
 * ║    Oprava: RREADY=rfifo_w_ready_w (backpressure na AXI slave) ║
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
  input  wire [$bits(xfcp_req_hdr_t)-1:0] req_hdr,
  input  wire                        req_valid,
  output logic                       req_ready,
  input  wire                        req_is_write_i,  // pre-decoded FF: opcode==WRITE

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

  output logic                       error_timeout,    // watchdog prekroceny
  output logic [7:0]                 resp_status_o     // XFCP status: OK/SLVERR/DECERR/TIMEOUT
);

  localparam int ADDR_INC = AXI_DATA_WIDTH / 8;  // bajtový inkrement adresy (4 pre 32b)

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
    ST_RD_WAIT  = 8'b00100000,  // READ: čakanie na R response
    ST_NEXT     = 8'b01000000,  // aktualizácia addr/rem, rozhodnutie ďalší word
    ST_DONE     = 8'b10000000   // čakanie na packetizer idle → IDLE
  } state_e;

  (* fsm_encoding = "one-hot" *) state_e state_q, state_n;

  // ============================================================
  // Registre
  // ============================================================
  logic [COUNT_WIDTH-1:0]    rem_q;       // zostatok bajtov na spracovanie
  logic [AXI_ADDR_WIDTH-1:0] addr_q;     // aktualna AXI adresa
  xfcp_op_e                  op_q;       // zachytena operacia
  logic [15:0]               watchdog_q;
  xfcp_status_e              axi_status_q; // first-error-wins: OK / SLVERR / DECERR


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
  logic                      rfifo_w_ready_w;
  // Interne signaly read buffer FIFO (pred vystupnym registrom)
  logic [AXI_DATA_WIDTH-1:0] rfifo_rdata_w;
  logic                      rfifo_rvalid_w;
  logic                      rfifo_rready_w;
  logic                      read_data_ready_r; // registered: skrati kriticku cestu state_q -> rd_ptr_q

  // Byte-swap: aplikovaný iba ak LITTLE_ENDIAN=1
  assign wfifo_swapped = LITTLE_ENDIAN ? byte_swap(wfifo_raw)    : wfifo_raw;
  assign rdata_swapped = LITTLE_ENDIAN ? byte_swap(m_axil.RDATA) : m_axil.RDATA;

  // Write buffer FIFO: parser → engine (cez fabric wdata_valid gating)
  xfcp_fifo #(.DATA_WIDTH(AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) i_write_buffer (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .w_valid(write_data_valid), .w_data(write_data),  .w_ready(write_data_ready),
    .r_valid(wfifo_valid),      .r_data(wfifo_raw),   .r_ready(wfifo_rd_en)
  );

  // Read buffer FIFO: engine -> vystupny register -> packetizer.
  //
  // Kriticka cesta (STA): state_q.ST_PAYLOAD -> read_data_ready (port) ->
  //   rfifo_rready_w -> i_read_buffer.rd_ptr_q (~7 LUT, prilis pomale pri 125 MHz).
  //
  // Oprava: read_data_ready_r je registrovana verzia read_data_ready.
  //   Kratsia cesta: read_data_ready_r (FF) -> rfifo_rready_w -> rd_ptr_q (~3 LUT).
  //   Pridava 1-takt latency pri signalizacii "downstream spotreboval data",
  //   co je prijatelne (vysilanie je UART/AXI-S, ms-latency dominuje).
  xfcp_fifo #(.DATA_WIDTH(AXI_DATA_WIDTH), .DEPTH(FIFO_DEPTH)) i_read_buffer (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .w_valid(m_axil.RVALID && m_axil.RREADY), .w_data(rdata_swapped), .w_ready(rfifo_w_ready_w),
    .r_valid(rfifo_rvalid_w), .r_data(rfifo_rdata_w), .r_ready(rfifo_rready_w)
  );

  // read_data_ready_r: lomi dlhu kombinacnu cestu od packetizera
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) read_data_ready_r <= 1'b0;
    else        read_data_ready_r <= read_data_ready;
  end

  // rfifo_rready_w: pop FIFO ked vystupny register moze prijat data.
  //   Podmienka: slot je prazdny (!read_data_valid) ALEBO downstream spotreboval
  //   minuly takt (read_data_ready_r). Registracia ready-vstupu skracuje STA.
  assign rfifo_rready_w = !read_data_valid || read_data_ready_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_data       <= '0;
      read_data_valid <= 1'b0;
    end else if (rfifo_rready_w) begin
      read_data       <= rfifo_rdata_w;
      read_data_valid <= rfifo_rvalid_w;
    end
  end

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
      axi_status_q  <= XFCP_ST_OK;
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
          axi_status_q  <= XFCP_ST_OK;  // reset na zaciatku kazdej transakcie
          if (req_valid && req_ready) begin       // FIX 1
            rem_q  <= req_hdr_s.count;  // req_hdr = req_hdr_staged from endpoint (already FF-staged)
            addr_q <= req_hdr_s.addr;   // path: req_addr_r(FF) -> req_hdr_staged(comb) -> addr_q.D
            op_q   <= req_hdr_s.opcode;
          end
        end

        // Watchdog beží vo všetkých AXI čakacích stavoch
        ST_WR_ADDR,
        ST_WR_DATA,
        ST_RD_ADDR: begin
          watchdog_q <= watchdog_q + 1'b1;
          if (watchdog_q >= 16'(TIMEOUT_VAL)) error_timeout <= 1'b1;
        end

        // ── ST_WR_B: watchdog + zachyt BRESP (first-error-wins) ─────
        ST_WR_B: begin
          watchdog_q <= watchdog_q + 1'b1;
          if (watchdog_q >= 16'(TIMEOUT_VAL)) error_timeout <= 1'b1;
          if (m_axil.BVALID && (axi_status_q == XFCP_ST_OK)) begin
            unique case (m_axil.BRESP)
              2'b10:   axi_status_q <= XFCP_ST_AXI_SLVERR;
              2'b11:   axi_status_q <= XFCP_ST_AXI_DECERR;
              default: ;
            endcase
          end
        end

        // ── ST_RD_WAIT: watchdog + zachyt RRESP (first-error-wins) ──
        ST_RD_WAIT: begin
          watchdog_q <= watchdog_q + 1'b1;
          if (watchdog_q >= 16'(TIMEOUT_VAL)) error_timeout <= 1'b1;
          if (m_axil.RVALID && m_axil.RREADY && (axi_status_q == XFCP_ST_OK)) begin
            unique case (m_axil.RRESP)
              2'b10:   axi_status_q <= XFCP_ST_AXI_SLVERR;
              2'b11:   axi_status_q <= XFCP_ST_AXI_DECERR;
              default: ;
            endcase
          end
        end

        // ── ST_NEXT ───────────────────────────────────────────────
        // Posun na dalsi word: dekrementuj rem, inkrementuj addr.
        // Watchdog reset: novy word = nova transakcia.
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
    m_axil.RREADY  = rfifo_w_ready_w;

    // ── req_ready ─────────────────────────────────────────────
    // WRITE: vyžaduje wfifo_valid aby fabric nedispatchoval request
    //        pred príchodom payload dát z parsera.
    // READ:  bez podmienky na FIFO (žiadny payload).
    // Spoločne: ST_IDLE && packetizer_idle_i (engine nesmie začať
    //           kým packetizer odosiela predchádzajúcu odpoveď).
    if (req_is_write_i)
      req_ready = (state_q == ST_IDLE) && packetizer_idle_i && wfifo_valid;
    else
      req_ready = (state_q == ST_IDLE) && packetizer_idle_i;

    // FIX G: ST_DONE and ST_IDLE always handle their own exit transitions.
    // error_timeout must NOT override ST_DONE. If it did, error_timeout would
    // keep the engine in ST_DONE forever (error_timeout only clears in ST_IDLE,
    // which is unreachable → deadlock). Without ST_DONE→IDLE, resp_done never
    // fires → order_fifo in xfcp_fabric_endpoint deadlocks too.
    if (state_q == ST_DONE) begin
      if (packetizer_idle_i) state_n = ST_IDLE;

    end else if (state_q == ST_IDLE) begin
      if (req_valid && req_ready) begin
        resp_start = 1'b1;
        if (req_is_write_i)
          state_n = ST_WR_ADDR;
        else
          state_n = ST_RD_ADDR;
      end

    end else if (error_timeout) begin
      // Timeout in active AXI state: abort to ST_DONE.
      // resp_done fires combinationally (assign below) to unblock order_fifo.
      state_n = ST_DONE;

    end else begin
      case (state_q)

        // ── ST_WR_ADDR: AW channel ────────────────────────────────
        ST_WR_ADDR: begin
          m_axil.AWVALID = 1'b1;
          if (m_axil.AWREADY)
            state_n = ST_WR_DATA;
        end

        // ── ST_WR_DATA: W channel ─────────────────────────────────
        ST_WR_DATA: begin
          m_axil.WVALID = wfifo_valid;
          if (m_axil.WVALID && m_axil.WREADY) begin
            wfifo_rd_en = 1'b1;
            state_n     = ST_WR_B;
          end
        end

        // ── ST_WR_B: čakanie na write response ───────────────────
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

        // ── ST_RD_WAIT: čakanie na R response ────────────────────
        ST_RD_WAIT: begin
          if (m_axil.RVALID && m_axil.RREADY) state_n = ST_NEXT;
        end

        // ── ST_NEXT: aktualizácia addr/rem + rozhodnutie ─────────
        ST_NEXT: begin
          if (rem_q <= COUNT_WIDTH'(ADDR_INC)) begin
            state_n = ST_DONE;
          end else begin
            if (op_q == XFCP_OP_WRITE)
              state_n = ST_WR_ADDR;
            else
              state_n = ST_RD_ADDR;
          end
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
  //
  // FIX G: aj pri timeout musí resp_done vystreliť, inak
  // order_fifo v xfcp_fabric_endpoint deadlockuje navždy.
  // ============================================================
  assign resp_done = ((state_q == ST_NEXT) && (rem_q <= COUNT_WIDTH'(ADDR_INC)) && !error_timeout)
                   || (error_timeout && (state_q != ST_DONE) && (state_q != ST_IDLE));

  // ============================================================
  // resp_status_o: XFCP STATUS byte pre packetizer.
  // Timeout ma prioritu nad AXI BRESP/RRESP errormi.
  assign resp_status_o = error_timeout ? 8'(XFCP_ST_TIMEOUT) : 8'(axi_status_q);

  // resp_type: urcuje typ response paketu
  //
  // READ aj ID vracajú RESP_READ (payload s dátami).
  // WRITE vracia RESP_WRITE (len header, bez payloadu).
  //
  // FIX G: timeout pri READ operácii musí vrátiť RESP_WRITE
  // (bez payload dat), inak packetizer zasekne v ST_PAYLOAD
  // a čaká na read_data_valid ktorý nikdy nepríde.
  // ============================================================
  assign resp_type = (error_timeout && (state_q != ST_DONE) && (state_q != ST_IDLE))
                     ? XFCP_OP_RESP_WRITE
                     : ((op_q == XFCP_OP_READ || op_q == XFCP_OP_ID)
                        ? XFCP_OP_RESP_READ
                        : XFCP_OP_RESP_WRITE);

  // ============================================================
  // Simulačné správy
  // ============================================================
  // synthesis translate_off
  logic error_timeout_q;

  always_ff @(posedge clk) begin
    if (rst_n) begin

      // 1. Watchdog – loguj len pri nástupe (edge detect)
      if (error_timeout && !error_timeout_q)
        $warning("[%0t] %m: WATCHDOG TIMEOUT stav=0x%02h", $time, 8'(state_q));

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

      // 5. AXI responses – len ked pridu
      if (state_q == ST_WR_B && m_axil.BVALID)
        $display("[%0t] %m: AXI RESP RCV | BVALID=1 BRESP=%0b status=0x%02h",
                $time, m_axil.BRESP, 8'(axi_status_q));
      if (state_q == ST_RD_WAIT && m_axil.RVALID)
        $display("[%0t] %m: AXI RESP RCV | RVALID=1 RRESP=%0b RDATA=0x%08h status=0x%02h",
                $time, m_axil.RRESP, m_axil.RDATA, 8'(axi_status_q));

      // Edge detect register
      error_timeout_q <= error_timeout;

    end else begin
      error_timeout_q <= 1'b0;
    end
  end
  // synthesis translate_on

endmodule : xfcp_axi_engine

`endif // XFCP_AXI_ENGINE_SV
