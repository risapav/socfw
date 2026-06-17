/**
 * @file  xfcp_caps_adapter.sv
 * @brief XFCP GET_CAPS adapter -- staticka odpoved (2 x 32-bit slov, 8 bajtov).
 *
 * @details
 *   Prijme GET_CAPS request (opcode 0x01, COUNT=0) a okamzite odpovie
 *   dvoma 32-bit slovami cez rdata rozhranie (rovnake ako AXIL engine).
 *
 *   Odpoved (MSB-first v kazdom slove, packetizer serialzuje bajt[31:24] prvy):
 *     Word 0 [31:24] = PROTO_MAJOR
 *     Word 0 [23:16] = PROTO_MINOR
 *     Word 0 [15: 8] = NUM_AXIL_SLOTS
 *     Word 0 [ 7: 0] = NUM_STREAM_SLOTS
 *
 *     Word 1 [31:24] = MAX_STREAM_BYTES[15:8]  (high byte)
 *     Word 1 [23:16] = MAX_STREAM_BYTES[ 7:0]  (low byte)
 *     Word 1 [15: 8] = STREAM_ALIGN
 *     Word 1 [ 7: 0] = CAPS_FLAGS (bit0=AXIL, bit1=STREAM, bit2=CAPS, bit3=TARGETS, bit4=MEM)
 *
 *   Latencia: caps_resp_done_o sa vygeneruje 1 cyklus po prijati requestu.
 *   Arbiter v xfcp_fabric_endpoint potom rozhodne kedy zacat response packet.
 *   Data su dostupne ihned (combinacne z parametrov).
 *
 * @param PROTO_MAJOR       Hlavna verzia protokolu (default 1).
 * @param PROTO_MINOR       Vedlajsia verzia protokolu (default 1).
 * @param NUM_AXIL_SLOTS    Pocet AXI-Lite slotov.
 * @param NUM_STREAM_SLOTS  Pocet AXI-Stream slotov.
 * @param MAX_STREAM_BYTES  Max pocet bajtov na jeden STREAM prenos.
 * @param STREAM_ALIGN      Zarovnanie COUNT (nasobok tohto cisla).
 * @param CAPS_FLAGS        Bitova maska schopnosti (bit0=AXIL, bit1=STREAM, bit2=CAPS, bit3=TARGETS, bit4=MEM).
 */

`ifndef XFCP_CAPS_ADAPTER_SV
`define XFCP_CAPS_ADAPTER_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_caps_adapter #(
  parameter int PROTO_MAJOR      = 1,
  parameter int PROTO_MINOR      = 1,
  parameter int NUM_AXIL_SLOTS   = 7,
  parameter int NUM_STREAM_SLOTS = 1,
  parameter int MAX_STREAM_BYTES = 256,
  parameter int STREAM_ALIGN     = 4,
  parameter int CAPS_FLAGS       = 5'b11111  // AXIL | STREAM | CAPS | TARGETS | MEM
)(
  input  wire clk,
  input  wire rst_n,

  // Request interface (od xfcp_fabric_endpoint)
  input  logic          caps_req_valid_i,
  output logic          caps_req_ready_o,
  input  xfcp_req_hdr_t caps_req_hdr_i,

  // Datovy kanal -> xfcp_fabric_endpoint -> xfcp_tx_packetizer
  output logic [31:0]   caps_rdata_o,
  output logic          caps_rdata_valid_o,
  input  logic          caps_rdata_ready_i,

  // Done signal -> xfcp_fabric_endpoint (inkrement caps_done_cnt)
  output logic          caps_resp_done_o,
  output logic [7:0]    caps_resp_status_o
);

  // Staticke slova zostavene z parametrov (kombinacne).
  localparam logic [31:0] CAPS_WORD0 = {
    8'(PROTO_MAJOR),
    8'(PROTO_MINOR),
    8'(NUM_AXIL_SLOTS),
    8'(NUM_STREAM_SLOTS)
  };

  localparam logic [31:0] CAPS_WORD1 = {
    8'(MAX_STREAM_BYTES >> 8),
    8'(MAX_STREAM_BYTES & 8'hFF),
    8'(STREAM_ALIGN),
    8'(CAPS_FLAGS)
  };

  // ── FSM ──────────────────────────────────────────────────────────────────
  // ST_IDLE     : caka na request
  // ST_DONE_PLS : 1-cyklovy done pulse (caps_done_cnt++ v fabric_endpoint)
  // ST_DATA     : posiela slova word0, word1 cez rdata
  typedef enum logic [1:0] {
    ST_IDLE     = 2'd0,
    ST_DONE_PLS = 2'd1,
    ST_DATA     = 2'd2
  } state_e;

  state_e state_q;
  logic   word_idx_q;  // 0 = word0, 1 = word1

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= ST_IDLE;
      word_idx_q <= 1'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (caps_req_valid_i) begin
            state_q    <= ST_DONE_PLS;
            word_idx_q <= 1'b0;
          end
        end

        ST_DONE_PLS: begin
          state_q <= ST_DATA;
        end

        ST_DATA: begin
          if (caps_rdata_ready_i) begin
            if (word_idx_q == 1'b1)
              state_q <= ST_IDLE;
            else
              word_idx_q <= 1'b1;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign caps_req_ready_o   = (state_q == ST_IDLE);
  assign caps_resp_done_o   = (state_q == ST_DONE_PLS);
  assign caps_rdata_valid_o = (state_q == ST_DATA);
  assign caps_rdata_o       = word_idx_q ? CAPS_WORD1 : CAPS_WORD0;
  assign caps_resp_status_o = 8'h00;

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (caps_req_valid_i && caps_req_ready_o)
        $display("[%0t] %m: GET_CAPS seq=0x%02h -- W0=0x%08h W1=0x%08h",
                 $time, caps_req_hdr_i.seq, CAPS_WORD0, CAPS_WORD1);
    end
  end
  // synthesis translate_on

endmodule : xfcp_caps_adapter

`endif  // XFCP_CAPS_ADAPTER_SV
