/**
 * @file  xfcp_tx_packetizer.sv
 * @brief XFCP Response Packetizer (v0.9+STATUS) -- 4-bajtovy header.
 *
 * Novy format vystupneho paketu:
 *   Bajt  | Pole
 *   ------|---------------------------
 *    0    | SOP = XFCP_SOP_RESP (0xFD)
 *    1    | TYPE (0x12=RESP_READ, 0x13=RESP_WRITE)
 *    2    | SEQ (echo z requestu)
 *    3    | STATUS (xfcp_status_e: 0x00=OK, 0x04=SLVERR, 0x05=DECERR, 0x06=TIMEOUT)
 *   4..N  | PAYLOAD (32-bit slova, MSB-first) -- len pre RESP_READ
 *   end   | 0x00 + TLAST
 *
 * Zmeny oproti v0.9:
 *   - DEV_TYPE a DEV_STR odstranene z hlavicky RESP_READ/RESP_WRITE
 *   - STATUS byte pridany na pozicii 3
 *   - HEADER_BYTES: 21 -> 4
 *   - Parametre XFCP_ID_TYPE, XFCP_ID_STR odstranene
 *   - Novy vstup resp_status_i [7:0]
 */

`ifndef XFCP_TX_PACKETIZER_SV
`define XFCP_TX_PACKETIZER_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_tx_packetizer #(
  parameter int AXI_DATA_WIDTH = 32
) (
  input  wire clk,
  input  wire rst_n,

  // AXI-Stream vystup (8-bit)
  output logic [7:0] m_axis_tdata,
  output logic       m_axis_tvalid,
  input  wire        m_axis_tready,
  output logic       m_axis_tlast,

  // Riadiace signaly od arbitera
  input  wire           resp_start,    // 1-takt pulz: zacni odosielat paket
  input  wire [7:0]     resp_type,     // typ response (xfcp_op_e)
  input  wire [7:0]     resp_seq,      // SEQ z requestu
  input  wire [7:0]     resp_status_i, // XFCP STATUS byte (xfcp_status_e)

  // Datovy kanal z engine read_buffer FIFO
  input  wire [AXI_DATA_WIDTH-1:0] read_data,
  input  wire                      read_data_valid,
  output logic                     read_data_ready,   // backpressure do FIFO

  // Synchronizacia s engineom
  input  wire  resp_done_i,      // engine: posledne slovo spracovane
  output logic packetizer_idle,  // kombinacny: 1 ked ST_IDLE
  output logic resp_done_o       // 1-takt pulz po odoslani TLAST
);

  // ============================================================
  // Lokalne konstanty
  // ============================================================
  // SOP(1) + TYPE(1) + SEQ(1) + STATUS(1) = 4 bajty
  localparam int HEADER_BYTES = 4;

  // ============================================================
  // ONE-HOT FSM
  // ============================================================
  typedef enum logic [3:0] {
    ST_IDLE    = 4'b0001,
    ST_HEADER  = 4'b0010,
    ST_PAYLOAD = 4'b0100,
    ST_DONE    = 4'b1000
  } state_e;

  state_e state_q, state_n;

  // ============================================================
  // Registre
  // ============================================================
  logic [1:0] header_ptr_q;  // index bajtu (0-3)

  // Dual-slot buffer (nezmeneny oproti v0.9 -- rovnaka architektura)
  logic [31:0] slot0_q,       slot1_q;
  logic        slot0_valid_q, slot1_valid_q;
  logic [1:0]  byte_cnt_q;
  logic        done_latch_q;

  // ============================================================
  // Header ROM – 4 bajty (kombinacny, stabilny od resp_start)
  // ============================================================
  logic [HEADER_BYTES*8-1:0] hdr_vec;

  always_comb begin
    hdr_vec[ 0 +: 8] = XFCP_SOP_RESP;
    hdr_vec[ 8 +: 8] = xfcp_op_e'(resp_type);
    hdr_vec[16 +: 8] = resp_seq;
    hdr_vec[24 +: 8] = resp_status_i;
  end

  // ============================================================
  // Pomocne signaly
  // ============================================================
  wire hs        = m_axis_tvalid && m_axis_tready;
  wire done_flag = done_latch_q || resp_done_i;

  // ============================================================
  // BACKPRESSURE (nezmenena logika)
  // ============================================================
  assign read_data_ready = (state_q == ST_PAYLOAD) &&
                           (!slot0_valid_q || !slot1_valid_q);

  // ============================================================
  // RESP_DONE LATCH (nezmenena logika)
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
  // DUAL-SLOT BUFFER + SHIFT SERIALIZER (nezmenena logika v4)
  // ============================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      slot0_q       <= '0;
      slot0_valid_q <= 1'b0;
      slot1_q       <= '0;
      slot1_valid_q <= 1'b0;
      byte_cnt_q    <= '0;
    end else begin

      if (state_q == ST_IDLE) begin
        slot0_valid_q <= 1'b0;
        slot1_valid_q <= 1'b0;
        byte_cnt_q    <= '0;

      end else if (state_q == ST_PAYLOAD) begin

        // A) FIFO → SLOT
        if (read_data_valid) begin
          if (!slot0_valid_q) begin
            slot0_q       <= read_data;
            slot0_valid_q <= 1'b1;
          end else if (!slot1_valid_q) begin
            slot1_q       <= read_data;
            slot1_valid_q <= 1'b1;
          end
        end

        // B) Serializer
        if (hs && slot0_valid_q && byte_cnt_q[1] && byte_cnt_q[0]) begin
          slot0_q       <= slot1_q;
          slot0_valid_q <= slot1_valid_q;
          slot1_valid_q <= (read_data_valid && slot0_valid_q && !slot1_valid_q);
          byte_cnt_q    <= '0;
        end else if (hs && slot0_valid_q) begin
          slot0_q    <= {slot0_q[23:0], 8'h00};
          byte_cnt_q <= byte_cnt_q + 1'b1;
        end

      end
    end
  end

  // ============================================================
  // Sekvenčna logika -- FSM state + header pointer
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
        if (header_ptr_q != 2'(HEADER_BYTES - 1))
          header_ptr_q <= header_ptr_q + 1'b1;
      end
    end
  end

  // ============================================================
  // FSM -- kombinacna logika
  // ============================================================
  always_comb begin
    state_n       = state_q;
    m_axis_tvalid = 1'b0;
    m_axis_tdata  = 8'h00;
    m_axis_tlast  = 1'b0;
    resp_done_o   = 1'b0;

    unique case (state_q)

      ST_IDLE: begin
        if (resp_start) state_n = ST_HEADER;
      end

      // 4-bajtovy header: SOP + TYPE + SEQ + STATUS
      ST_HEADER: begin
        m_axis_tvalid = 1'b1;
        m_axis_tdata  = hdr_vec[{header_ptr_q, 3'b000} +: 8];
        if (hs && header_ptr_q == 2'(HEADER_BYTES - 1)) begin
          if (xfcp_resp_has_payload(xfcp_op_e'(resp_type)))
            state_n = ST_PAYLOAD;
          else
            state_n = ST_DONE;
        end
      end

      ST_PAYLOAD: begin
        m_axis_tvalid = slot0_valid_q;
        m_axis_tdata  = slot0_q[31:24];
        // Early exit: done signaled but both slots empty and FIFO has nothing
        // (STREAM_READ error response -- rfifo was never filled).
        if (done_flag && !slot0_valid_q && !slot1_valid_q && !read_data_valid)
          state_n = ST_DONE;
        else if (hs && byte_cnt_q[1] && byte_cnt_q[0] && done_flag && !slot1_valid_q)
          state_n = ST_DONE;
      end

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

  assign packetizer_idle = (state_q == ST_IDLE);

  // ============================================================
  // Simulacne spravy + assertions
  // ============================================================
  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (state_q == ST_IDLE && state_n == ST_HEADER)
        $display("[%0t] %m: Start paketu | type=0x%02h status=0x%02h",
                 $time, xfcp_op_e'(resp_type), resp_status_i);

      if (state_q == ST_HEADER && state_n == ST_PAYLOAD)
        $display("[%0t] %m: Header done -> ST_PAYLOAD", $time);

      if (state_q == ST_HEADER && state_n == ST_DONE)
        $display("[%0t] %m: Header done -> ST_DONE (WRITE resp)", $time);

      if (resp_done_o)
        $display("[%0t] %m: Paket odoslany (TLAST)", $time);

      if (state_q == ST_PAYLOAD) begin
        if (hs || read_data_valid)
          $display("[%0t] %m: DATA hs=%b | slot0=%b/%08h slot1=%b/%08h byte=%0d done=%0b",
                   $time, hs, slot0_valid_q, slot0_q,
                   slot1_valid_q, slot1_q, byte_cnt_q, done_flag);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && state_q == ST_PAYLOAD)
      assert (!(slot1_valid_q && !slot0_valid_q))
        else $fatal(1, "[%0t] %m: INVARIANT FAIL – slot1 platny ale slot0 prazdny!", $time);
  end

  always_ff @(posedge clk) begin
    if (rst_n && state_q == ST_PAYLOAD && m_axis_tvalid)
      assert (slot0_valid_q)
        else $fatal(1, "[%0t] %m: INVARIANT FAIL – TVALID=1 ale slot0 prazdny!", $time);
  end
  // synthesis translate_on

endmodule : xfcp_tx_packetizer

`endif  // XFCP_TX_PACKETIZER_SV
