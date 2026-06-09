/**
 * @file    xfcp_arbiter_2to1.sv
 * @brief   2-to-1 XFCP packet arbiter s response de-multiplexerom.
 * @param   ORD_FIFO_DEPTH  Hlbka order FIFO (max outstanding requests).
 * @details
 *   Port 0 (UART): bajt-stream bez TLAST. Arbiter parsuje XFCP hlavicku
 *   a generuje synteticke TLAST po poslednom bajte paketu.
 *   Poradi bajtov:
 *     0=SOP  1=OP  2=SEQ  3=CNT_H  4=CNT_L  5-8=ADDR[3:0]  9+=PAYLOAD(WRITE)
 *   Pre WRITE: p0_remain = COUNT bajtov payloadu.
 *   Pre READ/ID: p0_remain = 0, TLAST sa generuje na bajte ADDR3 (bajt 8).
 *
 *   Port 1 (ETH-UDP): framed stream s prirodzenym TLAST na konci UDP datagramu.
 *
 *   Arbitracna politika: fixed priority, Port 0 (UART) > Port 1 (ETH).
 *   Prepnutie vzdy na hranici paketu.
 *
 *   Order FIFO sleduje, ktory port poslal kazdy request, aby sa response
 *   spravne smeroval spat (m0=UART, m1=ETH).
 */

`ifndef XFCP_ARBITER_2TO1_SV
`define XFCP_ARBITER_2TO1_SV

`default_nettype none

import xfcp_pkg::*;

module xfcp_arbiter_2to1 #(
  parameter int ORD_FIFO_DEPTH = 8
)(
  input  logic       clk_i,
  input  logic       rst_ni,

  // Port 0: UART (TLAST always 0 — parser generuje synteticke TLAST)
  input  logic       s0_valid_i,
  output logic       s0_ready_o,
  input  logic [7:0] s0_data_i,

  // Port 1: ETH-UDP (TLAST=1 na konci UDP datagramu)
  input  logic       s1_valid_i,
  output logic       s1_ready_o,
  input  logic [7:0] s1_data_i,
  input  logic       s1_last_i,

  // Vystup na XFCP fabric endpoint
  output logic       m_valid_o,
  input  logic       m_ready_i,
  output logic [7:0] m_data_o,
  output logic       m_last_o,

  // Response vstup z XFCP fabric endpoint
  input  logic       s_resp_valid_i,
  output logic       s_resp_ready_o,
  input  logic [7:0] s_resp_data_i,
  input  logic       s_resp_last_i,

  // Response vystup Port 0 (UART)
  output logic       m0_valid_o,
  input  logic       m0_ready_i,
  output logic [7:0] m0_data_o,
  output logic       m0_last_o,

  // Response vystup Port 1 (ETH)
  output logic       m1_valid_o,
  input  logic       m1_ready_i,
  output logic [7:0] m1_data_o,
  output logic       m1_last_o
);

  // =========================================================================
  // Arbiter state
  // =========================================================================
  typedef enum logic [1:0] {
    ARB_IDLE   = 2'd0,
    ARB_GRANT0 = 2'd1,
    ARB_GRANT1 = 2'd2
  } arb_state_e;

  arb_state_e arb_q, arb_d;

  // =========================================================================
  // Port 0 XFCP header parser
  // =========================================================================
  typedef enum logic [3:0] {
    P0_SOP    = 4'd0,
    P0_OP     = 4'd1,
    P0_SEQ    = 4'd2,
    P0_CNT_H  = 4'd3,
    P0_CNT_L  = 4'd4,
    P0_ADDR0  = 4'd5,
    P0_ADDR1  = 4'd6,
    P0_ADDR2  = 4'd7,
    P0_ADDR3  = 4'd8,  // last header byte; TLAST tu ak remain==0
    P0_DATA   = 4'd9   // payload (WRITE only)
  } p0_state_e;

  p0_state_e   p0_state_q, p0_state_d;
  logic [7:0]  p0_op_q;      // zachyteny opcode
  logic [7:0]  p0_cnt_h_q;   // COUNT high byte
  logic [15:0] p0_remain_q;  // zostatok payload bajtov
  logic        s1_in_frame_q;

  // Beat: bajt bol preneseny Port0 -> endpoint
  wire p0_beat_w = (arb_q == ARB_GRANT0) && s0_valid_i && m_ready_i;

  // Synteticke TLAST pre Port 0
  wire p0_tlast_w =
    (p0_state_q == P0_ADDR3 && p0_remain_q == 16'h0) ||
    (p0_state_q == P0_DATA  && p0_remain_q == 16'h1);

  // Is current opcode a WRITE (has payload in request)?
  wire p0_is_write_w = (p0_op_q == {XFCP_OP_WRITE});

  always_comb begin
    p0_state_d = p0_state_q;
    if (p0_beat_w) begin
      case (p0_state_q)
        P0_SOP:   p0_state_d = P0_OP;
        P0_OP:    p0_state_d = P0_SEQ;
        P0_SEQ:   p0_state_d = P0_CNT_H;
        P0_CNT_H: p0_state_d = P0_CNT_L;
        P0_CNT_L: p0_state_d = P0_ADDR0;
        P0_ADDR0: p0_state_d = P0_ADDR1;
        P0_ADDR1: p0_state_d = P0_ADDR2;
        P0_ADDR2: p0_state_d = P0_ADDR3;
        P0_ADDR3: p0_state_d = (p0_remain_q == 16'h0) ? P0_SOP : P0_DATA;
        P0_DATA:  p0_state_d = (p0_remain_q == 16'h1) ? P0_SOP : P0_DATA;
        default:  p0_state_d = P0_SOP;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      p0_state_q  <= P0_SOP;
      p0_op_q     <= 8'h0;
      p0_cnt_h_q  <= 8'h0;
      p0_remain_q <= 16'h0;
    end else if (p0_beat_w) begin
      p0_state_q <= p0_state_d;
      case (p0_state_q)
        P0_OP:    p0_op_q    <= s0_data_i;
        P0_CNT_H: p0_cnt_h_q <= s0_data_i;
        P0_CNT_L: begin
          // WRITE: remain = COUNT; READ/ID: remain = 0
          p0_remain_q <= p0_is_write_w ? {p0_cnt_h_q, s0_data_i} : 16'h0;
        end
        P0_DATA:  p0_remain_q <= p0_remain_q - 16'h1;
        default: ;
      endcase
    end
  end

  // =========================================================================
  // Order FIFO (1-bit: 0=UART, 1=ETH)
  // =========================================================================
  localparam int FIFO_AW = $clog2(ORD_FIFO_DEPTH);

  logic                 ord_mem_q [ORD_FIFO_DEPTH];
  logic [FIFO_AW-1:0]   ord_wr_q, ord_rd_q;
  logic [FIFO_AW:0]     ord_cnt_q;  // 0..ORD_FIFO_DEPTH

  wire ord_full_w  = (ord_cnt_q == (FIFO_AW+1)'(ORD_FIFO_DEPTH));
  wire ord_empty_w = (ord_cnt_q == '0);

  // Push on first accepted beat of each request (not at IDLE->GRANT transition)
  wire ord_push0_w = (arb_q == ARB_GRANT0) && p0_beat_w && (p0_state_q == P0_SOP);
  wire ord_push1_w = (arb_q == ARB_GRANT1) && s1_valid_i && m_ready_i && !s1_in_frame_q;
  wire ord_push_w  = ord_push0_w || ord_push1_w;

  // Pop: ked posledny bajt response prebehol cez de-mux
  wire resp_consumed_w = s_resp_valid_i && s_resp_last_i && s_resp_ready_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ord_wr_q  <= '0;
      ord_rd_q  <= '0;
      ord_cnt_q <= '0;
    end else begin
      if (ord_push_w) begin
        ord_mem_q[ord_wr_q] <= ord_push1_w;  // 0=UART, 1=ETH
        ord_wr_q <= ord_wr_q + 1'b1;
      end
      if (resp_consumed_w) begin
        ord_rd_q <= ord_rd_q + 1'b1;
      end
      // Citac: push a pop nemusia byt exclusive
      if (ord_push_w && !resp_consumed_w)
        ord_cnt_q <= ord_cnt_q + 1'b1;
      else if (!ord_push_w && resp_consumed_w)
        ord_cnt_q <= ord_cnt_q - 1'b1;
    end
  end

  // =========================================================================
  // Arbiter FSM
  // =========================================================================
  always_comb begin
    arb_d = arb_q;
    case (arb_q)
      ARB_IDLE: begin
        if (s0_valid_i && !ord_full_w)
          arb_d = ARB_GRANT0;
        else if (s1_valid_i && !ord_full_w)
          arb_d = ARB_GRANT1;
      end
      ARB_GRANT0: begin
        if (p0_beat_w && p0_tlast_w)
          arb_d = ARB_IDLE;
      end
      ARB_GRANT1: begin
        if (s1_valid_i && m_ready_i && s1_last_i)
          arb_d = ARB_IDLE;
      end
      default: arb_d = ARB_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      arb_q         <= ARB_IDLE;
      s1_in_frame_q <= 1'b0;
    end else begin
      arb_q <= arb_d;
      if (arb_q != ARB_GRANT1)
        s1_in_frame_q <= 1'b0;
      else if (s1_valid_i && m_ready_i)
        s1_in_frame_q <= !s1_last_i;
    end
  end

  // =========================================================================
  // Output MUX — request path
  // =========================================================================
  always_comb begin
    m_valid_o  = 1'b0;
    m_data_o   = 8'h0;
    m_last_o   = 1'b0;
    s0_ready_o = 1'b0;
    s1_ready_o = 1'b0;

    case (arb_q)
      ARB_GRANT0: begin
        m_valid_o  = s0_valid_i;
        m_data_o   = s0_data_i;
        m_last_o   = p0_tlast_w;
        s0_ready_o = m_ready_i;
      end
      ARB_GRANT1: begin
        m_valid_o  = s1_valid_i;
        m_data_o   = s1_data_i;
        m_last_o   = s1_last_i;
        s1_ready_o = m_ready_i;
      end
      default: ;
    endcase
  end

  // =========================================================================
  // Response de-mux
  // =========================================================================
  wire resp_sel_w = ord_empty_w ? 1'b0 : ord_mem_q[ord_rd_q];

  always_comb begin
    m0_valid_o     = 1'b0;
    m0_data_o      = s_resp_data_i;
    m0_last_o      = s_resp_last_i;
    m1_valid_o     = 1'b0;
    m1_data_o      = s_resp_data_i;
    m1_last_o      = s_resp_last_i;
    s_resp_ready_o = 1'b0;

    if (!ord_empty_w && s_resp_valid_i) begin
      if (!resp_sel_w) begin
        m0_valid_o     = 1'b1;
        s_resp_ready_o = m0_ready_i;
      end else begin
        m1_valid_o     = 1'b1;
        s_resp_ready_o = m1_ready_i;
      end
    end
  end

endmodule

`default_nettype wire

`endif // XFCP_ARBITER_2TO1_SV
