/**
 * @file eth_header_parser.sv
 * @brief Parses Ethernet header, filters by MAC, forwards payload via AXI-Stream.
 * @details FSM states:
 *   ST_HEADER — collects 14 header bytes (s_axis_tready=1, no downstream stall).
 *   ST_PAYLOAD — forwards payload bytes with backpressure (s_axis_tready=m_axis_tready).
 *   ST_DROP — consumes frame bytes without forwarding (s_axis_tready=1, no downstream stall).
 * Drop decision is evaluated from the fully-registered dst_mac when byte 13 arrives.
 * Short frames (tlast before byte 13) are discarded: FSM resets to ST_HEADER.
 * @param None
 */

`ifndef ETH_HEADER_PARSER_SV
`define ETH_HEADER_PARSER_SV

`default_nettype none

import eth_pkg::*;

module eth_header_parser (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic [47:0] local_mac_i,
  input  wire logic        accept_broadcast_i,
  input  wire logic        promiscuous_i,

  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  output      logic        s_axis_tready,
  input  wire logic        s_axis_tlast,
  input  wire logic        s_axis_tuser,

  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  input  wire logic        m_axis_tready,
  output      logic        m_axis_tlast,
  output      logic        m_axis_tuser,

  output      logic [47:0] rx_dst_mac_o,
  output      logic [47:0] rx_src_mac_o,
  output      logic [15:0] rx_ethertype_o,
  output      logic        hdr_valid_o,
  output      logic        drop_o
);

  typedef enum logic [1:0] {
    ST_HEADER  = 2'd0,
    ST_PAYLOAD = 2'd1,
    ST_DROP    = 2'd2
  } state_e;

  state_e state_q;

  logic [3:0]           byte_cnt;
  eth_hdr_t    header_reg;

  // Drop decision: computed from fully-registered dst_mac (valid when byte_cnt==13)
  logic drop_decision_w;
  assign drop_decision_w = !promiscuous_i &&
                           (header_reg.dst_mac != local_mac_i) &&
                           !(accept_broadcast_i &&
                             (header_reg.dst_mac == ETH_BROADCAST_MAC));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= ST_HEADER;
      byte_cnt   <= 4'd0;
      header_reg <= '0;
    end else begin
      case (state_q)

        ST_HEADER: begin
          // s_axis_tready=1 here; consume unconditionally when tvalid
          if (s_axis_tvalid) begin
            if (s_axis_tlast) begin
              // Short frame (< 14 bytes) — discard and reset
              byte_cnt   <= 4'd0;
              header_reg <= '0;
            end else begin
              case (byte_cnt)
                4'd0:  header_reg.dst_mac[47:40] <= s_axis_tdata;
                4'd1:  header_reg.dst_mac[39:32] <= s_axis_tdata;
                4'd2:  header_reg.dst_mac[31:24] <= s_axis_tdata;
                4'd3:  header_reg.dst_mac[23:16] <= s_axis_tdata;
                4'd4:  header_reg.dst_mac[15:8]  <= s_axis_tdata;
                4'd5:  header_reg.dst_mac[7:0]   <= s_axis_tdata;
                4'd6:  header_reg.src_mac[47:40] <= s_axis_tdata;
                4'd7:  header_reg.src_mac[39:32] <= s_axis_tdata;
                4'd8:  header_reg.src_mac[31:24] <= s_axis_tdata;
                4'd9:  header_reg.src_mac[23:16] <= s_axis_tdata;
                4'd10: header_reg.src_mac[15:8]  <= s_axis_tdata;
                4'd11: header_reg.src_mac[7:0]   <= s_axis_tdata;
                4'd12: header_reg.ethertype[15:8] <= s_axis_tdata;
                4'd13: begin
                  header_reg.ethertype[7:0] <= s_axis_tdata;
                  state_q <= drop_decision_w ? ST_DROP : ST_PAYLOAD;
                end
                default: ;
              endcase
              byte_cnt <= byte_cnt + 4'd1;
            end
          end
        end

        ST_PAYLOAD: begin
          // s_axis_tready=m_axis_tready here
          if (s_axis_tvalid && m_axis_tready && s_axis_tlast) begin
            state_q  <= ST_HEADER;
            byte_cnt <= 4'd0;
          end
        end

        ST_DROP: begin
          // s_axis_tready=1 here; consume without forwarding
          if (s_axis_tvalid && s_axis_tlast) begin
            state_q  <= ST_HEADER;
            byte_cnt <= 4'd0;
          end
        end

        default: state_q <= ST_HEADER;

      endcase
    end
  end

  // Stream routing: ST_PAYLOAD forwards with backpressure; all other states accept freely
  assign s_axis_tready = (state_q == ST_PAYLOAD) ? m_axis_tready : 1'b1;

  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid && (state_q == ST_PAYLOAD);
  assign m_axis_tlast  = s_axis_tlast;
  assign m_axis_tuser  = s_axis_tuser;

  // Header outputs (valid and stable once state_q == ST_PAYLOAD)
  assign rx_dst_mac_o   = header_reg.dst_mac;
  assign rx_src_mac_o   = header_reg.src_mac;
  assign rx_ethertype_o = header_reg.ethertype;
  assign hdr_valid_o    = (state_q == ST_PAYLOAD);
  assign drop_o         = (state_q == ST_DROP);

endmodule

`endif // ETH_HEADER_PARSER_SV
