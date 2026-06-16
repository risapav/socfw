/**
 * @file  xfcp_target_info_adapter.sv
 * @brief XFCP GET_TARGET_INFO adapter -- staticka tabulka N targetov (4 x 32-bit slov = 16B).
 *
 * @details
 *   Prijme GET_TARGET_INFO request (opcode 0x03, COUNT=0, ADDR[7:0]=index)
 *   a odpovie stitmi 32-bit slovami z ROM tabulky cez rdata rozhranie.
 *
 *   Payload (MSB-first v kazdom slove, packetizer serializuje bajt[31:24] prvy):
 *     Word 0 [31:24] = target_type  (0x01=AXIL, 0x02=STREAM)
 *     Word 0 [23:16] = target_id    (== index)
 *     Word 0 [15: 8] = flags        (0x00)
 *     Word 0 [ 7: 0] = reserved     (0x00)
 *     Word 1 [31: 0] = base_addr    (32-bit big-endian)
 *     Word 2 [31:24] = max_transfer[15:8]
 *     Word 2 [23:16] = max_transfer[ 7:0]
 *     Word 2 [15: 8] = align
 *     Word 2 [ 7: 0] = reserved     (0x00)
 *     Word 3 [31: 0] = 4-char ASCII name
 *
 *   Neplatny index (>= NUM_TARGETS) → odpoved s ti_resp_status_o=XFCP_ST_BAD_ADDRESS,
 *   stale 4 nulove slova (packetizer ich dostane, host ich ignoruje kvoli status!=OK).
 *
 *   FSM: ST_IDLE -> ST_DONE_PLS -> ST_DATA (word_idx 0..3) -> ST_IDLE
 *
 * @param NUM_TARGETS       Pocet targetov v tabulke (max 256).
 * @param TARGET_TYPE       Pole typov: 0x01=AXIL, 0x02=STREAM.
 * @param TARGET_BASE_ADDR  Pole base adries (32b).
 * @param TARGET_MAX_XFER   Pole max_transfer (16b).
 * @param TARGET_ALIGN      Pole zarovnani.
 * @param TARGET_NAME       Pole 4-char ASCII nazvov (32b).
 */

`ifndef XFCP_TARGET_INFO_ADAPTER_SV
`define XFCP_TARGET_INFO_ADAPTER_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_target_info_adapter #(
  parameter int NUM_TARGETS = 8,

  parameter logic [7:0]  TARGET_TYPE      [NUM_TARGETS] = '{default: 8'h01},
  parameter logic [31:0] TARGET_BASE_ADDR [NUM_TARGETS] = '{default: 32'h0},
  parameter logic [15:0] TARGET_MAX_XFER  [NUM_TARGETS] = '{default: 16'd128},
  parameter logic [7:0]  TARGET_ALIGN     [NUM_TARGETS] = '{default: 8'd4},
  parameter logic [31:0] TARGET_NAME      [NUM_TARGETS] = '{default: 32'h3F3F3F3F}
)(
  input  wire clk,
  input  wire rst_n,

  // Request interface (od xfcp_fabric_endpoint)
  input  logic          ti_req_valid_i,
  output logic          ti_req_ready_o,
  input  xfcp_req_hdr_t ti_req_hdr_i,

  // Datovy kanal -> xfcp_fabric_endpoint -> xfcp_tx_packetizer
  output logic [31:0]   ti_rdata_o,
  output logic          ti_rdata_valid_o,
  input  logic          ti_rdata_ready_i,

  // Done signal -> xfcp_fabric_endpoint (inkrement ti_done_cnt)
  output logic          ti_resp_done_o,
  output logic [7:0]    ti_resp_status_o
);

  // synthesis translate_off
  initial begin
    if (NUM_TARGETS < 1 || NUM_TARGETS > 256)
      $fatal(1, "%m: NUM_TARGETS musi byt 1-256, got %0d", NUM_TARGETS);
  end
  // synthesis translate_on

  // ── FSM ──────────────────────────────────────────────────────────────────
  // ST_IDLE     : caka na request
  // ST_DONE_PLS : 1-cyklovy done pulse (ti_done_cnt++ v fabric_endpoint)
  // ST_DATA     : posiela word0..word3 cez rdata
  typedef enum logic [1:0] {
    ST_IDLE     = 2'd0,
    ST_DONE_PLS = 2'd1,
    ST_DATA     = 2'd2
  } state_e;

  state_e    state_q;
  logic [1:0] word_idx_q;  // 0..3 (4 slova = 16B)
  logic [7:0] index_q;     // ulozeny ADDR[7:0] z requestu
  logic       bad_index_q; // 1 ak index >= NUM_TARGETS

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= ST_IDLE;
      word_idx_q  <= 2'd0;
      index_q     <= 8'h0;
      bad_index_q <= 1'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (ti_req_valid_i) begin
            index_q     <= ti_req_hdr_i.addr[7:0];
            bad_index_q <= (ti_req_hdr_i.addr[7:0] >= 8'(NUM_TARGETS));
            word_idx_q  <= 2'd0;
            state_q     <= ST_DONE_PLS;
          end
        end

        ST_DONE_PLS: begin
          state_q <= ST_DATA;
        end

        ST_DATA: begin
          if (ti_rdata_ready_i) begin
            if (word_idx_q == 2'd3)
              state_q <= ST_IDLE;
            else
              word_idx_q <= word_idx_q + 2'd1;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // ── ROM lookup (kombinacne) ────────────────────────────────────────────────
  // Indexuje do parametrickych poli. Pre bad_index_q vrati nuly.
  logic [31:0] rom_word [0:3];

  always_comb begin
    if (bad_index_q) begin
      rom_word[0] = '0;
      rom_word[1] = '0;
      rom_word[2] = '0;
      rom_word[3] = '0;
    end else begin
      rom_word[0] = {TARGET_TYPE[index_q], index_q, 8'h00, 8'h00};
      rom_word[1] = TARGET_BASE_ADDR[index_q];
      rom_word[2] = {TARGET_MAX_XFER[index_q][15:8],
                     TARGET_MAX_XFER[index_q][ 7:0],
                     TARGET_ALIGN[index_q],
                     8'h00};
      rom_word[3] = TARGET_NAME[index_q];
    end
  end

  assign ti_req_ready_o   = (state_q == ST_IDLE);
  assign ti_resp_done_o   = (state_q == ST_DONE_PLS);
  assign ti_rdata_valid_o = (state_q == ST_DATA);
  assign ti_rdata_o       = rom_word[word_idx_q];
  assign ti_resp_status_o = bad_index_q ? 8'(XFCP_ST_BAD_ADDRESS) : 8'h00;

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (ti_req_valid_i && ti_req_ready_o) begin
        if (8'(NUM_TARGETS) <= ti_req_hdr_i.addr[7:0])
          $display("[%0t] %m: GET_TARGET_INFO seq=0x%02h index=%0d -> BAD_ADDRESS",
                   $time, ti_req_hdr_i.seq, ti_req_hdr_i.addr[7:0]);
        else
          $display("[%0t] %m: GET_TARGET_INFO seq=0x%02h index=%0d type=0x%02h name=%s",
                   $time, ti_req_hdr_i.seq, ti_req_hdr_i.addr[7:0],
                   TARGET_TYPE[ti_req_hdr_i.addr[7:0]],
                   string'(TARGET_NAME[ti_req_hdr_i.addr[7:0]]));
      end
    end
  end
  // synthesis translate_on

endmodule : xfcp_target_info_adapter

`endif  // XFCP_TARGET_INFO_ADAPTER_SV
