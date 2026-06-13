/**
 * @file  xfcp_axis_adapter.sv
 * @brief XFCP STREAM_WRITE/READ adapter – serialise/gather AXI-Stream bytes.
 *
 * @details
 *   STREAM_WRITE (opcode 0x20):
 *     Prijme count/4 slov z fabric endpointu (axis_wdata_*) a po bajtoch
 *     ich odosle na m_axis (MSB-first).  Odpoved po poslednom m_axis handshake.
 *     Chyby: BAD_LENGTH (count=0/count>MAX_STREAM_BYTES/count%4!=0),
 *             UNSUPPORTED (stream_id!=0), TIMEOUT (m_axis_tready neide).
 *     Pri chybe: drainuje zvysne wdata slova pred odpovedu.
 *
 *   STREAM_READ (opcode 0x21):
 *     Zbiera count bajtov z s_axis a pakuje ich do 32-bitovych slov (MSB-first)
 *     do interneho response FIFO (rfifo).  Po zozbierani vsetkych bajtov:
 *     vydá resp_done, fabric endpoint cita z rfifo cez axis_rdata_*.
 *     Chyby: rovnake ako STREAM_WRITE + TIMEOUT (s_axis_tvalid neide).
 *
 * @param TIMEOUT_CYCLES   Pocet cyklov bez handshake pred TIMEOUT (default 1024).
 * @param MAX_STREAM_BYTES Max. bajty na transakciu (count <= limit, default 256).
 * @param RFIFO_DEPTH      Hlbka response FIFO (slov); musi byt >= MAX_STREAM_BYTES/4.
 */

`ifndef XFCP_AXIS_ADAPTER_SV
`define XFCP_AXIS_ADAPTER_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_axis_adapter #(
  parameter int TIMEOUT_CYCLES   = 1024,
  parameter int MAX_STREAM_BYTES = 256,
  parameter int RFIFO_DEPTH      = 64
)(
  input wire clk,
  input wire rst_n,

  // Interface to xfcp_fabric_endpoint
  input  logic          axis_req_valid_i,
  output logic          axis_req_ready_o,
  input  xfcp_req_hdr_t axis_req_hdr_i,

  input  logic [31:0]   axis_wdata_i,
  input  logic          axis_wdata_valid_i,
  output logic          axis_wdata_ready_o,

  output logic [31:0]   axis_rdata_o,
  output logic          axis_rdata_valid_o,
  input  logic          axis_rdata_ready_i,

  output logic          axis_resp_done_o,
  output logic [7:0]    axis_resp_status_o,

  // AXI-Stream master (STREAM_WRITE data output)
  output logic [7:0]    m_axis_tdata_o,
  output logic          m_axis_tvalid_o,
  input  logic          m_axis_tready_i,
  output logic          m_axis_tlast_o,

  // AXI-Stream slave (STREAM_READ data input)
  input  logic [7:0]    s_axis_tdata_i,
  input  logic          s_axis_tvalid_i,
  output logic          s_axis_tready_o,
  input  logic          s_axis_tlast_i
);

  // synthesis translate_off
  initial begin
    if (RFIFO_DEPTH * 4 < MAX_STREAM_BYTES)
      $fatal(1, "%m: RFIFO_DEPTH*4(%0d) < MAX_STREAM_BYTES(%0d)",
             RFIFO_DEPTH * 4, MAX_STREAM_BYTES);
  end
  // synthesis translate_on

  // ── FSM ──────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_WR_DATA,   // STREAM_WRITE: serialise wdata words -> m_axis bytes
    ST_WR_DRAIN,  // STREAM_WRITE: drain wdata after error or timeout
    ST_RD_DATA,   // STREAM_READ:  gather s_axis bytes -> rfifo
    ST_RESP       // pulse resp_done (1 cycle), then -> ST_IDLE
  } state_e;

  state_e      state_q;
  logic [7:0]  resp_status_q;

  // Byte-level counter (bytes remaining to send/receive)
  logic [15:0] byte_cnt_q;
  // Byte position within current 32-bit word [0-3]
  logic [1:0]  byte_idx_q;

  // WRITE: buffered wdata word + valid flag
  logic [31:0] wdata_word_q;
  logic        word_valid_q;

  // Tracking for drain after timeout
  logic [13:0] req_words_q;     // total words = count >> 2
  logic [13:0] words_loaded_q;  // wdata words consumed from endpoint
  logic [13:0] drain_cnt_q;     // words left to drain in ST_WR_DRAIN

  // READ: byte accumulator for 32-bit word packing
  logic [31:0] rd_word_q;
  logic [1:0]  rd_byte_idx_q;

  // Watchdog counter
  localparam int WD_W = $clog2(TIMEOUT_CYCLES + 2);
  logic [WD_W-1:0] watchdog_q;
  wire watchdog_expired = (watchdog_q == WD_W'(TIMEOUT_CYCLES));

  // ── Request validation (combinational) ───────────────────────
  wire [15:0] req_count  = axis_req_hdr_i.count;
  wire [7:0]  req_sid    = axis_req_hdr_i.addr[7:0];
  wire        req_bad    = (req_count == '0) ||
                           (req_count > 16'(MAX_STREAM_BYTES)) ||
                           (req_count[1:0] != 2'b00);
  wire        req_unsup  = (req_sid != 8'h00);
  wire        req_err    = req_bad || req_unsup;
  wire [7:0]  req_err_st = req_bad ? 8'(XFCP_ST_BAD_LENGTH)
                                   : 8'(XFCP_ST_UNSUPPORTED);
  wire        req_is_wr  = (axis_req_hdr_i.opcode == XFCP_OP_STREAM_WRITE);

  // ── Response FIFO (STREAM_READ response data) ─────────────────
  // DATA_WIDTH=32, DEPTH=RFIFO_DEPTH.
  // Read side connected directly to fabric endpoint's axis_rdata_* interface.
  logic [31:0] rfifo_wdata_w;
  logic        rfifo_wvalid_w;
  logic        rfifo_wready;

  xfcp_fifo #(
    .DATA_WIDTH (32),
    .DEPTH      (RFIFO_DEPTH)
  ) i_rfifo (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .w_valid(rfifo_wvalid_w), .w_data(rfifo_wdata_w), .w_ready(rfifo_wready),
    .r_valid(axis_rdata_valid_o), .r_data(axis_rdata_o), .r_ready(axis_rdata_ready_i)
  );

  // ── WRITE byte selector (MSB-first: byte 0 = bits[31:24]) ────
  logic [7:0] wr_byte_w;
  always_comb begin
    unique case (byte_idx_q)
      2'd0: wr_byte_w = wdata_word_q[31:24];
      2'd1: wr_byte_w = wdata_word_q[23:16];
      2'd2: wr_byte_w = wdata_word_q[15:8];
      2'd3: wr_byte_w = wdata_word_q[7:0];
    endcase
  end

  // ── READ byte packer: insert current s_axis byte into 32-bit word ──
  // rfifo_wdata_w is combinational; valid only when rfifo_wvalid_w=1.
  always_comb begin
    unique case (rd_byte_idx_q)
      2'd0: rfifo_wdata_w = {s_axis_tdata_i, rd_word_q[23:0]};
      2'd1: rfifo_wdata_w = {rd_word_q[31:24], s_axis_tdata_i, rd_word_q[15:0]};
      2'd2: rfifo_wdata_w = {rd_word_q[31:16], s_axis_tdata_i, rd_word_q[7:0]};
      2'd3: rfifo_wdata_w = {rd_word_q[31:8],  s_axis_tdata_i};
    endcase
  end

  wire s_axis_hs      = (state_q == ST_RD_DATA) && s_axis_tvalid_i && s_axis_tready_o;
  assign rfifo_wvalid_w = s_axis_hs && (rd_byte_idx_q == 2'd3);

  // ── Combinational outputs ─────────────────────────────────────
  // axis_req_ready_o: accepts new request only in ST_IDLE.
  assign axis_req_ready_o   = (state_q == ST_IDLE);
  assign axis_resp_done_o   = (state_q == ST_RESP);
  assign axis_resp_status_o = resp_status_q;

  assign m_axis_tdata_o  = wr_byte_w;
  assign m_axis_tvalid_o = (state_q == ST_WR_DATA) && word_valid_q;
  assign m_axis_tlast_o  = m_axis_tvalid_o && (byte_cnt_q == 16'd1);

  // axis_wdata_ready_o:
  //   ST_WR_DATA:  ready when no word buffered (byte boundary between words).
  //   ST_WR_DRAIN: always ready (drain mode).
  assign axis_wdata_ready_o = ((state_q == ST_WR_DATA)  && !word_valid_q) ||
                               (state_q == ST_WR_DRAIN);

  // s_axis_tready_o:
  //   Bytes 0-2: always ready in ST_RD_DATA (data goes into rd_word accumulator).
  //   Byte   3:  only when rfifo has space (this byte triggers a rfifo push).
  assign s_axis_tready_o = (state_q == ST_RD_DATA) &&
                            (rd_byte_idx_q != 2'd3 || rfifo_wready);

  // ── Main FSM ─────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= ST_IDLE;
      resp_status_q  <= '0;
      byte_cnt_q     <= '0;
      byte_idx_q     <= '0;
      wdata_word_q   <= '0;
      word_valid_q   <= 1'b0;
      req_words_q    <= '0;
      words_loaded_q <= '0;
      drain_cnt_q    <= '0;
      rd_word_q      <= '0;
      rd_byte_idx_q  <= '0;
      watchdog_q     <= '0;
    end else begin
      case (state_q)

        // ──────────────────────────────────────────────────────
        ST_IDLE: begin
          if (axis_req_valid_i) begin
            byte_cnt_q     <= req_count;
            req_words_q    <= req_count[15:2];
            words_loaded_q <= '0;
            byte_idx_q     <= '0;
            word_valid_q   <= 1'b0;
            rd_word_q      <= '0;
            rd_byte_idx_q  <= '0;
            watchdog_q     <= '0;
            if (req_err) begin
              resp_status_q <= req_err_st;
              // STREAM_WRITE error: must drain wdata words (if any)
              // STREAM_READ  error: no wdata to drain; respond immediately
              if (req_is_wr && req_count != '0) begin
                drain_cnt_q <= req_count[15:2];
                state_q     <= ST_WR_DRAIN;
              end else begin
                drain_cnt_q <= '0;
                state_q     <= ST_RESP;
              end
            end else begin
              resp_status_q <= 8'(XFCP_ST_OK);
              state_q       <= req_is_wr ? ST_WR_DATA : ST_RD_DATA;
            end
          end
        end

        // ──────────────────────────────────────────────────────
        ST_WR_DATA: begin
          // Load new wdata word when no word currently buffered.
          // word_valid_q=0 only at byte boundaries (byte_idx_q=0),
          // so this effectively loads at the start of each word.
          if (!word_valid_q && axis_wdata_valid_i) begin
            wdata_word_q   <= axis_wdata_i;
            word_valid_q   <= 1'b1;
            words_loaded_q <= words_loaded_q + 14'd1;
          end

          if (word_valid_q && m_axis_tready_i) begin
            // Byte handshake: advance counters
            watchdog_q <= '0;
            byte_cnt_q <= byte_cnt_q - 16'd1;
            byte_idx_q <= byte_idx_q + 2'd1;
            if (byte_idx_q == 2'd3)
              word_valid_q <= 1'b0;  // word exhausted; load next on next cycle
            if (byte_cnt_q == 16'd1)
              state_q <= ST_RESP;
          end else if (word_valid_q) begin
            // m_axis_tvalid but not ready: run watchdog
            if (!watchdog_expired)
              watchdog_q <= watchdog_q + 1'b1;
            if (watchdog_expired) begin
              resp_status_q <= 8'(XFCP_ST_TIMEOUT);
              word_valid_q  <= 1'b0;
              // Drain wdata words not yet loaded
              if (req_words_q > words_loaded_q) begin
                drain_cnt_q <= req_words_q - words_loaded_q;
                state_q     <= ST_WR_DRAIN;
              end else begin
                state_q <= ST_RESP;
              end
            end
          end
        end

        // ──────────────────────────────────────────────────────
        ST_WR_DRAIN: begin
          // Accept and discard wdata words until drain_cnt_q reaches 0.
          if (axis_wdata_valid_i && drain_cnt_q != '0) begin
            drain_cnt_q <= drain_cnt_q - 14'd1;
            if (drain_cnt_q == 14'd1)
              state_q <= ST_RESP;
          end
        end

        // ──────────────────────────────────────────────────────
        ST_RD_DATA: begin
          if (s_axis_hs) begin
            watchdog_q    <= '0;
            byte_cnt_q    <= byte_cnt_q - 16'd1;
            rd_byte_idx_q <= rd_byte_idx_q + 2'd1;
            // Accumulate bytes MSB-first into rd_word_q.
            // Byte 3 triggers rfifo push (rfifo_wvalid_w=1 this cycle);
            // rd_word_q resets for the next word.
            unique case (rd_byte_idx_q)
              2'd0: rd_word_q[31:24] <= s_axis_tdata_i;
              2'd1: rd_word_q[23:16] <= s_axis_tdata_i;
              2'd2: rd_word_q[15:8]  <= s_axis_tdata_i;
              2'd3: rd_word_q        <= '0;  // reset; rfifo_wdata_w captured combinatorially
            endcase
            if (byte_cnt_q == 16'd1)
              state_q <= ST_RESP;
          end else if (!s_axis_tvalid_i) begin
            // No data available: run watchdog
            if (!watchdog_expired)
              watchdog_q <= watchdog_q + 1'b1;
            if (watchdog_expired) begin
              resp_status_q <= 8'(XFCP_ST_TIMEOUT);
              state_q       <= ST_RESP;
            end
          end
        end

        // ──────────────────────────────────────────────────────
        ST_RESP: begin
          // axis_resp_done_o is asserted this cycle (combinational from state_q).
          // fabric endpoint's axis_done_cnt increments at next posedge.
          state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  // ── Simulacne spravy ─────────────────────────────────────────
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (state_q == ST_IDLE && axis_req_valid_i)
        $display("[%0t] %m: REQ op=0x%02h count=%0d sid=%0d err=%0b",
                 $time, 8'(axis_req_hdr_i.opcode), req_count, req_sid, req_err);
      if (state_q == ST_RESP)
        $display("[%0t] %m: RESP status=0x%02h", $time, resp_status_q);
      if (watchdog_expired && (state_q == ST_WR_DATA || state_q == ST_RD_DATA))
        $warning("[%0t] %m: TIMEOUT in state %0d byte_cnt=%0d",
                 $time, state_q, byte_cnt_q);
    end
  end
  // synthesis translate_on

endmodule : xfcp_axis_adapter

`endif // XFCP_AXIS_ADAPTER_SV
