/**
 * @file udp_ipv4_tx_builder.sv
 * @brief Builds an IPv4+UDP header stream prepended to a UDP payload.
 * @details Pipelined checksum computation eliminates ETH_RXC timing violations.
 *   Every register-to-register path has exactly 2 operands (one register plus
 *   one 16-bit zero-extended word), limiting the carry chain to <=17 stages
 *   (~6.7 ns) well inside the 8 ns ETH_RXC window.
 *
 * FSM states (4-bit, 10 states):
 *   ST_IDLE     -- waits for tx_meta_valid_i; latches metadata, no computation.
 *   ST_LEN      -- total_len, udp_len, csum_q seed: csum_q = 0xC52D + payload_len.
 *   ST_CSUM0    -- csum_q += {16'd0, src_ip[31:16]}  (2 operands)
 *   ST_CSUM1    -- csum_q += {16'd0, src_ip[15:0]}   (2 operands)
 *   ST_CSUM2    -- csum_q += {16'd0, dst_ip[31:16]}  (2 operands)
 *   ST_CSUM3    -- csum_q += {16'd0, dst_ip[15:0]}   (2 operands)
 *   ST_FOLD     -- two-pass 16-bit fold of csum_q, stores ~result in ipv4_csum_q.
 *   ST_FILL_HDR -- writes all 28 header bytes from locally registered values.
 *   ST_HDR      -- streams hdr_q[hdr_cnt_q] to m_axis.
 *   ST_PAYLOAD  -- forwards s_axis payload; m_axis_tlast = s_axis_tlast.
 *
 * IPv4 fixed fields: VER/IHL=0x45, DSCP=0x00, ID=0x0000, Flags=DF (0x4000),
 *   TTL=64, Protocol=0x11 (UDP).  UDP checksum disabled (0x0000, RFC 768).
 *
 * @param tx_meta_i.payload_len  UDP payload length in bytes (<=65507).
 * @param ipv4_total_len_o       IPv4 total length = 28 + payload_len.
 */

`ifndef UDP_IPV4_TX_BUILDER_SV
`define UDP_IPV4_TX_BUILDER_SV

`default_nettype none

import eth_pkg::*;

module udp_ipv4_tx_builder (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic        tx_meta_valid_i,
  output      logic        tx_meta_ready_o,
  input       udp_packet_meta_t tx_meta_i,

  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  output      logic        s_axis_tready,
  input  wire logic        s_axis_tlast,

  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  input  wire logic        m_axis_tready,
  output      logic        m_axis_tlast,

  output      logic [15:0] ipv4_total_len_o
);

  typedef enum logic [3:0] {
    ST_IDLE     = 4'd0,
    ST_LEN      = 4'd1,
    ST_CSUM0    = 4'd2,
    ST_CSUM1    = 4'd3,
    ST_CSUM2    = 4'd4,
    ST_CSUM3    = 4'd5,
    ST_FOLD     = 4'd6,
    ST_FILL_HDR = 4'd7,
    ST_HDR      = 4'd8,
    ST_PAYLOAD  = 4'd9
  } state_e;

  state_e           state_q;
  logic [4:0]       hdr_cnt_q;
  udp_packet_meta_t tx_meta_q;
  logic [15:0]      total_len_q;
  logic [15:0]      udp_len_q;
  logic [7:0]       hdr_q [0:27];

  // Single 32-bit checksum accumulator; one 16-bit word added per CSUM state.
  logic [31:0] csum_q;
  logic [15:0] ipv4_csum_q;

  // Combinatorial fold of csum_q used only in ST_FOLD (no timing pressure).
  logic [16:0] fold1_w;
  logic [15:0] fold2_w;
  assign fold1_w = {1'b0, csum_q[15:0]} + {1'b0, csum_q[31:16]};
  assign fold2_w = fold1_w[15:0] + {15'b0, fold1_w[16]};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= ST_IDLE;
      hdr_cnt_q   <= 5'd0;
      tx_meta_q   <= '0;
      total_len_q <= 16'd0;
      udp_len_q   <= 16'd0;
      csum_q      <= 32'd0;
      ipv4_csum_q <= 16'd0;
    end else begin
      case (state_q)

        // Pure latch -- no computation, cuts cross-module routing from adder paths.
        ST_IDLE: begin
          if (tx_meta_valid_i) begin
            tx_meta_q <= tx_meta_i;
            state_q   <= ST_LEN;
          end
        end

        // 2-operand seed: constant 0xC52D (= fixed IPv4 header sum 0xC511 +
        // total_len contribution 0x001C) plus payload_len.
        ST_LEN: begin
          total_len_q <= 16'd28 + tx_meta_q.payload_len;
          udp_len_q   <= 16'd8  + tx_meta_q.payload_len;
          csum_q      <= 32'h0000C52D + {16'd0, tx_meta_q.payload_len};
          state_q     <= ST_CSUM0;
        end

        // One 16-bit word per state; each is a 2-operand addition.
        ST_CSUM0: begin
          csum_q  <= csum_q + {16'd0, tx_meta_q.src_ip[31:16]};
          state_q <= ST_CSUM1;
        end

        ST_CSUM1: begin
          csum_q  <= csum_q + {16'd0, tx_meta_q.src_ip[15:0]};
          state_q <= ST_CSUM2;
        end

        ST_CSUM2: begin
          csum_q  <= csum_q + {16'd0, tx_meta_q.dst_ip[31:16]};
          state_q <= ST_CSUM3;
        end

        ST_CSUM3: begin
          csum_q  <= csum_q + {16'd0, tx_meta_q.dst_ip[15:0]};
          state_q <= ST_FOLD;
        end

        // Two-pass fold + one's complement; only 2 adds + invert.
        ST_FOLD: begin
          ipv4_csum_q <= ~fold2_w;
          state_q     <= ST_FILL_HDR;
        end

        // Write all 28 header bytes from registered values only.
        ST_FILL_HDR: begin
          hdr_q[0]  <= 8'h45;
          hdr_q[1]  <= 8'h00;
          hdr_q[2]  <= total_len_q[15:8];
          hdr_q[3]  <= total_len_q[7:0];
          hdr_q[4]  <= 8'h00;
          hdr_q[5]  <= 8'h00;
          hdr_q[6]  <= 8'h40;
          hdr_q[7]  <= 8'h00;
          hdr_q[8]  <= 8'h40;
          hdr_q[9]  <= 8'h11;
          hdr_q[10] <= ipv4_csum_q[15:8];
          hdr_q[11] <= ipv4_csum_q[7:0];
          hdr_q[12] <= tx_meta_q.src_ip[31:24];
          hdr_q[13] <= tx_meta_q.src_ip[23:16];
          hdr_q[14] <= tx_meta_q.src_ip[15:8];
          hdr_q[15] <= tx_meta_q.src_ip[7:0];
          hdr_q[16] <= tx_meta_q.dst_ip[31:24];
          hdr_q[17] <= tx_meta_q.dst_ip[23:16];
          hdr_q[18] <= tx_meta_q.dst_ip[15:8];
          hdr_q[19] <= tx_meta_q.dst_ip[7:0];
          hdr_q[20] <= tx_meta_q.src_port[15:8];
          hdr_q[21] <= tx_meta_q.src_port[7:0];
          hdr_q[22] <= tx_meta_q.dst_port[15:8];
          hdr_q[23] <= tx_meta_q.dst_port[7:0];
          hdr_q[24] <= udp_len_q[15:8];
          hdr_q[25] <= udp_len_q[7:0];
          hdr_q[26] <= 8'h00;
          hdr_q[27] <= 8'h00;
          hdr_cnt_q <= 5'd0;
          state_q   <= ST_HDR;
        end

        ST_HDR: begin
          if (m_axis_tready) begin
            if (hdr_cnt_q == 5'd27) begin
              hdr_cnt_q <= 5'd0;
              state_q   <= (tx_meta_q.payload_len == '0) ? ST_IDLE : ST_PAYLOAD;
            end else begin
              hdr_cnt_q <= hdr_cnt_q + 5'd1;
            end
          end
        end

        ST_PAYLOAD: begin
          if (s_axis_tvalid && m_axis_tready && s_axis_tlast)
            state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign tx_meta_ready_o = (state_q == ST_IDLE);
  assign s_axis_tready   = (state_q == ST_PAYLOAD) && m_axis_tready;

  assign m_axis_tdata    = (state_q == ST_HDR) ? hdr_q[hdr_cnt_q] : s_axis_tdata;
  assign m_axis_tvalid   = (state_q == ST_HDR) ||
                           (s_axis_tvalid && (state_q == ST_PAYLOAD));
  assign m_axis_tlast    = ((state_q == ST_PAYLOAD) && s_axis_tvalid && s_axis_tlast) ||
                           ((state_q == ST_HDR) && (hdr_cnt_q == 5'd27) &&
                            (tx_meta_q.payload_len == '0));

  assign ipv4_total_len_o = total_len_q;

endmodule

`endif // UDP_IPV4_TX_BUILDER_SV
