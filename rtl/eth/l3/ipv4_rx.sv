/**
 * @file ipv4_rx.sv
 * @brief IPv4 header parser: strips 20-byte IP header (IHL=5), validates, forwards payload.
 * @param LOCAL_IP    32-bit FPGA IP.  Non-promiscuous drops frames with dst_ip != LOCAL_IP.
 * @param PROMISCUOUS If 1, accept all dst_ip values.
 * @details Receives IPv4 payload from eth_type_demux port 1 (after Ethernet header strip).
 *   Parses the 20-byte IPv4 header (IHL must be 5; options not supported — dropped).
 *   Forwards the payload stream to downstream protocol parsers (ICMP, UDP, etc.).
 *
 *   m_hdr_valid_o: registered 1-cycle pulse, fires in the FIRST cycle of ST_PAYLOAD.
 *   At that point all header fields (including dst_ip) are fully registered.
 *   IMPORTANT: m_hdr_valid_o may fire in the SAME cycle as the first m_axis_tvalid beat.
 *   Downstream parsers must use combinatorial routing on m_hdr_valid_i, not registered.
 *
 *   m_axis_tuser: set for the entire frame if the frame must be dropped (bad IHL, wrong
 *   dst_ip, fragmented, or upstream error).  Downstream parsers should discard on tuser=1.
 *
 *   Metadata (m_meta_valid_o): valid in the same cycle as m_axis_tlast for accepted frames.
 *
 *   IPv4 header byte map (20 bytes, IHL=5):
 *     [0]    version[7:4]=4, IHL[3:0]=5
 *     [1]    DSCP+ECN (ignored)
 *     [2:3]  total length (includes 20-byte header)
 *     [4:5]  identification (ignored)
 *     [6]    flags[2:0] + frag_off[12:8]  (DF=bit6, MF=bit5)
 *     [7]    frag_off[7:0]
 *     [8]    TTL
 *     [9]    protocol
 *     [10:11] header checksum (not verified)
 *     [12:15] source IP
 *     [16:19] destination IP
 */
`ifndef IPV4_RX_SV
`define IPV4_RX_SV

`default_nettype none

module ipv4_rx #(
  parameter logic [31:0] LOCAL_IP    = 32'hC0A80002,
  parameter bit          PROMISCUOUS = 1'b0
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // ---- Input stream from eth_type_demux port 1 ----
  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  input  wire logic        s_axis_tlast,
  input  wire logic        s_axis_tuser,

  // ---- Early protocol notification (registered 1-cycle pulse) ----
  output      logic        m_hdr_valid_o,   // fires at first cycle of ST_PAYLOAD
  output      logic [7:0]  m_hdr_proto_o,   // stable from m_hdr_valid_o through m_axis_tlast
  output      logic [31:0] m_hdr_src_ip_o,
  output      logic [31:0] m_hdr_dst_ip_o,
  output      logic        m_hdr_accept_o,  // 0 = bad IHL / wrong IP / fragment

  // ---- Payload AXI-Stream (no backpressure) ----
  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  output      logic        m_axis_tlast,
  output      logic        m_axis_tuser,   // 1 = frame must be dropped

  // ---- Metadata at tlast (only for accepted frames) ----
  output      logic        m_meta_valid_o,
  input  wire logic        m_meta_ready_i,
  output      logic [31:0] m_meta_src_ip_o,
  output      logic [31:0] m_meta_dst_ip_o,
  output      logic [7:0]  m_meta_proto_o,
  output      logic [15:0] m_meta_payload_len_o,

  // ---- Diagnostics ----
  output      logic [15:0] stat_rx_frames,
  output      logic [15:0] stat_rx_dropped
);

  typedef enum logic [1:0] {
    ST_IDLE    = 2'd0,
    ST_HEADER  = 2'd1,
    ST_PAYLOAD = 2'd2
  } state_e;

  state_e     state_q;
  logic [4:0] hdr_cnt_q;  // 0..19 in ST_HEADER

  // Captured header fields
  logic [3:0]  ihl_q;
  logic [15:0] total_len_q;
  logic [1:0]  flags_q;    // [1]=DF, [0]=MF
  logic [12:0] frag_off_q;
  logic [7:0]  proto_q;
  logic [31:0] src_ip_q;
  logic [31:0] dst_ip_q;

  // Per-frame drop flag (set if version!=4, IHL!=5, fragmented, wrong dst, tuser)
  logic        drop_q;

  // Registered early-header valid pulse
  logic        hdr_valid_q;

  // Metadata output registers
  logic        meta_valid_q;
  logic [31:0] meta_src_q;
  logic [31:0] meta_dst_q;
  logic [7:0]  meta_proto_q;
  logic [15:0] meta_plen_q;

  // Statistics
  logic [15:0] cnt_rx_q;
  logic [15:0] cnt_drop_q;

  // -------------------------------------------------------------------------
  // Combinatorial accept check — valid from first ST_PAYLOAD cycle onwards
  // (all fields registered by then).
  // -------------------------------------------------------------------------
  logic frag_w;
  logic ip_accept_w;
  assign frag_w      = flags_q[0] || (frag_off_q != 13'd0);  // MF || frag_off!=0
  assign ip_accept_w = (ihl_q == 4'd5) &&
                       !frag_w &&
                       (PROMISCUOUS || (dst_ip_q == LOCAL_IP));

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_IDLE;
      hdr_cnt_q    <= 5'd0;
      ihl_q        <= 4'd0;
      total_len_q  <= '0;
      flags_q      <= 2'b00;
      frag_off_q   <= 13'd0;
      proto_q      <= 8'h00;
      src_ip_q     <= '0;
      dst_ip_q     <= '0;
      drop_q       <= 1'b0;
      hdr_valid_q  <= 1'b0;
      meta_valid_q <= 1'b0;
      meta_src_q   <= '0;
      meta_dst_q   <= '0;
      meta_proto_q <= 8'h00;
      meta_plen_q  <= '0;
      cnt_rx_q     <= '0;
      cnt_drop_q   <= '0;
    end else begin
      // Default: clear the one-cycle pulse
      hdr_valid_q <= 1'b0;

      if (meta_valid_q && m_meta_ready_i)
        meta_valid_q <= 1'b0;

      case (state_q)

        // -------------------------------------------------------------------
        ST_IDLE: begin
          if (s_axis_tvalid) begin
            if (s_axis_tlast) begin
              cnt_drop_q <= cnt_drop_q + 16'd1;
            end else begin
              // Byte 0: version[7:4] + IHL[3:0]
              ihl_q     <= s_axis_tdata[3:0];
              drop_q    <= (s_axis_tdata[7:4] != 4'd4);
              hdr_cnt_q <= 5'd1;
              state_q   <= ST_HEADER;
            end
          end
        end

        // -------------------------------------------------------------------
        ST_HEADER: begin
          if (s_axis_tvalid) begin
            hdr_cnt_q <= hdr_cnt_q + 5'd1;
            if (s_axis_tuser) drop_q <= 1'b1;

            case (hdr_cnt_q)
              5'd2:  total_len_q[15:8]  <= s_axis_tdata;
              5'd3:  total_len_q[7:0]   <= s_axis_tdata;
              // [4:5] identification — skip
              5'd6:  begin
                // byte 6: reserved(7) | DF(6) | MF(5) | frag_off[12:8](4:0)
                flags_q[1]  <= s_axis_tdata[6];  // DF
                flags_q[0]  <= s_axis_tdata[5];  // MF
                frag_off_q[12:8] <= s_axis_tdata[4:0];
              end
              5'd7:  frag_off_q[7:0]  <= s_axis_tdata;
              5'd8:  ;  // TTL — not captured (not needed for echo)
              5'd9:  proto_q          <= s_axis_tdata;
              // [10:11] checksum — skip
              5'd12: src_ip_q[31:24]  <= s_axis_tdata;
              5'd13: src_ip_q[23:16]  <= s_axis_tdata;
              5'd14: src_ip_q[15:8]   <= s_axis_tdata;
              5'd15: src_ip_q[7:0]    <= s_axis_tdata;
              5'd16: dst_ip_q[31:24]  <= s_axis_tdata;
              5'd17: dst_ip_q[23:16]  <= s_axis_tdata;
              5'd18: dst_ip_q[15:8]   <= s_axis_tdata;
              5'd19: dst_ip_q[7:0]    <= s_axis_tdata;  // last header byte
              default: ;
            endcase

            if (hdr_cnt_q == 5'd19) begin
              // Transition to payload; dst_ip_q[7:0] is being registered now.
              // hdr_valid_q fires NEXT cycle (first ST_PAYLOAD cycle) when dst_ip_q is valid.
              hdr_valid_q <= 1'b1;
              state_q     <= ST_PAYLOAD;
              hdr_cnt_q   <= 5'd0;
            end else if (s_axis_tlast) begin
              cnt_drop_q <= cnt_drop_q + 16'd1;
              hdr_cnt_q  <= 5'd0;
              state_q    <= ST_IDLE;
            end
          end
        end

        // -------------------------------------------------------------------
        ST_PAYLOAD: begin
          if (s_axis_tvalid && s_axis_tlast) begin
            cnt_rx_q <= cnt_rx_q + 16'd1;
            if (!drop_q && ip_accept_w && !s_axis_tuser) begin
              if (!meta_valid_q || m_meta_ready_i) begin
                meta_valid_q <= 1'b1;
                meta_src_q   <= src_ip_q;
                meta_dst_q   <= dst_ip_q;
                meta_proto_q <= proto_q;
                meta_plen_q  <= total_len_q - 16'd20;
              end
            end else begin
              cnt_drop_q <= cnt_drop_q + 16'd1;
            end
            state_q <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Payload forwarding (combinatorial pass-through, tagged with accept status)
  // -------------------------------------------------------------------------
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid && (state_q == ST_PAYLOAD);
  assign m_axis_tlast  = s_axis_tlast;
  assign m_axis_tuser  = s_axis_tuser || drop_q || !ip_accept_w;

  // -------------------------------------------------------------------------
  // Early header outputs (valid while hdr_valid_q=1 and throughout ST_PAYLOAD)
  // -------------------------------------------------------------------------
  assign m_hdr_valid_o  = hdr_valid_q;
  assign m_hdr_proto_o  = proto_q;
  assign m_hdr_src_ip_o = src_ip_q;
  assign m_hdr_dst_ip_o = dst_ip_q;
  assign m_hdr_accept_o = ip_accept_w && !drop_q;

  assign m_meta_valid_o       = meta_valid_q;
  assign m_meta_src_ip_o      = meta_src_q;
  assign m_meta_dst_ip_o      = meta_dst_q;
  assign m_meta_proto_o       = meta_proto_q;
  assign m_meta_payload_len_o = meta_plen_q;

  assign stat_rx_frames  = cnt_rx_q;
  assign stat_rx_dropped = cnt_drop_q;

endmodule

`endif // IPV4_RX_SV
