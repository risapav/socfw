/**
 * @file  xfcp_fabric_endpoint.sv
 * @brief Pipelined XFCP multi-device endpoint -- AXIL + AXIS + CAPS + TI + MEM (A-light routing).
 *
 * @details
 *   Prepaja jeden XFCP port s NUM_SLAVES AXI-Lite zariadeniami,
 *   jednym AXI-Stream adapterom (xfcp_axis_adapter),
 *   jednym CAPS adapterom (xfcp_caps_adapter),
 *   jednym TARGET-INFO adapterom (xfcp_target_info_adapter)
 *   a jednym MEM adapterom (xfcp_mem_adapter, AXI4-Full master).
 *   Garantuje in-order odpovede pomocou order_fifo.
 *
 *   Routing (A-light schema):
 *     opcode 0x10/0x11/0x00 -> AXIL engine (dec_sel podla adresy)
 *     opcode 0x20/0x21      -> AXIS adapter (stream_id v addr[7:0])
 *     opcode 0x01           -> CAPS adapter (staticka odpoved)
 *     opcode 0x03           -> TI adapter (index v addr[7:0], staticka tabulka)
 *     opcode 0x30/0x31      -> MEM adapter (AXI4-Full burst, single outstanding)
 *
 *   Rozsirenia oproti xfcp_test_09_targets (MEM extension):
 *     1. order_entry_t: is_mem flag pridany vedla is_axis, is_caps, is_ti
 *     2. dec_valid: || is_mem_op
 *     3. eng_busy/eng_done_cnt: !is_mem_op guard pridany
 *     4. mem_busy_q: blocker (single outstanding) analogicky k axis_busy_q
 *     5. mem_done_cnt_q: analogicky k caps_done_cnt_q
 *     6. mem_req dispatch: s busy trackerom (kvoli MEM_WRITE wdata)
 *     7. wdata routing: wdata_sel_is_mem vetva analogicky k is_axis
 *     8. rdata MUX: arb_is_mem_q -> mem_rdata_i
 *     9. mem_rdata_ready_o: analogicky k axis_rdata_ready_o
 *    10. Arbiter done MUX: is_mem ? mem_done_rdy
 *    11. arb_is_axil_q: preregistered !(axis || caps || ti || mem)
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

  // AXI-Stream adapter interface (STREAM_WRITE/READ opcodes)
  output logic          axis_req_valid_o,
  input  logic          axis_req_ready_i,
  output xfcp_req_hdr_t axis_req_hdr_o,
  output logic [31:0]   axis_wdata_o,
  output logic          axis_wdata_valid_o,
  input  logic          axis_wdata_ready_i,
  input  logic [31:0]   axis_rdata_i,
  input  logic          axis_rdata_valid_i,
  output logic          axis_rdata_ready_o,
  input  logic          axis_resp_done_i,
  input  logic [7:0]    axis_resp_status_i,

  // CAPS adapter interface (GET_CAPS opcode)
  output logic          caps_req_valid_o,
  input  logic          caps_req_ready_i,
  output xfcp_req_hdr_t caps_req_hdr_o,
  input  logic [31:0]   caps_rdata_i,
  input  logic          caps_rdata_valid_i,
  output logic          caps_rdata_ready_o,
  input  logic          caps_resp_done_i,
  input  logic [7:0]    caps_resp_status_i,

  // TARGET_INFO adapter interface (GET_TARGET_INFO opcode)
  output logic          ti_req_valid_o,
  input  logic          ti_req_ready_i,
  output xfcp_req_hdr_t ti_req_hdr_o,
  input  logic [31:0]   ti_rdata_i,
  input  logic          ti_rdata_valid_i,
  output logic          ti_rdata_ready_o,
  input  logic          ti_resp_done_i,
  input  logic [7:0]    ti_resp_status_i,

  // MEM adapter interface (MEM_READ/MEM_WRITE opcodes)
  output logic          mem_req_valid_o,
  input  logic          mem_req_ready_i,
  output xfcp_req_hdr_t mem_req_hdr_o,
  output logic [31:0]   mem_wdata_o,
  output logic          mem_wdata_valid_o,
  input  logic          mem_wdata_ready_i,
  input  logic [31:0]   mem_rdata_i,
  input  logic          mem_rdata_valid_i,
  output logic          mem_rdata_ready_o,
  input  logic          mem_resp_done_i,
  input  logic [7:0]    mem_resp_status_i,

  output logic endpoint_busy_o,

  // Debug pulses (1-cycle, combinational)
  output logic dbg_sop_o,
  output logic dbg_hdr_o,
  output logic dbg_drop_o,
  output logic dbg_req_o,
  output logic dbg_resp_o,
  output logic dbg_bad_hdr_o,
  output logic dbg_recovery_o
);

  // synthesis translate_off
  initial begin
    if (NUM_SLAVES < 1 || NUM_SLAVES > 16)
      $fatal(1, "%m: NUM_SLAVES musi byt 1-16, got %0d", NUM_SLAVES);
  end
  // synthesis translate_on

  localparam int SEL_W = (NUM_SLAVES > 1) ? $clog2(NUM_SLAVES) : 1;

  // order_entry_t: is_axis=AXIS, is_caps=CAPS, is_ti=TARGET_INFO, is_mem=MEM, else AXIL.
  typedef struct packed {
    logic [SEL_W-1:0] sel;
    xfcp_op_e         op;
    logic [7:0]       seq;
    logic             is_axis;
    logic             is_caps;
    logic             is_ti;
    logic             is_mem;
    xfcp_op_e         resp_op;
  } order_entry_t;

  // ── Parser vystupy ───────────────────────────────────────────
  xfcp_req_hdr_t             req_hdr;
  logic                      req_valid;
  logic                      req_ready;
  logic [AXI_DATA_WIDTH-1:0] wdata;
  logic                      wdata_valid_raw;
  logic                      wdata_valid;
  logic                      wdata_ready;
  logic                      invalid_req;
  logic                      drop_wdata_q;
  logic [13:0]               drop_cnt_q;

  // ── Address decoder ──────────────────────────────────────────
  // STREAM/CAPS/TI/MEM ops bypass address decode.
  logic [SEL_W-1:0] dec_sel;
  logic             dec_valid_axil;
  logic             dec_valid;
  wire              is_stream_op;
  wire              is_caps_op;
  wire              is_ti_op;
  wire              is_mem_op;
  assign is_stream_op = xfcp_op_is_stream(req_hdr.opcode);
  assign is_caps_op   = xfcp_op_is_caps(req_hdr.opcode);
  assign is_ti_op     = xfcp_op_is_targets(req_hdr.opcode);
  assign is_mem_op    = xfcp_op_is_mem(req_hdr.opcode);

  always_comb begin
    dec_sel        = '0;
    dec_valid_axil = 1'b0;
    for (int i = NUM_SLAVES-1; i >= 0; i--) begin
      if ((req_hdr.addr & SLAVE_MASK[i]) == SLAVE_BASE[i]) begin
        dec_sel        = SEL_W'(i);
        dec_valid_axil = 1'b1;
      end
    end
  end
  assign dec_valid = dec_valid_axil || is_stream_op || is_caps_op || is_ti_op || is_mem_op;

  // ── req_stage registers ───────────────────────────────────────
  logic [SEL_W-1:0]          dec_sel_r;
  logic                      dec_valid_r;
  logic                      req_valid_r;
  logic                      invalid_req_r;
  xfcp_op_e                  req_op_r;
  logic [7:0]                req_seq_r;
  logic [15:0]               req_count_r;
  logic [AXI_ADDR_WIDTH-1:0] req_addr_r;
  logic                      ofifo_wvalid_r;
  logic                      is_stream_r;
  logic                      is_caps_r;
  logic                      is_ti_r;
  logic                      is_mem_r;
  logic                      req_is_write_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dec_sel_r      <= '0;
      dec_valid_r    <= 1'b0;
      req_valid_r    <= 1'b0;
      invalid_req_r  <= 1'b0;
      req_op_r       <= xfcp_pkg::XFCP_OP_READ;
      req_seq_r      <= '0;
      req_count_r    <= '0;
      req_addr_r     <= '0;
      is_stream_r    <= 1'b0;
      is_caps_r      <= 1'b0;
      is_ti_r        <= 1'b0;
      is_mem_r       <= 1'b0;
      req_is_write_r <= 1'b0;
    end else begin
      dec_valid_r    <= req_valid && dec_valid;
      req_valid_r    <= req_valid;
      invalid_req_r  <= req_valid && !dec_valid;
      is_stream_r    <= req_valid && is_stream_op;
      is_caps_r      <= req_valid && is_caps_op;
      is_ti_r        <= req_valid && is_ti_op;
      is_mem_r       <= req_valid && is_mem_op;
      req_is_write_r <= req_valid && (req_hdr.opcode == xfcp_pkg::XFCP_OP_WRITE);
      if (req_valid) begin
        dec_sel_r   <= dec_sel;
        req_op_r    <= req_hdr.opcode;
        req_seq_r   <= req_hdr.seq;
        req_count_r <= req_hdr.count;
        req_addr_r  <= req_hdr.addr;
      end
    end
  end

  xfcp_req_hdr_t req_hdr_staged;
  always_comb begin
    req_hdr_staged.opcode = req_op_r;
    req_hdr_staged.seq    = req_seq_r;
    req_hdr_staged.count  = req_count_r;
    req_hdr_staged.addr   = req_addr_r;
  end

  // ── slave_sel_q / slave_is_axis_q / slave_is_mem_q ──────────
  // Declared and driven inside wdata routing section below.
  logic [SEL_W-1:0] slave_sel_q;
  logic             slave_is_axis_q;

  // ── Engine signaly ───────────────────────────────────────────
  logic                      eng_busy          [NUM_SLAVES];
  logic                      eng_req_ready     [NUM_SLAVES];
  logic                      eng_req_ready_r   [NUM_SLAVES];
  logic                      eng_wdata_ready   [NUM_SLAVES];
  logic [AXI_DATA_WIDTH-1:0] eng_rdata         [NUM_SLAVES];
  logic                      eng_rdata_valid   [NUM_SLAVES];
  logic                      eng_resp_done     [NUM_SLAVES];
  logic [7:0]                eng_resp_type     [NUM_SLAVES];
  logic [7:0]                eng_resp_status   [NUM_SLAVES];
  logic                      eng_pkt_idle      [NUM_SLAVES];

  // ── Order FIFO signaly ───────────────────────────────────────
  order_entry_t ofifo_wdata;
  order_entry_t ofifo_rdata;
  logic         ofifo_wvalid, ofifo_wready;
  logic         ofifo_rvalid, ofifo_rready;

  // ── Order FIFO head register ──────────────────────────────────
  order_entry_t ofifo_head_r;
  logic         ofifo_head_valid_r;
  logic         ofifo_head_consume;

  // ── AXIL busy tracker + done counter ─────────────────────────
  logic [1:0] eng_done_cnt [NUM_SLAVES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_SLAVES; i++) begin
        eng_busy[i]     <= 1'b0;
        eng_done_cnt[i] <= '0;
      end
    end else begin
      for (int i = 0; i < NUM_SLAVES; i++) begin
        // !is_stream_op, !is_caps_op, !is_ti_op, !is_mem_op: prevent non-AXIL from setting eng_busy.
        if (req_valid && req_ready && !invalid_req && !is_stream_op
            && !is_caps_op && !is_ti_op && !is_mem_op && dec_sel == SEL_W'(i))
          eng_busy[i] <= 1'b1;
        else if (eng_resp_done[i])
          eng_busy[i] <= 1'b0;

        case ({eng_resp_done[i],
               (ofifo_head_consume && !ofifo_head_r.is_axis
                && !ofifo_head_r.is_caps && !ofifo_head_r.is_ti
                && !ofifo_head_r.is_mem
                && (ofifo_head_r.sel == SEL_W'(i)))})
          2'b10: eng_done_cnt[i] <= eng_done_cnt[i] + 1'b1;
          2'b01: if (eng_done_cnt[i] > 0)
                   eng_done_cnt[i] <= eng_done_cnt[i] - 1'b1;
          2'b11: ;
          default: ;
        endcase
      end
    end
  end

  logic [NUM_SLAVES-1:0] eng_done_rdy;
  always_comb begin
    for (int i = 0; i < NUM_SLAVES; i++)
      eng_done_rdy[i] = (eng_done_cnt[i] > 0);
  end

  // ── AXIS adapter busy tracker + done counter ──────────────────
  logic       axis_busy_q;
  logic [1:0] axis_done_cnt_q;
  wire        axis_done_rdy;
  assign axis_done_rdy = (axis_done_cnt_q > 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axis_busy_q     <= 1'b0;
      axis_done_cnt_q <= '0;
    end else begin
      if (req_valid && req_ready && !invalid_req && is_stream_op)
        axis_busy_q <= 1'b1;
      if (axis_resp_done_i)
        axis_busy_q <= 1'b0;

      case ({axis_resp_done_i,
             (ofifo_head_consume && ofifo_head_r.is_axis)})
        2'b10: axis_done_cnt_q <= axis_done_cnt_q + 1'b1;
        2'b01: if (axis_done_cnt_q > 0)
                 axis_done_cnt_q <= axis_done_cnt_q - 1'b1;
        2'b11: ;
        default: ;
      endcase
    end
  end

  // axis_req_ready_r: registered (breaks timing paths).
  logic axis_req_ready_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) axis_req_ready_r <= 1'b0;
    else if (!req_valid_r) axis_req_ready_r <= 1'b0;
    else axis_req_ready_r <= axis_req_ready_i;
  end

  // ── CAPS adapter done counter ─────────────────────────────────
  logic [1:0] caps_done_cnt_q;
  wire        caps_done_rdy;
  assign caps_done_rdy = (caps_done_cnt_q > 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      caps_done_cnt_q <= '0;
    end else begin
      case ({caps_resp_done_i,
             (ofifo_head_consume && ofifo_head_r.is_caps)})
        2'b10: caps_done_cnt_q <= caps_done_cnt_q + 1'b1;
        2'b01: if (caps_done_cnt_q > 0)
                 caps_done_cnt_q <= caps_done_cnt_q - 1'b1;
        2'b11: ;
        default: ;
      endcase
    end
  end

  // ── TARGET_INFO adapter done counter ─────────────────────────
  logic [1:0] ti_done_cnt_q;
  wire        ti_done_rdy;
  assign ti_done_rdy = (ti_done_cnt_q > 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ti_done_cnt_q <= '0;
    end else begin
      case ({ti_resp_done_i,
             (ofifo_head_consume && ofifo_head_r.is_ti)})
        2'b10: ti_done_cnt_q <= ti_done_cnt_q + 1'b1;
        2'b01: if (ti_done_cnt_q > 0)
                 ti_done_cnt_q <= ti_done_cnt_q - 1'b1;
        2'b11: ;
        default: ;
      endcase
    end
  end

  // ── MEM adapter busy tracker + done counter ───────────────────
  logic       mem_busy_q;
  logic [1:0] mem_done_cnt_q;
  wire        mem_done_rdy;
  assign mem_done_rdy = (mem_done_cnt_q > 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_busy_q     <= 1'b0;
      mem_done_cnt_q <= '0;
    end else begin
      if (req_valid && req_ready && !invalid_req && is_mem_op)
        mem_busy_q <= 1'b1;
      if (mem_resp_done_i)
        mem_busy_q <= 1'b0;

      case ({mem_resp_done_i,
             (ofifo_head_consume && ofifo_head_r.is_mem)})
        2'b10: mem_done_cnt_q <= mem_done_cnt_q + 1'b1;
        2'b01: if (mem_done_cnt_q > 0)
                 mem_done_cnt_q <= mem_done_cnt_q - 1'b1;
        2'b11: ;
        default: ;
      endcase
    end
  end

  // mem_req_ready_r: registered (breaks timing paths).
  logic mem_req_ready_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mem_req_ready_r <= 1'b0;
    else if (!req_valid_r) mem_req_ready_r <= 1'b0;
    else mem_req_ready_r <= mem_req_ready_i;
  end

  // ── Order FIFO instancia ─────────────────────────────────────
  xfcp_fifo #(
    .DATA_WIDTH ($bits(order_entry_t)),
    .DEPTH      (ORDER_FIFO_DEPTH)
  ) i_order_fifo (
    .clk     (clk), .rst_n (rst_n), .flush (1'b0),
    .w_valid (ofifo_wvalid), .w_data (ofifo_wdata), .w_ready (ofifo_wready),
    .r_valid (ofifo_rvalid), .r_data (ofifo_rdata), .r_ready (ofifo_rready)
  );

  assign ofifo_rready = !ofifo_head_valid_r && ofifo_rvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ofifo_head_r       <= '0;
      ofifo_head_valid_r <= 1'b0;
    end else begin
      if (!ofifo_head_valid_r && ofifo_rvalid) begin
        ofifo_head_r       <= ofifo_rdata;
        ofifo_head_valid_r <= 1'b1;
      end else if (ofifo_head_consume) begin
        ofifo_head_valid_r <= 1'b0;
      end
    end
  end

  // ── Request dispatch ─────────────────────────────────────────
  logic req_fire;
  assign invalid_req  = req_valid && !dec_valid;
  assign req_fire     = req_valid && req_ready;
  assign req_ready    = invalid_req_r ? 1'b1 :
                        is_mem_r      ?
                          (!mem_busy_q && mem_req_ready_r
                           && ofifo_wready && !ofifo_wvalid_r) :
                        is_ti_r       ?
                          (ti_req_ready_i && ofifo_wready && !ofifo_wvalid_r) :
                        is_caps_r     ?
                          (caps_req_ready_i && ofifo_wready && !ofifo_wvalid_r) :
                        is_stream_r   ?
                          (!axis_busy_q && axis_req_ready_r
                           && ofifo_wready && !ofifo_wvalid_r) :
                        dec_valid_r && !eng_busy[dec_sel_r]
                        && eng_req_ready_r[dec_sel_r]
                        && ofifo_wready && !ofifo_wvalid_r;
  assign ofifo_wvalid = ofifo_wvalid_r;
  assign ofifo_wdata  = '{sel:     dec_sel_r,
                           op:      req_op_r,
                           seq:     req_seq_r,
                           is_axis: is_stream_r,
                           is_caps: is_caps_r,
                           is_ti:   is_ti_r,
                           is_mem:  is_mem_r,
                           resp_op: xfcp_resp_for_op(req_op_r)};

  // AXIS req dispatch
  assign axis_req_valid_o = req_valid_r && is_stream_r && !axis_busy_q
                            && ofifo_wready && !ofifo_wvalid_r;
  assign axis_req_hdr_o   = req_hdr_staged;

  // CAPS req dispatch (okamzite, bez busy trackera)
  assign caps_req_valid_o = req_valid_r && is_caps_r
                            && caps_req_ready_i && ofifo_wready && !ofifo_wvalid_r;
  assign caps_req_hdr_o   = req_hdr_staged;

  // TI req dispatch (okamzite, bez busy trackera)
  assign ti_req_valid_o = req_valid_r && is_ti_r
                          && ti_req_ready_i && ofifo_wready && !ofifo_wvalid_r;
  assign ti_req_hdr_o   = req_hdr_staged;

  // MEM req dispatch (s busy trackerom — analogicky k AXIS)
  assign mem_req_valid_o = req_valid_r && is_mem_r && !mem_busy_q
                           && ofifo_wready && !ofifo_wvalid_r;
  assign mem_req_hdr_o   = req_hdr_staged;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      for (int i = 0; i < NUM_SLAVES; i++) eng_req_ready_r[i] <= 1'b0;
    else if (!req_valid_r)
      for (int i = 0; i < NUM_SLAVES; i++) eng_req_ready_r[i] <= 1'b0;
    else
      for (int i = 0; i < NUM_SLAVES; i++) eng_req_ready_r[i] <= eng_req_ready[i];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ofifo_wvalid_r <= 1'b0;
    else        ofifo_wvalid_r <= req_fire && !invalid_req_r;
  end

  // ── wdata routing ─────────────────────────────────────────────
  // slave_is_mem_q: sleduje is_mem_r pocas transakcie (analogicky k slave_is_axis_q)
  logic slave_is_mem_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      slave_sel_q    <= '0;
      slave_is_axis_q <= 1'b0;
      slave_is_mem_q  <= 1'b0;
    end else if (req_valid && req_ready) begin
      slave_sel_q    <= dec_sel_r;
      slave_is_axis_q <= is_stream_op;
      slave_is_mem_q  <= is_mem_op;
    end
  end

  logic [SEL_W-1:0] wdata_sel;
  wire  drain_wdata       = drop_wdata_q ||
                            (invalid_req_r && (req_op_r == XFCP_OP_WRITE ||
                                               req_op_r == XFCP_OP_MEM_WRITE));
  wire  wdata_sel_is_axis = req_valid_r ? is_stream_r : slave_is_axis_q;
  wire  wdata_sel_is_mem  = req_valid_r ? is_mem_r    : slave_is_mem_q;
  assign wdata_sel   = req_valid_r ? dec_sel_r : slave_sel_q;
  assign wdata_valid = wdata_valid_raw && !drain_wdata;

  logic [AXI_DATA_WIDTH-1:0] wdata_stage_data_r;
  logic [SEL_W-1:0]          wdata_stage_sel_r;
  logic                      wdata_stage_valid_r;
  logic                      wdata_stage_is_axis_r;
  logic                      wdata_stage_is_mem_r;

  wire wdata_stage_fire_w =
    wdata_stage_valid_r &&
      (wdata_stage_is_axis_r ? axis_wdata_ready_i :
       wdata_stage_is_mem_r  ? mem_wdata_ready_i  :
                               eng_wdata_ready[wdata_stage_sel_r]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wdata_stage_valid_r   <= 1'b0;
      wdata_stage_data_r    <= '0;
      wdata_stage_sel_r     <= '0;
      wdata_stage_is_axis_r <= 1'b0;
      wdata_stage_is_mem_r  <= 1'b0;
    end else if (drain_wdata) begin
      wdata_stage_valid_r   <= 1'b0;
      wdata_stage_is_axis_r <= 1'b0;
      wdata_stage_is_mem_r  <= 1'b0;
    end else if (!wdata_stage_valid_r || wdata_stage_fire_w) begin
      wdata_stage_valid_r   <= wdata_valid;
      wdata_stage_is_axis_r <= wdata_valid && wdata_sel_is_axis;
      wdata_stage_is_mem_r  <= wdata_valid && wdata_sel_is_mem;
      if (wdata_valid) begin
        wdata_stage_data_r <= wdata;
        wdata_stage_sel_r  <= wdata_sel;
      end
    end
  end

  assign wdata_ready        = drain_wdata ? 1'b1 :
                              (!wdata_stage_valid_r || wdata_stage_fire_w);
  assign axis_wdata_o       = wdata_stage_data_r;
  assign axis_wdata_valid_o = wdata_stage_valid_r && wdata_stage_is_axis_r;
  assign mem_wdata_o        = wdata_stage_data_r;
  assign mem_wdata_valid_o  = wdata_stage_valid_r && wdata_stage_is_mem_r;

  // ── Invalid WRITE/MEM_WRITE payload drain ────────────────────
  wire [13:0] req_words = req_count_r[15:2];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      drop_wdata_q <= 1'b0;
      drop_cnt_q   <= '0;
    end else if (invalid_req_r && req_fire &&
                 (req_op_r == XFCP_OP_WRITE || req_op_r == XFCP_OP_MEM_WRITE)) begin
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
  logic          arb_is_axis_q;
  logic          arb_is_caps_q;
  logic          arb_is_ti_q;
  logic          arb_is_mem_q;
  logic          arb_is_axil_q;  // preregistered: !(axis || caps || ti || mem)
  logic          resp_start_pulse;
  logic          resp_start_q;
  logic          packetizer_idle;
  logic          packetizer_idle_q;

  xfcp_op_e                  resp_type_q;
  xfcp_op_e                  resp_type;
  logic [7:0]                resp_seq_q;
  logic [7:0]                resp_status_q;
  logic [AXI_DATA_WIDTH-1:0] rdata;
  logic                      rdata_valid;
  logic                      rdata_ready;
  logic                      resp_done_held_q;
  logic                      resp_done_mux_q;

  logic [AXI_DATA_WIDTH-1:0] rdata_r;
  logic                      rdata_valid_r;
  wire                       rdata_ready_int = rdata_ready || !rdata_valid_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdata_r       <= '0;
      rdata_valid_r <= 1'b0;
    end else if (rdata_ready_int) begin
      rdata_r       <= rdata;
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

  // rdata MUX: AXIL engine vs AXIS vs CAPS vs TI vs MEM adapter.
  always_comb begin
    if (arb_is_axis_q) begin
      rdata       = axis_rdata_i;
      rdata_valid = axis_rdata_valid_i;
    end else if (arb_is_caps_q) begin
      rdata       = caps_rdata_i;
      rdata_valid = caps_rdata_valid_i;
    end else if (arb_is_ti_q) begin
      rdata       = ti_rdata_i;
      rdata_valid = ti_rdata_valid_i;
    end else if (arb_is_mem_q) begin
      rdata       = mem_rdata_i;
      rdata_valid = mem_rdata_valid_i;
    end else begin
      rdata       = eng_rdata      [arb_sel_q];
      rdata_valid = eng_rdata_valid[arb_sel_q];
    end
    resp_type = resp_type_q;
  end

  assign axis_rdata_ready_o = arb_is_axis_q && (arb_q == ARB_WAIT_PKT) && rdata_ready_int;
  assign caps_rdata_ready_o = arb_is_caps_q && (arb_q == ARB_WAIT_PKT) && rdata_ready_int;
  assign ti_rdata_ready_o   = arb_is_ti_q   && (arb_q == ARB_WAIT_PKT) && rdata_ready_int;
  assign mem_rdata_ready_o  = arb_is_mem_q  && (arb_q == ARB_WAIT_PKT) && rdata_ready_int;

  // Arbiter sekvencna
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb_q         <= ARB_IDLE;
      arb_sel_q     <= '0;
      arb_is_axis_q <= 1'b0;
      arb_is_caps_q <= 1'b0;
      arb_is_ti_q   <= 1'b0;
      arb_is_mem_q  <= 1'b0;
      arb_is_axil_q <= 1'b1;
      resp_type_q   <= xfcp_pkg::XFCP_OP_RESP_WRITE;
      resp_seq_q    <= '0;
      resp_status_q <= '0;
    end else begin
      arb_q <= arb_n;
      if (resp_start_pulse) begin
        arb_sel_q     <= ofifo_head_r.sel;
        arb_is_axis_q <= ofifo_head_r.is_axis;
        arb_is_caps_q <= ofifo_head_r.is_caps;
        arb_is_ti_q   <= ofifo_head_r.is_ti;
        arb_is_mem_q  <= ofifo_head_r.is_mem;
        arb_is_axil_q <= !ofifo_head_r.is_axis
                         && !ofifo_head_r.is_caps
                         && !ofifo_head_r.is_ti
                         && !ofifo_head_r.is_mem;
        resp_seq_q    <= ofifo_head_r.seq;
        if (ofifo_head_r.is_axis) begin
          resp_type_q   <= ofifo_head_r.resp_op;
          resp_status_q <= axis_resp_status_i;
        end else if (ofifo_head_r.is_caps) begin
          resp_type_q   <= ofifo_head_r.resp_op;
          resp_status_q <= caps_resp_status_i;
        end else if (ofifo_head_r.is_ti) begin
          resp_type_q   <= ofifo_head_r.resp_op;
          resp_status_q <= ti_resp_status_i;
        end else if (ofifo_head_r.is_mem) begin
          resp_type_q   <= ofifo_head_r.resp_op;
          resp_status_q <= mem_resp_status_i;
        end else begin
          resp_type_q   <= xfcp_op_e'(eng_resp_type[ofifo_head_r.sel]);
          resp_status_q <= eng_resp_status[ofifo_head_r.sel];
        end
      end else if (arb_q == ARB_IDLE && arb_n == ARB_WAIT_ENG) begin
        arb_sel_q     <= ofifo_head_r.sel;
        arb_is_caps_q <= ofifo_head_r.is_caps;
        arb_is_ti_q   <= ofifo_head_r.is_ti;
        arb_is_mem_q  <= ofifo_head_r.is_mem;
        arb_is_axil_q <= !ofifo_head_r.is_axis
                         && !ofifo_head_r.is_caps
                         && !ofifo_head_r.is_ti
                         && !ofifo_head_r.is_mem;
      end
    end
  end

  // Arbiter kombinacna
  logic arb_done_now;
  always_comb begin
    arb_done_now =
      ofifo_head_r.is_axis ? axis_done_rdy :
      ofifo_head_r.is_caps ? caps_done_rdy :
      ofifo_head_r.is_ti   ? ti_done_rdy   :
      ofifo_head_r.is_mem  ? mem_done_rdy  :
                             eng_done_rdy[ofifo_head_r.sel];
  end

  always_comb begin
    arb_n              = arb_q;
    ofifo_head_consume = 1'b0;
    resp_start_pulse   = 1'b0;

    case (arb_q)
      ARB_IDLE: begin
        if (ofifo_head_valid_r && packetizer_idle) begin
          if (arb_done_now) begin
            ofifo_head_consume = 1'b1;
            resp_start_pulse   = 1'b1;
            arb_n              = ARB_WAIT_PKT;
          end else begin
            arb_n = ARB_WAIT_ENG;
          end
        end
      end

      ARB_WAIT_ENG: begin
        if (arb_done_now) begin
          ofifo_head_consume = 1'b1;
          resp_start_pulse   = 1'b1;
          arb_n              = ARB_WAIT_PKT;
        end
      end

      ARB_WAIT_PKT: begin
        if (packetizer_idle_q && packetizer_idle)
          arb_n = ARB_IDLE;
      end

      default: arb_n = ARB_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) resp_start_q <= 1'b0;
    else        resp_start_q <= resp_start_pulse;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      packetizer_idle_q <= 1'b1;
    else if (resp_start_pulse)
      packetizer_idle_q <= 1'b0;
    else
      packetizer_idle_q <= packetizer_idle;
  end

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

  // ── AXI Engine instancie ─────────────────────────────────────
  // arb_is_axil_q: preregistered !(axis||caps||ti), breaks timing path.
  genvar gi;
  generate
    for (gi = 0; gi < NUM_SLAVES; gi++) begin : g_engine
      assign eng_pkt_idle[gi] = packetizer_idle
                                 || (arb_q != ARB_WAIT_PKT)
                                 || (arb_sel_q != SEL_W'(gi))
                                 || !arb_is_axil_q;  // arb_is_axil_q excludes axis/caps/ti/mem

      xfcp_axi_engine #(
        .LITTLE_ENDIAN  (LITTLE_ENDIAN),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
      ) i_engine (
        .clk   (clk), .rst_n (rst_n),
        .m_axil (m_axil[gi]),
        .req_hdr        (req_hdr_staged),
        .req_valid      (req_valid_r && dec_valid_r && !eng_busy[gi]
                         && !is_stream_r && !is_caps_r && !is_ti_r && !is_mem_r
                         && dec_sel_r == SEL_W'(gi) && ofifo_wready),
        .req_ready      (eng_req_ready[gi]),
        .req_is_write_i (req_is_write_r),
        .write_data       (wdata_stage_data_r),
        .write_data_valid (wdata_stage_valid_r && (wdata_stage_sel_r == SEL_W'(gi))
                           && !wdata_stage_is_axis_r && !wdata_stage_is_mem_r),
        .write_data_ready (eng_wdata_ready[gi]),
        .read_data       (eng_rdata[gi]),
        .read_data_valid (eng_rdata_valid[gi]),
        .read_data_ready (rdata_ready_int && (arb_sel_q == SEL_W'(gi))
                          && (arb_q == ARB_WAIT_PKT) && arb_is_axil_q),
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

  assign xfcp_out.TKEEP = '1;
  assign xfcp_out.TUSER = '0;
  assign xfcp_out.TID   = '0;
  assign xfcp_out.TDEST = '0;

  // ── Simulacne spravy ─────────────────────────────────────────
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (req_fire) begin
        if (!dec_valid)
          $warning("[%0t] %m: Neplatna adresa 0x%08h!", $time, req_hdr.addr);
        else if (is_ti_op)
          $display("[%0t] %m: TI req op=0x%02h seq=0x%02h index=%0d",
                   $time, 8'(req_hdr.opcode), req_hdr.seq, req_hdr.addr[7:0]);
        else if (is_caps_op)
          $display("[%0t] %m: CAPS req op=0x%02h seq=0x%02h",
                   $time, 8'(req_hdr.opcode), req_hdr.seq);
        else if (is_stream_op)
          $display("[%0t] %m: STREAM req op=0x%02h seq=0x%02h count=%0d",
                   $time, 8'(req_hdr.opcode), req_hdr.seq, req_hdr.count);
        else if (is_mem_op)
          $display("[%0t] %m: MEM req op=0x%02h seq=0x%02h addr=0x%08h count=%0d",
                   $time, 8'(req_hdr.opcode), req_hdr.seq, req_hdr.addr, req_hdr.count);
        else
          $display("[%0t] %m: AXIL req addr=0x%08h -> slave[%0d]",
                   $time, req_hdr.addr, dec_sel);
      end
      if (resp_start_q)
        $display("[%0t] %m: RESP ax=%0b caps=%0b ti=%0b mem=%0b sel=%0d type=0x%02h",
                 $time, arb_is_axis_q, arb_is_caps_q, arb_is_ti_q, arb_is_mem_q,
                 arb_sel_q, 8'(resp_type_q));
      if (arb_q != arb_n)
        $display(
          "[%0t] %m: ARB %0d->%0d sel=%0d ax=%0b caps=%0b ti=%0b mem=%0b head_v=%0b",
          $time, arb_q, arb_n, arb_sel_q, arb_is_axis_q, arb_is_caps_q,
          arb_is_ti_q, arb_is_mem_q, ofifo_head_valid_r);
    end
  end
  // synthesis translate_on

endmodule : xfcp_fabric_endpoint

`endif // XFCP_FABRIC_ENDPOINT_SV
