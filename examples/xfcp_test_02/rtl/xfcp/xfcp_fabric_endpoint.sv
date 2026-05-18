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

  // Fabric ID string (vrátený packetizerom v každom response header)
  parameter logic [127:0] ID_STR = "XFCP-FABRIC    ",

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

  axi4lite_if.master m_axil [NUM_SLAVES]
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
  } order_entry_t;

  // ── Parser výstupy ───────────────────────────────────────────
  xfcp_req_hdr_t             req_hdr;
  logic                      req_valid;
  logic                      req_ready;
  logic [AXI_DATA_WIDTH-1:0] wdata;
  logic                      wdata_valid_raw;  // priamo z parsera
  logic                      wdata_valid;      // gated: platné len s req_valid
  logic                      wdata_ready;

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

  // ── slave_sel_q: registrovaný pri req handshake ──────────────
  // Používaný pre wdata routing počas write transakcie.
  // POZOR: parser posiela wdata PRED req_fire → slave_sel_q by mohol
  // byť neaktualizovaný. Preto používame kombinačný dec_sel pre routing.
  logic [SEL_W-1:0] slave_sel_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) slave_sel_q <= '0;
    else if (req_valid && req_ready)
      slave_sel_q <= dec_sel;
  end

  // ── Engine signály ───────────────────────────────────────────
  logic                      eng_busy        [NUM_SLAVES];
  logic                      eng_req_ready   [NUM_SLAVES];
  logic                      eng_wdata_ready [NUM_SLAVES];
  logic [AXI_DATA_WIDTH-1:0] eng_rdata       [NUM_SLAVES];
  logic                      eng_rdata_valid [NUM_SLAVES];
  logic                      eng_resp_done   [NUM_SLAVES];
  logic                      eng_pkt_idle    [NUM_SLAVES];

  // ── Order FIFO signály (deklarované skoro – používané v busy trackeri)
  order_entry_t ofifo_wdata;
  order_entry_t ofifo_rdata;
  logic         ofifo_wvalid, ofifo_wready;
  logic         ofifo_rvalid, ofifo_rready;

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
        // Busy: nastav pri dispatch, čisti pri done
        if (req_valid && req_ready && dec_sel == SEL_W'(i))
          eng_busy[i] <= 1'b1;
        else if (eng_resp_done[i])
          eng_busy[i] <= 1'b0;

        // Done counter: increment pri resp_done, decrement pri arbiter pop
        case ({eng_resp_done[i],
               (ofifo_rready && ofifo_rvalid && ofifo_rdata.sel == SEL_W'(i))})
          2'b10: eng_done_cnt[i] <= eng_done_cnt[i] + 1'b1; // len done
          2'b01: if (eng_done_cnt[i] > 0)
                   eng_done_cnt[i] <= eng_done_cnt[i] - 1'b1; // len pop
          2'b11: ; // done + pop súčasne → bez zmeny
          default: ;
        endcase
      end
    end
  end

  // Pre arbiter: slave je "done" ak counter > 0 alebo práve prišiel pulz
  logic [NUM_SLAVES-1:0] eng_done_rdy;
  always_comb begin
    for (int i = 0; i < NUM_SLAVES; i++)
      eng_done_rdy[i] = (eng_done_cnt[i] > 0) || eng_resp_done[i];
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
  assign req_fire     = req_valid && req_ready;
  assign req_ready    = dec_valid
                        && !eng_busy[dec_sel]
                        && eng_req_ready[dec_sel]
                        && ofifo_wready;
  assign ofifo_wvalid = req_fire;
  assign ofifo_wdata  = '{sel: dec_sel, op: req_hdr.opcode};

  // ── wdata routing ─────────────────────────────────────────────
  // Po zmene parsera: header sa pushuje PRED payload pre WRITE.
  // req_valid=1 je zaručene platné pred wdata_valid_raw=1.
  // dec_sel je správny keď wdata_valid_raw príde.
  logic [SEL_W-1:0] wdata_sel;
  assign wdata_sel   = req_valid ? dec_sel : slave_sel_q;
  assign wdata_valid = wdata_valid_raw;  // bez gatingu – req_valid je vždy pred
  assign wdata_ready = eng_wdata_ready[wdata_sel];

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
  xfcp_op_e                  resp_type_q;  // registrovaný, stabíl počas paketu
  xfcp_op_e                  resp_type;
  logic [AXI_DATA_WIDTH-1:0] rdata;
  logic                      rdata_valid;
  logic                      rdata_ready;
  logic                      resp_done_mux;

  always_comb begin
    rdata         = eng_rdata      [arb_sel_q];
    rdata_valid   = eng_rdata_valid[arb_sel_q];
    resp_done_mux = eng_resp_done  [arb_sel_q];
    resp_type     = resp_type_q;   // stabilný registrovaný výstup
  end

  // Arbiter sekvenčná
  // arb_sel_q a resp_type_q sa zachytávajú PRESNE pri resp_start_pulse
  // (takt keď arbiter popne záznam z order_fifo a spustí packetizer).
  // Zachytenie pri každom IDLE takte by mohlo prepísať hodnotu starým
  // záznamom pred pop-om.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_q       <= ARB_IDLE;
      arb_sel_q   <= '0;
      resp_type_q <= xfcp_pkg::XFCP_OP_RESP_WRITE;
    end else begin
      arb_q <= arb_n;
      // Zachyť sel a op presne keď arbiter popne FIFO (resp_start_pulse)
      if (resp_start_pulse) begin
        arb_sel_q   <= ofifo_rdata.sel;
        resp_type_q <= (ofifo_rdata.op == xfcp_pkg::XFCP_OP_READ)
                       ? xfcp_pkg::XFCP_OP_RESP_READ
                       : xfcp_pkg::XFCP_OP_RESP_WRITE;
      end else if (arb_q == ARB_IDLE && arb_n == ARB_WAIT_ENG) begin
        // Zachyť aj pri prechode do WAIT_ENG (engine ešte nie je hotový)
        arb_sel_q   <= ofifo_rdata.sel;
        resp_type_q <= (ofifo_rdata.op == xfcp_pkg::XFCP_OP_READ)
                       ? xfcp_pkg::XFCP_OP_RESP_READ
                       : xfcp_pkg::XFCP_OP_RESP_WRITE;
      end
    end
  end

  // Arbiter kombinačná
  //
  // KRITICKÉ: Nový response sa smie spustiť LEN keď packetizer_idle=1.
  // Inak by druhý resp_start prišiel počas odosielania prvého paketu.
  always_comb begin
    arb_n            = arb_q;
    ofifo_rready     = 1'b0;
    resp_start_pulse = 1'b0;

    case (arb_q)
      ARB_IDLE: begin
        // Čakáme kým máme záznam v order_fifo A packetizer je voľný
        if (ofifo_rvalid && packetizer_idle) begin
          if (eng_done_rdy[ofifo_rdata.sel]) begin
            // Engine dokončil – spustíme packetizer
            ofifo_rready     = 1'b1;
            resp_start_pulse = 1'b1;
            arb_n            = ARB_WAIT_PKT;
          end else begin
            // Engine ešte pracuje – čakáme
            arb_n = ARB_WAIT_ENG;
          end
        end
      end

      ARB_WAIT_ENG: begin
        // Čakáme kým engine dokončí AXI transakciu
        if (eng_done_rdy[arb_sel_q]) begin
          ofifo_rready     = 1'b1;
          resp_start_pulse = 1'b1;
          arb_n            = ARB_WAIT_PKT;
        end
      end

      ARB_WAIT_PKT: begin
        // Čakáme kým packetizer odošle celý paket.
        // Používame registrovaný idle (packetizer_idle_q) aby sme
        // neopustili tento stav v rovnakom takte keď resp_start_q=1.
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

  // ── RX Parser ────────────────────────────────────────────────
  xfcp_rx_parser #(
    .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
  ) i_parser (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(xfcp_in.TDATA),   .s_axis_tvalid(xfcp_in.TVALID),
    .s_axis_tready(xfcp_in.TREADY), .s_axis_tlast(xfcp_in.TLAST),
    .req_hdr(req_hdr), .req_valid(req_valid), .req_ready(req_ready),
    .write_data(wdata), .write_data_valid(wdata_valid_raw),
    .write_data_ready(wdata_ready),
    .pass_valid(), .pass_data(), .pass_last(), .pass_ready(1'b0),
    .error_protocol()
  );

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
        .req_hdr   (req_hdr),
        .req_valid (req_valid && dec_valid && !eng_busy[gi]
                    && dec_sel == SEL_W'(gi) && ofifo_wready),
        .req_ready (eng_req_ready[gi]),
        .write_data       (wdata),
        .write_data_valid (wdata_valid && (wdata_sel == SEL_W'(gi))),
        .write_data_ready (eng_wdata_ready[gi]),
        .read_data       (eng_rdata[gi]),
        .read_data_valid (eng_rdata_valid[gi]),
        .read_data_ready (rdata_ready && (arb_sel_q == SEL_W'(gi))
                          && (arb_q == ARB_WAIT_PKT)),
        .resp_start        (),
        .resp_type         (),
        .resp_done         (eng_resp_done[gi]),
        .packetizer_idle_i (eng_pkt_idle[gi]),
        .error_timeout     ()
      );
    end : g_engine
  endgenerate

  // ── TX Packetizer ────────────────────────────────────────────
  xfcp_tx_packetizer #(
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
    .XFCP_ID_STR    (ID_STR)
  ) i_packetizer (
    .clk(clk), .rst_n(rst_n),
    .m_axis_tdata(xfcp_out.TDATA),   .m_axis_tvalid(xfcp_out.TVALID),
    .m_axis_tready(xfcp_out.TREADY), .m_axis_tlast(xfcp_out.TLAST),
    .resp_start      (resp_start_q),
    .resp_type       (resp_type),
    .read_data       (rdata),
    .read_data_valid (rdata_valid),
    .read_data_ready (rdata_ready),
    .resp_done_i     (resp_done_mux),
    .packetizer_idle (packetizer_idle),
    .resp_done_o     ()
  );

  // ── Simulačné správy ─────────────────────────────────────────
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (req_fire) begin
        if (!dec_valid)
          $error("[%0t] %m: Neplatná adresa 0x%08h!", $time, req_hdr.addr);
        else
          $display("[%0t] %m: Request addr=0x%08h → slave[%0d]",
                   $time, req_hdr.addr, dec_sel);
      end
      if (resp_start_q)
        $display("[%0t] %m: RESP slave[%0d] → packetizer type=0x%02h rdy=%0b",
                 $time, arb_sel_q, 8'(resp_type_q), eng_done_rdy[arb_sel_q]);
      if (arb_q != arb_n)
        $display("[%0t] %m: ARB %0d→%0d arb_sel=%0d fifo_sel=%0d ofifo_rv=%0b pkt_idle=%0b/%0b done_rdy=%0b",
                 $time, arb_q, arb_n, arb_sel_q, ofifo_rdata.sel,
                 ofifo_rvalid, packetizer_idle, packetizer_idle_q,
                 eng_done_rdy);
    end
  end
  // synthesis translate_on

endmodule : xfcp_fabric_endpoint

`endif // XFCP_FABRIC_ENDPOINT_SV
