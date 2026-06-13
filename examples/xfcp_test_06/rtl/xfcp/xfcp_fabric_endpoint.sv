/**
 * @file  xfcp_fabric_endpoint.sv
 * @brief Pipelined XFCP multi-device endpoint – opravená verzia.
 *
 * @details
 *   Prepája jeden XFCP port s NUM_SLAVES AXI-Lite zariadeniami.
 *   Garantuje in-order odpovede pomocou order_fifo.
 *
 * ── Opravy oproti prvej verzii ──────────────────────────────────
 *
 *   1. arb_sel_q registrovaný len pri ofifo_rready && ofifo_rvalid
 *   2. resp_start generovaný z resp_start_pulse (1-takt registrácia)
 *   3. wdata_valid maskovaný na slave_sel_q (aktívny write engine)
 *   4. eng_busy blokuje ďalší dispatch na obsadený slave
 *   5. wdata_ready = eng_wdata_ready[slave_sel_q] (nie OR)
 *   6. rdata_ready maskovaný na arb_sel_q && ARB_WAIT_PKT
 *   7. wdata_stage register: lomi cestu parser rd_ptr_q/req_op_r -> engine write_buffer
 */

`ifndef XFCP_FABRIC_ENDPOINT_SV
`define XFCP_FABRIC_ENDPOINT_SV

`default_nettype none

import axi_pkg::*;
import xfcp_pkg::*;

module xfcp_fabric_endpoint #(
  parameter int NUM_SLAVES       = 4,
  parameter int AXI_ADDR_WIDTH   = 32,
  parameter int AXI_DATA_WIDTH   = 32,
  parameter int ORDER_FIFO_DEPTH = 16,

  // Byte-swap: 0 = data MSB-first on wire, no AXI swap (matches original xfcp_axil_bridge).
  // 1 = byte-swap WDATA before AXI write and RDATA after AXI read (little-endian).
  parameter bit LITTLE_ENDIAN    = 1'b0,

  parameter logic [AXI_ADDR_WIDTH-1:0] SLAVE_BASE [NUM_SLAVES] = '{
    32'h0000_0000,
    32'h0001_0000,
    32'h0002_0000,
    32'h0003_0000
  },
  parameter logic [AXI_ADDR_WIDTH-1:0] SLAVE_MASK [NUM_SLAVES] = '{
    32'hFFFF_0000,
    32'hFFFF_0000,
    32'hFFFF_0000,
    32'hFFFF_0000
  }
)(
  input wire clk,
  input wire rst_n,

  axi4s_if.slave  xfcp_in,
  axi4s_if.master xfcp_out,

  axi4lite_if.master m_axil [NUM_SLAVES],

  // High only while response packet is being transmitted.
  // Debug/optional post-TX flush helper; not a full transaction-busy signal.
  output logic endpoint_busy_o,

  // Debug pulses: 1-cycle, combinational — wire to axil_diag_ctrl
  output logic dbg_sop_o,       // good SOP received by parser
  output logic dbg_hdr_o,       // header successfully decoded (hfifo_push)
  output logic dbg_drop_o,      // parser drop event
  output logic dbg_req_o,       // valid request dispatched to engine
  output logic dbg_resp_o,      // packetizer response started
  output logic dbg_bad_hdr_o,   // parser decode error
  output logic dbg_recovery_o   // parser sop_recovery
);

  // synthesis translate_off
  initial begin
    if (NUM_SLAVES < 1 || NUM_SLAVES > 16)
      $fatal(1, "%m: NUM_SLAVES musí byť 1–16, got %0d", NUM_SLAVES);
  end
  // synthesis translate_on

  localparam int SEL_W = (NUM_SLAVES > 1) ? $clog2(NUM_SLAVES) : 1;

  typedef struct packed {
    logic [SEL_W-1:0] sel;
    xfcp_op_e         op;
    logic [7:0]       seq;
  } order_entry_t;

  // ── Parser výstupy ───────────────────────────────────────────
  xfcp_req_hdr_t             req_hdr;
  logic                      req_valid;
  logic                      req_ready;
  logic [AXI_DATA_WIDTH-1:0] wdata;
  logic                      wdata_valid_raw;  // priamo z parsera
  logic                      wdata_valid;      // gated: platné len s req_valid
  logic                      wdata_ready;
  logic                      invalid_req;      // req_valid && !dec_valid
  logic                      drop_wdata_q;     // draining invalid WRITE payload
  logic [13:0]               drop_cnt_q;       // remaining words to drain

  // ── Address decoder ──────────────────────────────────────────
  logic [SEL_W-1:0] dec_sel;
  logic             dec_valid;

  always_comb begin
    dec_sel   = '0;
    dec_valid = 1'b0;
    for (int i = NUM_SLAVES-1; i >= 0; i--) begin
      if ((req_hdr.addr & SLAVE_MASK[i]) == SLAVE_BASE[i]) begin
        dec_sel   = SEL_W'(i);
        dec_valid = 1'b1;
      end
    end
  end

  // req_stage registers: registered versions of FIFO-derived signals.
  // All latched when req_valid=1, breaking rd_ptr_q -> downstream combinatorial
  // chains. dec_valid_r/req_valid_r/invalid_req_r are unconditionally registered
  // to sever the rd_ptr_q -> req_ready feedback loop (path 3, -1.9 ns).
  logic [SEL_W-1:0]              dec_sel_r;
  logic                          dec_valid_r;
  logic                          req_valid_r;
  logic                          invalid_req_r;
  xfcp_op_e                      req_op_r;
  logic [7:0]                    req_seq_r;
  logic [15:0]                   req_count_r;
  logic [AXI_ADDR_WIDTH-1:0]     req_addr_r;
  logic                          ofifo_wvalid_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dec_sel_r     <= '0;
      dec_valid_r   <= 1'b0;
      req_valid_r   <= 1'b0;
      invalid_req_r <= 1'b0;
      req_op_r      <= xfcp_pkg::XFCP_OP_READ;
      req_seq_r     <= '0;
      req_count_r   <= '0;
      req_addr_r    <= '0;
    end else begin
      // Gate with req_valid so dec_valid_r/invalid_req_r return to 0 when
      // req_valid=0, preventing stale FIFO content from causing premature req_fire.
      dec_valid_r   <= req_valid && dec_valid;
      req_valid_r   <= req_valid;
      invalid_req_r <= req_valid && !dec_valid;  // == invalid_req, gated
      if (req_valid) begin
        dec_sel_r   <= dec_sel;
        req_op_r    <= req_hdr.opcode;
        req_seq_r   <= req_hdr.seq;
        req_count_r <= req_hdr.count;
        req_addr_r  <= req_hdr.addr;
      end
    end
  end

  // req_hdr_staged: fully-registered version of req_hdr for engine dispatch.
  // Eliminates timing path: hfifo.rd_ptr_q -> FIFO_LUT_RAM -> req_hdr.addr -> engine.addr_q.
  xfcp_req_hdr_t req_hdr_staged;
  always_comb begin
    req_hdr_staged.opcode = req_op_r;
    req_hdr_staged.seq    = req_seq_r;
    req_hdr_staged.count  = req_count_r;
    req_hdr_staged.addr   = req_addr_r;
  end

  // ── slave_sel_q: registrovaný pri req handshake ──────────────
  // Používaný pre wdata routing počas write transakcie.
  // Uses dec_sel_r to break rd_ptr_q -> dec_sel -> slave_sel_q path (path 4).
  logic [SEL_W-1:0] slave_sel_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) slave_sel_q <= '0;
    else if (req_valid && req_ready)
      slave_sel_q <= dec_sel_r;
  end

  // ── Engine signály ───────────────────────────────────────────
  logic                      eng_busy          [NUM_SLAVES];
  logic                      eng_req_ready     [NUM_SLAVES];
  logic                      eng_req_ready_r   [NUM_SLAVES]; // registrovane: lomi hfifo->req_ready loop
  logic                      eng_wdata_ready   [NUM_SLAVES];
  logic [AXI_DATA_WIDTH-1:0] eng_rdata         [NUM_SLAVES];
  logic                      eng_rdata_valid   [NUM_SLAVES];
  logic                      eng_resp_done     [NUM_SLAVES];
  logic [7:0]                eng_resp_type     [NUM_SLAVES];
  logic [7:0]                eng_resp_status   [NUM_SLAVES]; // STATUS byte z enginu
  logic                      eng_pkt_idle      [NUM_SLAVES];

  // ── Order FIFO signály (deklarované skoro – používané v busy trackeri)
  order_entry_t ofifo_wdata;
  order_entry_t ofifo_rdata;
  logic         ofifo_wvalid, ofifo_wready;
  logic         ofifo_rvalid, ofifo_rready;

  // ── Order FIFO head register ──────────────────────────────────
  // Lomi cestu: ofifo.rd_ptr_q -> mem[rd_ptr] -> rdata.sel ->
  //   eng_done_rdy[sel] -> ofifo_rready -> do_read -> count_q  (-1.138 ns).
  // Pattern: FIFO sa popne automaticky ked head register je prazdny
  // (ofifo_rready = assign). Arbiter cita len z registrovaneho head_r (FF).
  order_entry_t ofifo_head_r;
  logic         ofifo_head_valid_r;
  logic         ofifo_head_consume;  // nastavene arbiterom v always_comb

  // ── Busy tracker + done counter ─────────────────────────────
  // eng_done_cnt počíta koľko resp_done pulzov prišlo pre každý slave
  // kým ich arbiter nespracoval. Potrebné keď WRITE+READ sú oba in-flight
  // na rovnakom slave – každý generuje resp_done, každý potrebuje pop.
  // Veľkosť 2 bity = max 3 čakajúce done (viac ako dosť pre single-outstanding).
  logic [1:0]             eng_done_cnt [NUM_SLAVES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_SLAVES; i++) begin
        eng_busy[i]     <= 1'b0;
        eng_done_cnt[i] <= '0;
      end
    end else begin
      for (int i = 0; i < NUM_SLAVES; i++) begin
        // Busy: nastav pri dispatch (len pre platne requesty), cisti pri done
        if (req_valid && req_ready && !invalid_req && dec_sel == SEL_W'(i))
          eng_busy[i] <= 1'b1;
        else if (eng_resp_done[i])
          eng_busy[i] <= 1'b0;

        // Done counter: increment pri resp_done, decrement ked arbiter popne head.
        // ofifo_head_consume nahradzuje (ofifo_rready && ofifo_rvalid && rdata.sel==i):
        // ofifo_head_r.sel je FF (nie async FIFO read) -> timing-safe.
        case ({eng_resp_done[i],
               (ofifo_head_consume && (ofifo_head_r.sel == SEL_W'(i)))})
          2'b10: eng_done_cnt[i] <= eng_done_cnt[i] + 1'b1; // len done
          2'b01: if (eng_done_cnt[i] > 0)
                   eng_done_cnt[i] <= eng_done_cnt[i] - 1'b1; // len pop
          2'b11: ; // done + pop sucasne -> bez zmeny
          default: ;
        endcase
      end
    end
  end

  // Pre arbiter: slave je "done" ak counter > 0.
  // eng_resp_done[i] odstranene z OR: eliminuje cestu
  // engine.rem_q -> resp_done (comb) -> ofifo_rready -> count_q (-1.029 ns).
  // eng_done_cnt sa inkrementuje v rovnakom cykle ako resp_done, takze
  // v T+1 je (eng_done_cnt > 0) ekvivalentne s (eng_resp_done T).
  logic [NUM_SLAVES-1:0] eng_done_rdy;
  always_comb begin
    for (int i = 0; i < NUM_SLAVES; i++)
      eng_done_rdy[i] = (eng_done_cnt[i] > 0);
  end

  // ── Order FIFO inštancia ─────────────────────────────────────

  xfcp_fifo #(
    .DATA_WIDTH ($bits(order_entry_t)),
    .DEPTH      (ORDER_FIFO_DEPTH)
  ) i_order_fifo (
    .clk     (clk), .rst_n (rst_n), .flush (1'b0),
    .w_valid (ofifo_wvalid), .w_data (ofifo_wdata), .w_ready (ofifo_wready),
    .r_valid (ofifo_rvalid), .r_data (ofifo_rdata), .r_ready (ofifo_rready)
  );

  // FIFO pop: automaticky ked head register je prazdny a FIFO ma data.
  // Arbiter nastavuje ofifo_head_consume (nie ofifo_rready priamo).
  assign ofifo_rready = !ofifo_head_valid_r && ofifo_rvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ofifo_head_r       <= '0;
      ofifo_head_valid_r <= 1'b0;
    end else begin
      // Load: head prazdny + FIFO ma zaznam -> nacitaj a popni FIFO
      if (!ofifo_head_valid_r && ofifo_rvalid) begin
        ofifo_head_r       <= ofifo_rdata;
        ofifo_head_valid_r <= 1'b1;
      end else if (ofifo_head_consume) begin
        // Arbiter spotreboval head register
        ofifo_head_valid_r <= 1'b0;
      end
    end
  end

  // ── Request dispatch ─────────────────────────────────────────
  //
  // req_ready aktívne len ak:
  //   1. adresa platná
  //   2. engine nie je busy
  //   3. order_fifo má miesto
  //   4. Pre READ: engine musí byť voľný (žiadny in-flight WRITE)
  //      → zaručuje že READ vždy číta po zápise (AXI ordering)
  //
  // eng_busy sleduje či engine má in-flight transakciu.
  // Kedže AXI-Lite je single-outstanding, engine busy = WRITE alebo
  // READ prebieha. Blokujeme ďalší dispatch kým engine neskončí.
  logic req_fire;
  assign invalid_req  = req_valid && !dec_valid;
  assign req_fire     = req_valid && req_ready;
  // req_ready: uses registered dec_sel_r/dec_valid_r/invalid_req_r to break the
  // rd_ptr_q -> req_ready -> rd_ptr_q.CE feedback loop (path 3, -1.9 ns).
  // Delays valid-request dispatch by 1 cycle (D -> D+1); functionally correct
  // since engine and FIFO pop stay in sync (both use the same registered signals).
  assign req_ready    = invalid_req_r ? 1'b1 :
                        dec_valid_r && !eng_busy[dec_sel_r] && eng_req_ready_r[dec_sel_r]
                        && ofifo_wready && !ofifo_wvalid_r;
  assign ofifo_wvalid = ofifo_wvalid_r;
  assign ofifo_wdata  = '{sel: dec_sel_r, op: req_op_r, seq: req_seq_r};

  // eng_req_ready_r: registrovana verzia eng_req_ready[i].
  // Lomi cestu: hfifo.mem[rd_ptr_q] -> req_hdr.opcode -> engine.req_ready
  //   -> eng_req_ready[dec_sel_r] -> req_ready -> do_read -> rd_ptr_q  (-1.296 ns).
  // Bezpecnost: eng_req_ready je urovnovy stavovy signal (nie 1-cyklovy pulz),
  // takze registracia pridava max 1 cyklus latencie bez rizika deadlocku.
  //
  // eng_req_ready_r: resetovaný na 0 medzi transakciami (req_valid_r=0).
  // Dôvod: req_hdr_staged je platný až od T=1 (1 cyklus po prvom req_valid=1).
  // V T=0 by engine videl stale opcode a mohol by dať req_ready=1 (READ vetva)
  // pre WRITE transakciu. Reset medzi transakciami zaistí, že každá nová transakcia
  // začína s eng_req_ready_r=0 a správnou hodnotou sa naplní až pri req_valid_r=1.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      for (int i = 0; i < NUM_SLAVES; i++) eng_req_ready_r[i] <= 1'b0;
    else if (!req_valid_r)
      for (int i = 0; i < NUM_SLAVES; i++) eng_req_ready_r[i] <= 1'b0;
    else
      for (int i = 0; i < NUM_SLAVES; i++) eng_req_ready_r[i] <= eng_req_ready[i];
  end

  // ofifo_wvalid_r: delay order FIFO push 1 cycle after req_fire.
  // At req_fire time, dec_sel_r/req_op_r/req_seq_r capture combinatorial values
  // at the clock edge; they are valid at the next cycle for the FIFO write.
  // !ofifo_wvalid_r in req_ready ensures at most one push is pending at a time.
  // !invalid_req_r (nie !invalid_req): lomi cestu hfifo.mem -> dec_valid ->
  //   !invalid_req -> ofifo_wvalid_r.D. Funkcne ekvivalentne: req_fire uz
  //   zavisi od dec_valid_r (cez req_ready), takze invalid_req_r je konzistentne.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ofifo_wvalid_r <= 1'b0;
    else        ofifo_wvalid_r <= req_fire && !invalid_req_r;
  end

  // ── wdata routing ─────────────────────────────────────────────
  // drain_wdata: 1 pocas odstranovania payloadu neplatneho WRITEu.
  // wdata_valid maskovany pocas drain, wdata_ready=1 pre okamzite odcerpanie.
  logic [SEL_W-1:0] wdata_sel;
  // drain_wdata: uses registered signals to break rd_ptr_q -> drain_wdata path.
  wire  drain_wdata  = drop_wdata_q ||
                       (invalid_req_r && req_op_r == XFCP_OP_WRITE);
  // wdata_sel: req_valid_r breaks rd_ptr_q -> req_valid -> wdata_sel path (path 1).
  assign wdata_sel   = req_valid_r ? dec_sel_r : slave_sel_q;
  assign wdata_valid = wdata_valid_raw && !drain_wdata;

  // wdata_stage: pipeline register between parser data FIFO and engine write FIFO.
  // Breaks timing path: parser rd_ptr_q / req_op_r -> engine i_write_buffer.mem.
  // Stage holds one word until selected engine write FIFO accepts it (backpressure).
  logic [AXI_DATA_WIDTH-1:0] wdata_stage_data_r;
  logic [SEL_W-1:0]          wdata_stage_sel_r;
  logic                      wdata_stage_valid_r;

  wire wdata_stage_fire_w =
    wdata_stage_valid_r && eng_wdata_ready[wdata_stage_sel_r];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wdata_stage_valid_r <= 1'b0;
      wdata_stage_data_r  <= '0;
      wdata_stage_sel_r   <= '0;
    end else if (drain_wdata) begin
      wdata_stage_valid_r <= 1'b0;
    end else if (!wdata_stage_valid_r || wdata_stage_fire_w) begin
      wdata_stage_valid_r <= wdata_valid;
      if (wdata_valid) begin
        wdata_stage_data_r <= wdata;
        wdata_stage_sel_r  <= wdata_sel;
      end
    end
  end

  assign wdata_ready = drain_wdata ? 1'b1 :
                       (!wdata_stage_valid_r || wdata_stage_fire_w);

  // ── Invalid WRITE payload drain ──────────────────────────────
  // drop_wdata_q zostava 1 kym sa neodcerpa COUNT/4 slov z parsera.
  // drain_wdata je kombinacny: platny aj v rovnakom takte ako req_fire.
  // req_count_r registered in req_stage block above; use it here.
  wire [13:0] req_words = req_count_r[15:2];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      drop_wdata_q <= 1'b0;
      drop_cnt_q   <= '0;
    end else if (invalid_req_r && req_fire &&
                 req_op_r == XFCP_OP_WRITE) begin
      // Zachyt pocet slov; odcitaj slovo ak sa v tomto takte odcerpava
      drop_cnt_q   <= req_words - {13'b0, drain_wdata && wdata_valid_raw};
      drop_wdata_q <= (req_words - {13'b0, drain_wdata && wdata_valid_raw}) != '0;
    end else if (drop_wdata_q && wdata_valid_raw) begin
      drop_cnt_q <= drop_cnt_q - 14'd1;
      if (drop_cnt_q == 14'd1)
        drop_wdata_q <= 1'b0;
    end
  end

  // ── Response Arbiter ─────────────────────────────────────────
  typedef enum logic [1:0] {
    ARB_IDLE, ARB_WAIT_ENG, ARB_WAIT_PKT
  } arb_state_e;

  arb_state_e    arb_q, arb_n;
  logic [SEL_W-1:0] arb_sel_q;
  logic          resp_start_pulse;
  logic          resp_start_q;
  logic          packetizer_idle;
  logic          packetizer_idle_q;  // registrovaný – ochrana pred same-cycle exit

  // Multiplexované výstupy pre packetizer
  // resp_type_q: registrovaný pri resp_start_pulse z order_fifo
  // (engine op_q môže byť prepísaný novým requestom)
  xfcp_op_e                  resp_type_q;    // registrovany, stabil pocas paketu
  xfcp_op_e                  resp_type;
  logic [7:0]                resp_seq_q;    // SEQ z order_fifo, stable pocas paketu
  logic [7:0]                resp_status_q; // STATUS zachyteny pri resp_start_pulse
  logic [AXI_DATA_WIDTH-1:0] rdata;
  logic                      rdata_valid;
  logic                      rdata_ready;
  // resp_start_pulse fires same cycle as eng_resp_done; arb_sel_q lags 1 cycle.
  // Hold resp_done for 2 cycles so packetizer's done_latch_q is always set.
  // resp_done_mux_q: registered, breaks i_order_fifo.mem/engine.rem_q ->
  // packetizer.state_q combinatorial paths (-2.033 ns and -2.028 ns).
  // After registration resp_done_i arrives at cycle N+1..N+2 (same as resp_start_q).
  logic                      resp_done_held_q;
  logic                      resp_done_mux_q;

  // Pipeline register (skid buffer) between engine FIFO MUX output and packetizer.
  // Breaks the critical timing path: eng_rdata[arb_sel_q] -> packetizer/slot0_q.
  // rdata_ready_int: pop from engine FIFO when packetizer is consuming (rdata_ready=1)
  // OR when the register is empty (!rdata_valid_r=1) and we are in ARB_WAIT_PKT.
  // The arb_q == ARB_WAIT_PKT guard in the engine's read_data_ready prevents premature
  // FIFO pops outside the response transmission window.
  logic [AXI_DATA_WIDTH-1:0] rdata_r;
  logic                      rdata_valid_r;
  wire                       rdata_ready_int = rdata_ready || !rdata_valid_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_r       <= '0;
      rdata_valid_r <= 1'b0;
    end else if (rdata_ready_int) begin
      rdata_r       <= rdata;
      // Guard with arb_q==ARB_WAIT_PKT: prevents false pre-load in the cycle
      // where resp_start_pulse fires but arb_q has not yet registered to
      // ARB_WAIT_PKT (rdata_ready_int=1 because !rdata_valid_r, but the
      // engine FIFO pop guard blocks the actual pop — without this guard
      // rdata_valid_r would latch 1 without a pop, producing a ghost-valid
      // that fills slot1 with stale data on the first ST_PAYLOAD cycle).
      rdata_valid_r <= rdata_valid && (arb_q == ARB_WAIT_PKT);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_done_held_q <= 1'b0;
      resp_done_mux_q  <= 1'b0;
    end else begin
      resp_done_held_q <= resp_start_pulse;
      resp_done_mux_q  <= resp_start_pulse || resp_done_held_q;
    end
  end

  always_comb begin
    rdata       = eng_rdata      [arb_sel_q];
    rdata_valid = eng_rdata_valid[arb_sel_q];
    resp_type   = resp_type_q;
  end

  // Arbiter sekvenčná
  // arb_sel_q a resp_type_q sa zachytávajú PRESNE pri resp_start_pulse
  // (takt keď arbiter popne záznam z order_fifo a spustí packetizer).
  // Zachytenie pri každom IDLE takte by mohlo prepísať hodnotu starým
  // záznamom pred pop-om.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_q         <= ARB_IDLE;
      arb_sel_q     <= '0;
      resp_type_q   <= xfcp_pkg::XFCP_OP_RESP_WRITE;
      resp_seq_q    <= '0;
      resp_status_q <= '0;
    end else begin
      arb_q <= arb_n;
      // Zachyt sel/type/seq/status z head registra (FF, nie async FIFO read).
      if (resp_start_pulse) begin
        arb_sel_q     <= ofifo_head_r.sel;
        resp_type_q   <= xfcp_op_e'(eng_resp_type[ofifo_head_r.sel]);
        resp_seq_q    <= ofifo_head_r.seq;
        resp_status_q <= eng_resp_status[ofifo_head_r.sel];
      end else if (arb_q == ARB_IDLE && arb_n == ARB_WAIT_ENG) begin
        arb_sel_q   <= ofifo_head_r.sel;
      end
    end
  end

  // Arbiter kombinačná
  //
  // KRITICKÉ: Nový response sa smie spustiť LEN keď packetizer_idle=1.
  // Inak by druhý resp_start prišiel počas odosielania prvého paketu.
  always_comb begin
    arb_n              = arb_q;
    ofifo_head_consume = 1'b0;
    resp_start_pulse   = 1'b0;

    case (arb_q)
      ARB_IDLE: begin
        // Cakame kym mame zaznam v head registri A packetizer je volny.
        // ofifo_head_valid_r (FF) nahradzuje ofifo_rvalid (async FIFO).
        if (ofifo_head_valid_r && packetizer_idle) begin
          if (eng_done_rdy[ofifo_head_r.sel]) begin
            // Engine dokoncil - spotrebujeme head a spustime packetizer
            ofifo_head_consume = 1'b1;
            resp_start_pulse   = 1'b1;
            arb_n              = ARB_WAIT_PKT;
          end else begin
            // Engine este pracuje - cakame
            arb_n = ARB_WAIT_ENG;
          end
        end
      end

      ARB_WAIT_ENG: begin
        // Cakame kym engine dokoncil AXI transakciu
        if (eng_done_rdy[arb_sel_q]) begin
          ofifo_head_consume = 1'b1;
          resp_start_pulse   = 1'b1;
          arb_n              = ARB_WAIT_PKT;
        end
      end

      ARB_WAIT_PKT: begin
        // Cakame kym packetizer odosle cely paket.
        // Pouzivame registrovany idle (packetizer_idle_q) aby sme
        // neopustili tento stav v rovnakom takte ked resp_start_q=1.
        if (packetizer_idle_q && packetizer_idle)
          arb_n = ARB_IDLE;
      end

      default: arb_n = ARB_IDLE;
    endcase
  end

  // resp_start registrovaný 1 takt
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) resp_start_q <= 1'b0;
    else        resp_start_q <= resp_start_pulse;
  end

  // Registrovaný packetizer_idle – zabráni okamžitému prechodu
  // ARB_WAIT_PKT→ARB_IDLE skôr ako packetizer stihne opustiť ST_IDLE.
  // Pri resp_start_pulse sa nasilne nastaví na 0 (paket začína).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      packetizer_idle_q <= 1'b1;
    else if (resp_start_pulse)
      packetizer_idle_q <= 1'b0;  // paket práve štartuje → nie sme idle
    else
      packetizer_idle_q <= packetizer_idle;
  end

  // Busy only during TX phase (ARB_WAIT_PKT): response is being transmitted.
  // Not raised during ARB_WAIT_ENG so write-data bytes can still reach the engine
  // (write payload follows the header in the same UART byte stream).
  assign endpoint_busy_o = (arb_q == ARB_WAIT_PKT);

  // ── RX Parser ────────────────────────────────────────────────
  xfcp_rx_parser #(
    .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
  ) i_parser (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(xfcp_in.TDATA),
    .s_axis_tvalid(xfcp_in.TVALID),
    .s_axis_tready(xfcp_in.TREADY),
    .s_axis_tlast(xfcp_in.TLAST),
    .req_hdr(req_hdr),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .write_data(wdata),
    .write_data_valid(wdata_valid_raw),
    .write_data_ready(wdata_ready),
    .pass_valid(),
    .pass_data(),
    .pass_last(),
    .pass_ready(1'b0),
    .error_protocol(),
    .dbg_sop_o      (dbg_sop_o),
    .dbg_hdr_o      (dbg_hdr_o),
    .dbg_drop_o     (dbg_drop_o),
    .dbg_bad_hdr_o  (dbg_bad_hdr_o),
    .dbg_recovery_o (dbg_recovery_o)
  );

  assign dbg_req_o  = req_fire && !invalid_req;
  assign dbg_resp_o = resp_start_pulse;

  // ── AXI Engine inštancie ─────────────────────────────────────
  //
  // packetizer_idle_i pre každý engine:
  //   Engine môže spustiť AXI transakciu kedykoľvek keď dostane req.
  //   Nesmie čakať na packetizer – to by zablokovalo pipeline.
  //   Signál 1 = "packetizer nie je zaneprázdnený MOJOU odpoveďou".
  //   Keďže arbiter riadi kedy ktorý engine komunikuje s packetizerom,
  //   engine vždy dostane packetizer_idle_i=1 okrem keď packetizer
  //   práve odosiela jeho response (arb_q==ARB_WAIT_PKT && arb_sel_q==i).
  // eng_pkt_idle[i]: engine i vidi packetizer ako idle ak
  // packetizer je naozaj idle ALEBO prave obsluhuje iny engine.
  genvar gi;
  generate
    for (gi = 0; gi < NUM_SLAVES; gi++) begin : g_engine
      assign eng_pkt_idle[gi] = packetizer_idle
                                 || (arb_q != ARB_WAIT_PKT)
                                 || (arb_sel_q != SEL_W'(gi));

      xfcp_axi_engine #(
        .LITTLE_ENDIAN  (LITTLE_ENDIAN),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
      ) i_engine (
        .clk   (clk), .rst_n (rst_n),
        .m_axil (m_axil[gi]),
        .req_hdr   (req_hdr_staged),
        // req_valid: uses registered signals in sync with req_ready (Fix A).
        // Fires at D+1 together with FIFO pop; dec_sel_r/dec_valid_r stable by then.
        .req_valid (req_valid_r && dec_valid_r && !eng_busy[gi]
                    && dec_sel_r == SEL_W'(gi) && ofifo_wready),
        .req_ready (eng_req_ready[gi]),
        .write_data       (wdata_stage_data_r),
        .write_data_valid (wdata_stage_valid_r && (wdata_stage_sel_r == SEL_W'(gi))),
        .write_data_ready (eng_wdata_ready[gi]),
        .read_data       (eng_rdata[gi]),
        .read_data_valid (eng_rdata_valid[gi]),
        .read_data_ready (rdata_ready_int && (arb_sel_q == SEL_W'(gi))
                          && (arb_q == ARB_WAIT_PKT)),
        .resp_start        (),
        .resp_type         (eng_resp_type[gi]),
        .resp_done         (eng_resp_done[gi]),
        .packetizer_idle_i (eng_pkt_idle[gi]),
        .error_timeout     (),
        .resp_status_o     (eng_resp_status[gi])
      );
    end : g_engine
  endgenerate

  // ── TX Packetizer ────────────────────────────────────────────
  xfcp_tx_packetizer #(
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
  ) i_packetizer (
    .clk(clk), .rst_n(rst_n),
    .m_axis_tdata(xfcp_out.TDATA),   .m_axis_tvalid(xfcp_out.TVALID),
    .m_axis_tready(xfcp_out.TREADY), .m_axis_tlast(xfcp_out.TLAST),
    .resp_start      (resp_start_q),
    .resp_type       (resp_type),
    .resp_seq        (resp_seq_q),
    .resp_status_i   (resp_status_q),
    .read_data       (rdata_r),
    .read_data_valid (rdata_valid_r),
    .read_data_ready (rdata_ready),
    .resp_done_i     (resp_done_mux_q),
    .packetizer_idle (packetizer_idle),
    .resp_done_o     ()
  );

  // ── Simulačné správy ─────────────────────────────────────────
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (req_fire) begin
        if (!dec_valid)
          $warning("[%0t] %m: Neplatná adresa 0x%08h!", $time, req_hdr.addr);
        else
          $display("[%0t] %m: Request addr=0x%08h → slave[%0d]",
                   $time, req_hdr.addr, dec_sel);
      end
      if (resp_start_q)
        $display("[%0t] %m: RESP slave[%0d] → packetizer type=0x%02h rdy=%0b",
                 $time, arb_sel_q, 8'(resp_type_q), eng_done_rdy[arb_sel_q]);
      if (arb_q != arb_n)
        $display("[%0t] %m: ARB %0d->%0d arb_sel=%0d head_sel=%0d head_v=%0b ofifo_rv=%0b pkt_idle=%0b/%0b done_rdy=%0b",
                 $time, arb_q, arb_n, arb_sel_q, ofifo_head_r.sel,
                 ofifo_head_valid_r, ofifo_rvalid, packetizer_idle, packetizer_idle_q,
                 eng_done_rdy);
    end
  end
  // synthesis translate_on

endmodule : xfcp_fabric_endpoint

`endif // XFCP_FABRIC_ENDPOINT_SV
