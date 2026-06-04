/**
 * @file ipv4_header_parser.sv
 * @brief IPv4 header parser: validates version/IHL, protocol (UDP=0x11), dst_ip.
 * @details Consumes 20-byte IPv4 header from AXI-Stream, then forwards payload.
 *   - ST_HEADER: consumes header bytes, no backpressure (s_axis_tready=1).
 *   - ST_PAYLOAD: forwards payload bytes with downstream backpressure.
 *   - ST_DROP: silently consumes remaining bytes (bad version, wrong IP, non-UDP).
 *   Uses dedicated byte-capture registers (ver_ok_q, proto_ok_q, ip_match_q) and
 *   individual 8-bit registers for src/dst IP fields. Avoids any wide register
 *   partial-slice or concatenation-vs-constant patterns that Quartus Lite
 *   misoptimises.
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
 */

`ifndef IPV4_HEADER_PARSER_SV
`define IPV4_HEADER_PARSER_SV

`default_nettype none

module ipv4_header_parser (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,
  input  wire logic [31:0] local_ip_i,
  input  wire logic        promiscuous_i,

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

  state_e     state_q;
  logic [4:0] byte_cnt_q;

  // Dedicated byte-capture registers for fields needed in drop decision and outputs.
  // Using separate 8-bit registers avoids Quartus Lite synthesis bugs with wide
  // registers (partial-slice or concat-vs-constant comparison forms).
  logic       ver_ok_q;    // version/IHL == 0x45, registered at byte 0
  logic       proto_ok_q;  // protocol   == 0x11, registered at byte 9
  logic       ip_match_q;  // running: dst_ip bytes 16-18 match local_ip_i[31:8]

  // Source IP bytes (12-15), captured independently
  logic [7:0] src_b0_q, src_b1_q, src_b2_q, src_b3_q;
  // Destination IP bytes (16-19), captured independently
  logic [7:0] dst_b0_q, dst_b1_q, dst_b2_q, dst_b3_q;
  // Protocol byte (9)
  logic [7:0] proto_byte_q;

  // Drop decision at byte 19: all flags are pure FF values; last byte from s_axis_tdata.
  logic drop_decision_w;
  assign drop_decision_w = !promiscuous_i && (
      !ver_ok_q                           ||  // version/IHL must be 0x45
      !proto_ok_q                         ||  // protocol must be UDP (0x11)
      !ip_match_q                         ||  // dst_ip bytes 16-18 match
      (s_axis_tdata != local_ip_i[7:0]));     // dst_ip byte 19

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_HEADER;
      byte_cnt_q   <= 5'd0;
      ver_ok_q     <= 1'b0;
      proto_ok_q   <= 1'b0;
      ip_match_q   <= 1'b0;
      src_b0_q     <= 8'h00;
      src_b1_q     <= 8'h00;
      src_b2_q     <= 8'h00;
      src_b3_q     <= 8'h00;
      dst_b0_q     <= 8'h00;
      dst_b1_q     <= 8'h00;
      dst_b2_q     <= 8'h00;
      dst_b3_q     <= 8'h00;
      proto_byte_q <= 8'h00;
    end else if (s_axis_tvalid && s_axis_tready) begin
      case (state_q)
        ST_HEADER: begin
          if (byte_cnt_q == 5'd19) begin
            // Last header byte: capture dst_ip[7:0] and decide
            byte_cnt_q <= 5'd0;
            dst_b3_q   <= s_axis_tdata;
            state_q    <= drop_decision_w ? ST_DROP : ST_PAYLOAD;
          end else if (s_axis_tlast) begin
            // Short frame: reset silently
            byte_cnt_q <= 5'd0;
          end else begin
            byte_cnt_q <= byte_cnt_q + 5'd1;
            case (byte_cnt_q)
              5'd0:  ver_ok_q   <= (s_axis_tdata == 8'h45);
              5'd9:  begin
                proto_ok_q  <= (s_axis_tdata == 8'h11);
                proto_byte_q <= s_axis_tdata;
              end
              5'd12: src_b0_q  <= s_axis_tdata;
              5'd13: src_b1_q  <= s_axis_tdata;
              5'd14: src_b2_q  <= s_axis_tdata;
              5'd15: src_b3_q  <= s_axis_tdata;
              5'd16: begin
                dst_b0_q   <= s_axis_tdata;
                ip_match_q <= (s_axis_tdata == local_ip_i[31:24]);
              end
              5'd17: begin
                dst_b1_q   <= s_axis_tdata;
                ip_match_q <= ip_match_q && (s_axis_tdata == local_ip_i[23:16]);
              end
              5'd18: begin
                dst_b2_q   <= s_axis_tdata;
                ip_match_q <= ip_match_q && (s_axis_tdata == local_ip_i[15:8]);
              end
              default: ;
            endcase
          end
        end
        ST_PAYLOAD: begin
          if (s_axis_tlast) begin
            state_q    <= ST_HEADER;
            byte_cnt_q <= 5'd0;
          end
        end
        ST_DROP: begin
          if (s_axis_tlast) begin
            state_q    <= ST_HEADER;
            byte_cnt_q <= 5'd0;
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

  // Outputs assembled from individual byte registers (no partial-slice concat).
  assign src_ip_o   = {src_b0_q, src_b1_q, src_b2_q, src_b3_q};
  assign dst_ip_o   = {dst_b0_q, dst_b1_q, dst_b2_q, dst_b3_q};
  assign protocol_o = proto_byte_q;
  assign hdr_valid_o = (state_q == ST_PAYLOAD);

endmodule

`endif // IPV4_HEADER_PARSER_SV
