/**
 * @file eth_header_parser.sv
 * @brief Parses Ethernet header, filters by MAC, forwards payload via AXI-Stream.
 * @details FSM states:
 *   ST_HEADER  -- collects 14 header bytes (s_axis_tready=1, no downstream stall).
 *   ST_PAYLOAD -- forwards payload bytes with backpressure (s_axis_tready=m_axis_tready).
 *   ST_DROP    -- consumes frame bytes without forwarding (s_axis_tready=1).
 * MAC accept decision uses explicit dst_mac_q / mac_accept_q registers (no packed struct)
 * to avoid Quartus Lite packed-struct member comparison synthesis issue.
 * mac_accept_q is registered at byte 5 from combinatorial dst_mac_complete_w;
 * state transition at byte 13 uses only the pre-registered mac_accept_q.
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
  output      logic        drop_o,

  // 1-cycle registered pulses fired when header decision is made (byte 13)
  output      logic        hdr_done_pulse_o,
  output      logic        hdr_accept_pulse_o,
  output      logic        hdr_drop_pulse_o,

  // First-frame capture (latched after reset) for HW debug
  output      logic [47:0] dbg_dst_mac_o,
  output      logic        dbg_mac_accept_o
);

  typedef enum logic [1:0] {
    ST_HEADER  = 2'd0,
    ST_PAYLOAD = 2'd1,
    ST_DROP    = 2'd2
  } state_e;

  state_e      state_q;
  logic [3:0]  byte_cnt_q;

  logic [47:0] dst_mac_q;
  logic [47:0] src_mac_q;
  logic [15:0] ethertype_q;
  logic        mac_accept_q;

  // Combinatorial complete dst_mac when byte 5 arrives — avoids packed-struct on critical path
  logic [47:0] dst_mac_complete_w;
  assign dst_mac_complete_w = {dst_mac_q[47:8], s_axis_tdata};

  logic dbg_locked_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q            <= ST_HEADER;
      byte_cnt_q         <= 4'd0;
      dst_mac_q          <= '0;
      src_mac_q          <= '0;
      ethertype_q        <= '0;
      mac_accept_q       <= 1'b0;
      hdr_done_pulse_o   <= 1'b0;
      hdr_accept_pulse_o <= 1'b0;
      hdr_drop_pulse_o   <= 1'b0;
      dbg_locked_q       <= 1'b0;
      dbg_dst_mac_o      <= '0;
      dbg_mac_accept_o   <= 1'b0;
    end else begin
      hdr_done_pulse_o   <= 1'b0;
      hdr_accept_pulse_o <= 1'b0;
      hdr_drop_pulse_o   <= 1'b0;

      case (state_q)

        ST_HEADER: begin
          if (s_axis_tvalid) begin
            if (s_axis_tlast) begin
              // Short frame before byte 13 -- discard, reset
              byte_cnt_q  <= 4'd0;
              dst_mac_q   <= '0;
              src_mac_q   <= '0;
              ethertype_q <= '0;
            end else begin
              byte_cnt_q <= byte_cnt_q + 4'd1;
              case (byte_cnt_q)
                4'd0:  dst_mac_q[47:40] <= s_axis_tdata;
                4'd1:  dst_mac_q[39:32] <= s_axis_tdata;
                4'd2:  dst_mac_q[31:24] <= s_axis_tdata;
                4'd3:  dst_mac_q[23:16] <= s_axis_tdata;
                4'd4:  dst_mac_q[15:8]  <= s_axis_tdata;
                4'd5: begin
                  dst_mac_q[7:0] <= s_axis_tdata;
                  // Register accept decision from combinatorial dst_mac_complete_w
                  mac_accept_q   <= promiscuous_i ||
                                    (dst_mac_complete_w == local_mac_i) ||
                                    (accept_broadcast_i &&
                                     (dst_mac_complete_w == ETH_BROADCAST_MAC));
                end
                4'd6:  src_mac_q[47:40] <= s_axis_tdata;
                4'd7:  src_mac_q[39:32] <= s_axis_tdata;
                4'd8:  src_mac_q[31:24] <= s_axis_tdata;
                4'd9:  src_mac_q[23:16] <= s_axis_tdata;
                4'd10: src_mac_q[15:8]  <= s_axis_tdata;
                4'd11: src_mac_q[7:0]   <= s_axis_tdata;
                4'd12: ethertype_q[15:8] <= s_axis_tdata;
                4'd13: begin
                  ethertype_q[7:0]   <= s_axis_tdata;
                  hdr_done_pulse_o   <= 1'b1;
                  hdr_accept_pulse_o <= mac_accept_q;
                  hdr_drop_pulse_o   <= !mac_accept_q;
                  state_q            <= mac_accept_q ? ST_PAYLOAD : ST_DROP;
                  if (!dbg_locked_q) begin
                    dbg_locked_q     <= 1'b1;
                    dbg_dst_mac_o    <= dst_mac_q;
                    dbg_mac_accept_o <= mac_accept_q;
                  end
                end
                default: ;
              endcase
            end
          end
        end

        ST_PAYLOAD: begin
          if (s_axis_tvalid && m_axis_tready && s_axis_tlast) begin
            state_q    <= ST_HEADER;
            byte_cnt_q <= 4'd0;
          end
        end

        ST_DROP: begin
          if (s_axis_tvalid && s_axis_tlast) begin
            state_q    <= ST_HEADER;
            byte_cnt_q <= 4'd0;
          end
        end

        default: state_q <= ST_HEADER;

      endcase
    end
  end

  assign s_axis_tready = (state_q == ST_PAYLOAD) ? m_axis_tready : 1'b1;

  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid && (state_q == ST_PAYLOAD);
  assign m_axis_tlast  = s_axis_tlast;
  assign m_axis_tuser  = s_axis_tuser;

  assign rx_dst_mac_o   = dst_mac_q;
  assign rx_src_mac_o   = src_mac_q;
  assign rx_ethertype_o = ethertype_q;
  assign hdr_valid_o    = (state_q == ST_PAYLOAD);
  assign drop_o         = (state_q == ST_DROP);

endmodule

`endif // ETH_HEADER_PARSER_SV
