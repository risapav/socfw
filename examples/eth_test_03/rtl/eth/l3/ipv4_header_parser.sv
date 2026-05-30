/**
 * @file ipv4_header_parser.sv
 * @brief IPv4 header parser: validates version/IHL, protocol (UDP=0x11), dst_ip.
 * @details Consumes 20-byte IPv4 header from AXI-Stream, then forwards payload.
 *   - ST_HEADER: consumes header bytes, no backpressure (s_axis_tready=1).
 *   - ST_PAYLOAD: forwards payload bytes with downstream backpressure.
 *   - ST_DROP: silently consumes remaining bytes (bad version, wrong IP, non-UDP).
 *   Validation uses header_next_w (combinatorial next-state of header_reg) to avoid
 *   stale-data bug when checking the 20th byte in the same always_ff block.
 *
 * @param local_ip_i  32-bit local IP address (network byte order: byte[0] in MSB).
 *
 * Ports:
 *   clk_i, rst_ni        — clock / active-low async reset
 *   local_ip_i[31:0]     — destination IP filter
 *   s_axis_*             — upstream AXI-Stream input (from eth_header_parser)
 *   m_axis_*             — downstream AXI-Stream output (IPv4 payload only)
 *   src_ip_o[31:0]       — parsed source IP (valid when hdr_valid_o=1)
 *   dst_ip_o[31:0]       — parsed destination IP (valid when hdr_valid_o=1)
 *   protocol_o[7:0]      — parsed protocol field (valid when hdr_valid_o=1)
 *   hdr_valid_o          — asserted in ST_PAYLOAD (frame accepted)
 *
 * IPv4 header field offsets (after 20 bytes shifted into header_reg MSB-first):
 *   [159:152] byte 0  Version+IHL (must be 0x45)
 *   [95:88]   byte 8  TTL
 *   [87:80]   byte 9  Protocol (0x11 = UDP)
 *   [63:32]   bytes 12-15  Source IP
 *   [31:0]    bytes 16-19  Destination IP
 */

`ifndef IPV4_HEADER_PARSER_SV
`define IPV4_HEADER_PARSER_SV

`default_nettype none

module ipv4_header_parser (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,
  input  wire logic [31:0] local_ip_i,

  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  output      logic        s_axis_tready,
  input  wire logic        s_axis_tlast,

  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  input  wire logic        m_axis_tready,
  output      logic        m_axis_tlast,

  output      logic [31:0] src_ip_o,
  output      logic [31:0] dst_ip_o,
  output      logic [7:0]  protocol_o,
  output      logic        hdr_valid_o
);

  typedef enum logic [1:0] {
    ST_HEADER  = 2'd0,
    ST_PAYLOAD = 2'd1,
    ST_DROP    = 2'd2
  } state_e;

  state_e       state_q;
  logic [4:0]   byte_cnt_q;
  logic [159:0] header_reg_q;

  // Combinatorial next-state of header_reg: avoids stale validation at byte 19.
  // Both header_reg_q NBA and drop_decision_w evaluate together at byte 19,
  // so the check must use the post-shift value.
  logic [159:0] header_next_w;
  assign header_next_w = {header_reg_q[151:0], s_axis_tdata};

  // Drop when: version/IHL != 0x45, protocol != UDP, or dst_ip mismatch.
  logic drop_decision_w;
  assign drop_decision_w = (header_next_w[159:152] != 8'h45)  ||
                           (header_next_w[87:80]   != 8'h11)  ||
                           (header_next_w[31:0]    != local_ip_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_HEADER;
      byte_cnt_q   <= 5'd0;
      header_reg_q <= '0;
    end else if (s_axis_tvalid && s_axis_tready) begin
      case (state_q)
        ST_HEADER: begin
          header_reg_q <= header_next_w;
          if (byte_cnt_q == 5'd19) begin
            byte_cnt_q <= 5'd0;
            state_q    <= drop_decision_w ? ST_DROP : ST_PAYLOAD;
          end else if (s_axis_tlast) begin
            // Short frame: reset silently
            byte_cnt_q   <= 5'd0;
            header_reg_q <= '0;
          end else begin
            byte_cnt_q <= byte_cnt_q + 5'd1;
          end
        end
        ST_PAYLOAD: begin
          if (s_axis_tlast) begin
            state_q      <= ST_HEADER;
            byte_cnt_q   <= 5'd0;
            header_reg_q <= '0;
          end
        end
        ST_DROP: begin
          if (s_axis_tlast) begin
            state_q      <= ST_HEADER;
            byte_cnt_q   <= 5'd0;
            header_reg_q <= '0;
          end
        end
        default: begin
          state_q    <= ST_HEADER;
          byte_cnt_q <= 5'd0;
        end
      endcase
    end
  end

  // ST_PAYLOAD: backpressure from downstream. ST_HEADER / ST_DROP: consume freely.
  assign s_axis_tready = (state_q == ST_PAYLOAD) ? m_axis_tready : 1'b1;

  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid && (state_q == ST_PAYLOAD);
  assign m_axis_tlast  = s_axis_tlast;

  // Field offsets valid in ST_PAYLOAD (header_reg_q holds full 20-byte header).
  assign src_ip_o   = header_reg_q[63:32];
  assign dst_ip_o   = header_reg_q[31:0];
  assign protocol_o = header_reg_q[87:80];
  assign hdr_valid_o = (state_q == ST_PAYLOAD);

endmodule

`endif // IPV4_HEADER_PARSER_SV
