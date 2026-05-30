/**
 * @file udp_ipv4_tx_builder.sv
 * @brief Builds an IPv4+UDP header stream prepended to a UDP payload.
 * @details Combines IPv4 header (20 B) and UDP header (8 B) into a 28-byte
 *   header that is emitted byte-by-byte before the upstream payload.
 *   IPv4 header checksum is computed combinatorially via ipv4_checksum.
 *   UDP checksum is set to 0x0000 (disabled, valid for IPv4 per RFC 768).
 *
 * FSM states:
 *   ST_IDLE   — waits for tx_meta_valid_i; latches metadata and precomputes lengths.
 *   ST_HDR    — streams 28 header bytes (IPv4 20 B + UDP 8 B) to m_axis.
 *   ST_PAYLOAD — forwards s_axis payload byte-by-byte; m_axis_tlast = s_axis_tlast.
 *
 * IPv4 fixed fields: VER/IHL=0x45, DSCP=0x00, ID=0x0000, Flags=DF (0x4000),
 *   TTL=64, Protocol=0x11 (UDP).
 *
 * @param tx_meta_i.payload_len  UDP payload length in bytes (<=65507).
 * @param ipv4_total_len_o       IPv4 total length = 28 + payload_len (informational).
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
  input  wire udp_packet_meta_t tx_meta_i,

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

  typedef enum logic [1:0] {
    ST_IDLE    = 2'd0,
    ST_HDR     = 2'd1,
    ST_PAYLOAD = 2'd2
  } state_e;

  state_e                    state_q;
  logic [4:0]                hdr_cnt_q;
  udp_packet_meta_t tx_meta_q;
  logic [15:0]               total_len_q;
  logic [15:0]               udp_len_q;

  // IPv4 header with checksum field zeroed (for checksum computation).
  logic [159:0] ipv4_hdr_w;
  assign ipv4_hdr_w = {
    8'h45, 8'h00,
    total_len_q[15:8], total_len_q[7:0],
    8'h00, 8'h00,
    8'h40, 8'h00,
    8'h40, 8'h11,
    8'h00, 8'h00,
    tx_meta_q.src_ip[31:24], tx_meta_q.src_ip[23:16],
    tx_meta_q.src_ip[15:8],  tx_meta_q.src_ip[7:0],
    tx_meta_q.dst_ip[31:24], tx_meta_q.dst_ip[23:16],
    tx_meta_q.dst_ip[15:8],  tx_meta_q.dst_ip[7:0]
  };

  logic [15:0] ipv4_csum_w;
  ipv4_checksum u_csum (
    .header_i  (ipv4_hdr_w),
    .checksum_o(ipv4_csum_w)
  );

  // Header byte mux: bytes 0-19 = IPv4, bytes 20-27 = UDP.
  logic [7:0] hdr_byte_w;
  always_comb begin
    case (hdr_cnt_q)
      5'd0:    hdr_byte_w = 8'h45;
      5'd1:    hdr_byte_w = 8'h00;
      5'd2:    hdr_byte_w = total_len_q[15:8];
      5'd3:    hdr_byte_w = total_len_q[7:0];
      5'd4:    hdr_byte_w = 8'h00;
      5'd5:    hdr_byte_w = 8'h00;
      5'd6:    hdr_byte_w = 8'h40;
      5'd7:    hdr_byte_w = 8'h00;
      5'd8:    hdr_byte_w = 8'h40;
      5'd9:    hdr_byte_w = 8'h11;
      5'd10:   hdr_byte_w = ipv4_csum_w[15:8];
      5'd11:   hdr_byte_w = ipv4_csum_w[7:0];
      5'd12:   hdr_byte_w = tx_meta_q.src_ip[31:24];
      5'd13:   hdr_byte_w = tx_meta_q.src_ip[23:16];
      5'd14:   hdr_byte_w = tx_meta_q.src_ip[15:8];
      5'd15:   hdr_byte_w = tx_meta_q.src_ip[7:0];
      5'd16:   hdr_byte_w = tx_meta_q.dst_ip[31:24];
      5'd17:   hdr_byte_w = tx_meta_q.dst_ip[23:16];
      5'd18:   hdr_byte_w = tx_meta_q.dst_ip[15:8];
      5'd19:   hdr_byte_w = tx_meta_q.dst_ip[7:0];
      5'd20:   hdr_byte_w = tx_meta_q.src_port[15:8];
      5'd21:   hdr_byte_w = tx_meta_q.src_port[7:0];
      5'd22:   hdr_byte_w = tx_meta_q.dst_port[15:8];
      5'd23:   hdr_byte_w = tx_meta_q.dst_port[7:0];
      5'd24:   hdr_byte_w = udp_len_q[15:8];
      5'd25:   hdr_byte_w = udp_len_q[7:0];
      5'd26:   hdr_byte_w = 8'h00;
      5'd27:   hdr_byte_w = 8'h00;
      default: hdr_byte_w = 8'h00;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= ST_IDLE;
      hdr_cnt_q   <= 5'd0;
      tx_meta_q   <= '0;
      total_len_q <= 16'd0;
      udp_len_q   <= 16'd0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (tx_meta_valid_i) begin
            tx_meta_q   <= tx_meta_i;
            total_len_q <= 16'd28 + tx_meta_i.payload_len;
            udp_len_q   <= 16'd8  + tx_meta_i.payload_len;
            hdr_cnt_q   <= 5'd0;
            state_q     <= ST_HDR;
          end
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

  assign m_axis_tdata    = (state_q == ST_HDR) ? hdr_byte_w : s_axis_tdata;
  assign m_axis_tvalid   = (state_q == ST_HDR) ||
                           (s_axis_tvalid && (state_q == ST_PAYLOAD));
  assign m_axis_tlast    = ((state_q == ST_PAYLOAD) && s_axis_tvalid && s_axis_tlast) ||
                           ((state_q == ST_HDR) && (hdr_cnt_q == 5'd27) && (tx_meta_q.payload_len == '0));

  assign ipv4_total_len_o = total_len_q;

endmodule

`endif // UDP_IPV4_TX_BUILDER_SV
