/**
 * @file eth_header_parser.sv
 * @brief Parses Ethernet header, filters by MAC, forwards payload via AXI-Stream.
 * @details FSM states:
 *   ST_HEADER  -- collects 14 header bytes (s_axis_tready=1, no downstream stall).
 *   ST_PAYLOAD -- forwards payload bytes with backpressure (s_axis_tready=m_axis_tready).
 *   ST_DROP    -- consumes frame bytes without forwarding (s_axis_tready=1).
 * MAC accept decision uses a byte-by-byte running match pipeline (mac_match_q /
 * bcast_match_q) updated at bytes 0-5, avoiding Quartus Lite misoptimisation of
 * 48-bit partial-slice register assignments used in comparisons.
 * mac_accept_q is registered at byte 6 from mac_match_q and bcast_match_q (both
 * pure 1-bit FF-only signals at that point); state transition at byte 13 uses
 * mac_accept_q.
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

  // Individual byte registers — avoids Quartus Lite partial-slice synthesis bugs.
  logic [7:0] dst_b0_q, dst_b1_q, dst_b2_q, dst_b3_q, dst_b4_q, dst_b5_q;
  logic [7:0] src_b0_q, src_b1_q, src_b2_q, src_b3_q, src_b4_q, src_b5_q;
  logic [7:0] eth_b0_q, eth_b1_q;
  logic        mac_accept_q;

  // Byte-by-byte running match: avoids 48-bit partial-slice synthesis issues in
  // Quartus Lite. Each is a 1-bit FF updated at bytes 0-5 (one 8-bit comparison
  // per byte). mac_match_q=1 iff all six bytes matched local_mac_i.
  logic mac_match_q;
  logic bcast_match_q;

  logic dbg_locked_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q            <= ST_HEADER;
      byte_cnt_q         <= 4'd0;
      dst_b0_q           <= 8'h00; dst_b1_q <= 8'h00; dst_b2_q <= 8'h00;
      dst_b3_q           <= 8'h00; dst_b4_q <= 8'h00; dst_b5_q <= 8'h00;
      src_b0_q           <= 8'h00; src_b1_q <= 8'h00; src_b2_q <= 8'h00;
      src_b3_q           <= 8'h00; src_b4_q <= 8'h00; src_b5_q <= 8'h00;
      eth_b0_q           <= 8'h00; eth_b1_q <= 8'h00;
      mac_accept_q       <= 1'b0;
      mac_match_q        <= 1'b0;
      bcast_match_q      <= 1'b0;
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
              byte_cnt_q <= 4'd0;
            end else begin
              byte_cnt_q <= byte_cnt_q + 4'd1;
              case (byte_cnt_q)
                4'd0: begin
                  dst_b0_q      <= s_axis_tdata;
                  mac_match_q   <= (s_axis_tdata == local_mac_i[47:40]);
                  bcast_match_q <= (s_axis_tdata == 8'hFF);
                end
                4'd1: begin
                  dst_b1_q      <= s_axis_tdata;
                  mac_match_q   <= mac_match_q   && (s_axis_tdata == local_mac_i[39:32]);
                  bcast_match_q <= bcast_match_q && (s_axis_tdata == 8'hFF);
                end
                4'd2: begin
                  dst_b2_q      <= s_axis_tdata;
                  mac_match_q   <= mac_match_q   && (s_axis_tdata == local_mac_i[31:24]);
                  bcast_match_q <= bcast_match_q && (s_axis_tdata == 8'hFF);
                end
                4'd3: begin
                  dst_b3_q      <= s_axis_tdata;
                  mac_match_q   <= mac_match_q   && (s_axis_tdata == local_mac_i[23:16]);
                  bcast_match_q <= bcast_match_q && (s_axis_tdata == 8'hFF);
                end
                4'd4: begin
                  dst_b4_q      <= s_axis_tdata;
                  mac_match_q   <= mac_match_q   && (s_axis_tdata == local_mac_i[15:8]);
                  bcast_match_q <= bcast_match_q && (s_axis_tdata == 8'hFF);
                end
                4'd5: begin
                  dst_b5_q      <= s_axis_tdata;
                  mac_match_q   <= mac_match_q   && (s_axis_tdata == local_mac_i[7:0]);
                  bcast_match_q <= bcast_match_q && (s_axis_tdata == 8'hFF);
                end
                4'd6: begin
                  src_b0_q     <= s_axis_tdata;
                  // mac_match_q holds cumulative match for all 6 DST_MAC bytes
                  mac_accept_q <= promiscuous_i || mac_match_q ||
                                  (accept_broadcast_i && bcast_match_q);
                end
                4'd7:  src_b1_q <= s_axis_tdata;
                4'd8:  src_b2_q <= s_axis_tdata;
                4'd9:  src_b3_q <= s_axis_tdata;
                4'd10: src_b4_q <= s_axis_tdata;
                4'd11: src_b5_q <= s_axis_tdata;
                4'd12: eth_b0_q <= s_axis_tdata;
                4'd13: begin
                  eth_b1_q           <= s_axis_tdata;
                  hdr_done_pulse_o   <= 1'b1;
                  hdr_accept_pulse_o <= mac_accept_q;
                  hdr_drop_pulse_o   <= !mac_accept_q;
                  state_q            <= mac_accept_q ? ST_PAYLOAD : ST_DROP;
                  if (!dbg_locked_q) begin
                    dbg_locked_q     <= 1'b1;
                    dbg_dst_mac_o    <= {dst_b0_q, dst_b1_q, dst_b2_q,
                                         dst_b3_q, dst_b4_q, dst_b5_q};
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

  assign rx_dst_mac_o   = {dst_b0_q, dst_b1_q, dst_b2_q, dst_b3_q, dst_b4_q, dst_b5_q};
  assign rx_src_mac_o   = {src_b0_q, src_b1_q, src_b2_q, src_b3_q, src_b4_q, src_b5_q};
  assign rx_ethertype_o = {eth_b0_q, eth_b1_q};
  assign hdr_valid_o    = (state_q == ST_PAYLOAD);
  assign drop_o         = (state_q == ST_DROP);

endmodule

`endif // ETH_HEADER_PARSER_SV
