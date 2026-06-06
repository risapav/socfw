/**
 * @file arp_rx.sv
 * @brief ARP request parser: validates incoming ARP frames and extracts reply parameters.
 * @param LOCAL_IP  32-bit FPGA IP address.  Only ARP requests targeting this IP are accepted.
 * @details Receives the 28-byte ARP payload (after Ethernet header strip) from eth_type_demux.
 *   Validates: htype=0x0001, ptype=0x0800, hlen=6, plen=4, oper=0x0001, tpa==LOCAL_IP.
 *   tuser=1 at tlast (bad FCS) causes the frame to be discarded.
 *   Ethernet minimum-frame padding bytes (after byte 27) are drained silently.
 *
 *   Timing note: validation result is latched at byte 27 using s_axis_tdata combinatorially
 *   for tpa[7:0] (not yet registered), avoiding a 1-cycle pipeline hole.
 *   If tlast arrives at byte 27 (frame with no padding) the output is emitted immediately.
 *
 *   ARP byte map (IPv4/Ethernet, 28 bytes):
 *     [0:1]  htype=0x0001  [2:3]  ptype=0x0800  [4] hlen=6  [5] plen=4
 *     [6:7]  oper=0x0001   [8:13] sha (sender MAC)  [14:17] spa (sender IP)
 *     [18:23] tha (ignored) [24:27] tpa (target IP == LOCAL_IP)
 */
`ifndef ARP_RX_SV
`define ARP_RX_SV

`default_nettype none

module arp_rx #(
  parameter logic [31:0] LOCAL_IP = 32'hC0A80002
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  input  wire logic        s_axis_tlast,
  input  wire logic        s_axis_tuser,

  output      logic        m_valid_o,
  input  wire logic        m_ready_i,
  output      logic [47:0] m_requester_mac_o,
  output      logic [31:0] m_requester_ip_o,

  output      logic [15:0] stat_rx_requests,
  output      logic [15:0] stat_rx_dropped
);

  typedef enum logic [1:0] {
    ST_IDLE  = 2'd0,
    ST_PARSE = 2'd1,
    ST_DRAIN = 2'd2
  } state_e;

  state_e     state_q;
  logic [4:0] byte_cnt_q;

  logic [15:0] htype_q;
  logic [15:0] ptype_q;
  logic [7:0]  hlen_q;
  logic [7:0]  plen_q;
  logic [15:0] oper_q;
  logic [47:0] sha_q;
  logic [31:0] spa_q;
  logic [31:0] tpa_q;
  logic        arp_valid_q;

  logic        meta_valid_q;
  logic [47:0] meta_mac_q;
  logic [31:0] meta_ip_q;

  logic [15:0] cnt_req_q;
  logic [15:0] cnt_drop_q;

  // Combinatorial validation at byte 27: uses s_axis_tdata for tpa[7:0] (not yet registered).
  // Only meaningful when byte_cnt_q==27 and s_axis_tvalid==1.
  logic arp_ok_now_w;
  always_comb begin
    arp_ok_now_w = (htype_q == 16'h0001) &&
                   (ptype_q == 16'h0800) &&
                   (hlen_q  ==  8'h06)   &&
                   (plen_q  ==  8'h04)   &&
                   (oper_q  == 16'h0001) &&
                   (tpa_q[31:8] == LOCAL_IP[31:8]) &&
                   (s_axis_tdata == LOCAL_IP[7:0]);
  end

  // Emit output metadata (shared between ST_PARSE tlast-at-27 and ST_DRAIN tlast paths)
  // Task-like inline macro: use an internal helper signal instead.
  // emit_meta_w: combinatorial condition to latch metadata
  logic emit_meta_w;
  always_comb begin
    emit_meta_w = 1'b0;
    if (state_q == ST_PARSE && s_axis_tvalid && s_axis_tlast && byte_cnt_q == 5'd27)
      emit_meta_w = arp_ok_now_w && !s_axis_tuser;
    else if (state_q == ST_DRAIN && s_axis_tvalid && s_axis_tlast)
      emit_meta_w = arp_valid_q && !s_axis_tuser;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_IDLE;
      byte_cnt_q   <= 5'd0;
      htype_q      <= '0; ptype_q <= '0; hlen_q  <= 8'h00; plen_q <= 8'h00;
      oper_q       <= '0; sha_q   <= '0; spa_q   <= '0;    tpa_q  <= '0;
      arp_valid_q  <= 1'b0;
      meta_valid_q <= 1'b0;
      meta_mac_q   <= '0;
      meta_ip_q    <= '0;
      cnt_req_q    <= '0;
      cnt_drop_q   <= '0;
    end else begin
      if (meta_valid_q && m_ready_i)
        meta_valid_q <= 1'b0;

      if (emit_meta_w) begin
        if (!meta_valid_q || m_ready_i) begin
          meta_valid_q <= 1'b1;
          meta_mac_q   <= sha_q;
          meta_ip_q    <= spa_q;
        end
        cnt_req_q <= cnt_req_q + 16'd1;
      end

      case (state_q)

        ST_IDLE: begin
          if (s_axis_tvalid) begin
            if (s_axis_tlast) begin
              cnt_drop_q <= cnt_drop_q + 16'd1;
            end else begin
              htype_q[15:8] <= s_axis_tdata;
              byte_cnt_q    <= 5'd1;
              arp_valid_q   <= 1'b0;
              state_q       <= ST_PARSE;
            end
          end
        end

        ST_PARSE: begin
          if (s_axis_tvalid) begin
            byte_cnt_q <= byte_cnt_q + 5'd1;

            case (byte_cnt_q)
              5'd1:  htype_q[7:0]  <= s_axis_tdata;
              5'd2:  ptype_q[15:8] <= s_axis_tdata;
              5'd3:  ptype_q[7:0]  <= s_axis_tdata;
              5'd4:  hlen_q        <= s_axis_tdata;
              5'd5:  plen_q        <= s_axis_tdata;
              5'd6:  oper_q[15:8]  <= s_axis_tdata;
              5'd7:  oper_q[7:0]   <= s_axis_tdata;
              5'd8:  sha_q[47:40]  <= s_axis_tdata;
              5'd9:  sha_q[39:32]  <= s_axis_tdata;
              5'd10: sha_q[31:24]  <= s_axis_tdata;
              5'd11: sha_q[23:16]  <= s_axis_tdata;
              5'd12: sha_q[15:8]   <= s_axis_tdata;
              5'd13: sha_q[7:0]    <= s_axis_tdata;
              5'd14: spa_q[31:24]  <= s_axis_tdata;
              5'd15: spa_q[23:16]  <= s_axis_tdata;
              5'd16: spa_q[15:8]   <= s_axis_tdata;
              5'd17: spa_q[7:0]    <= s_axis_tdata;
              // bytes 18-23: tha — ignored
              5'd24: tpa_q[31:24]  <= s_axis_tdata;
              5'd25: tpa_q[23:16]  <= s_axis_tdata;
              5'd26: tpa_q[15:8]   <= s_axis_tdata;
              5'd27: tpa_q[7:0]    <= s_axis_tdata;
              default: ;
            endcase

            if (byte_cnt_q == 5'd27) begin
              // Latch validation: arp_ok_now_w uses s_axis_tdata for tpa[7:0]
              arp_valid_q <= arp_ok_now_w;
              if (s_axis_tlast) begin
                // emit_meta_w handles output; go back to IDLE
                if (!arp_ok_now_w || s_axis_tuser)
                  cnt_drop_q <= cnt_drop_q + 16'd1;
                byte_cnt_q <= 5'd0;
                state_q    <= ST_IDLE;
              end else begin
                state_q <= ST_DRAIN;
              end
            end else if (s_axis_tlast) begin
              // Truncated frame
              cnt_drop_q <= cnt_drop_q + 16'd1;
              byte_cnt_q <= 5'd0;
              state_q    <= ST_IDLE;
            end
          end
        end

        ST_DRAIN: begin
          if (s_axis_tvalid && s_axis_tlast) begin
            // emit_meta_w handles output
            if (!arp_valid_q || s_axis_tuser)
              cnt_drop_q <= cnt_drop_q + 16'd1;
            byte_cnt_q <= 5'd0;
            state_q    <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  assign m_valid_o          = meta_valid_q;
  assign m_requester_mac_o  = meta_mac_q;
  assign m_requester_ip_o   = meta_ip_q;
  assign stat_rx_requests   = cnt_req_q;
  assign stat_rx_dropped    = cnt_drop_q;

endmodule

`endif // ARP_RX_SV
