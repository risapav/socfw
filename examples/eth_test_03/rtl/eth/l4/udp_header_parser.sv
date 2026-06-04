/**
 * @file udp_header_parser.sv
 * @brief UDP header parser: validates dst_port, extracts fields, forwards UDP payload.
 * @details Consumes 8-byte UDP header, then forwards exactly payload_len = udp_len - 8
 *   bytes. Any trailing bytes (Ethernet padding, FCS) are consumed in ST_FLUSH without
 *   output. This design is robust whether or not gmii_rx_mac strips FCS.
 *
 * FSM states:
 *   ST_HEADER  — consume 8 UDP header bytes, s_axis_tready=1 always.
 *   ST_PAYLOAD — forward exactly payload_len bytes with downstream backpressure.
 *                m_axis_tlast is generated on the last UDP payload byte,
 *                NOT on s_axis_tlast (which may carry trailing padding/FCS).
 *   ST_FLUSH   — consume remaining bytes to s_axis_tlast (padding + FCS).
 *   ST_DROP    — consume entire frame to s_axis_tlast without output.
 *
 * Uses dedicated byte-capture registers (port_match_q, len_ok_q) to avoid Quartus
 * Lite synthesis bugs with wide shift registers / concatenation-vs-constant forms.
 *
 * UDP header byte layout:
 *   bytes 0-1: Source Port
 *   bytes 2-3: Destination Port
 *   bytes 4-5: UDP Length (header + payload)
 *   bytes 6-7: UDP Checksum
 *
 * @param DROP_NONZERO_CHECKSUM  Drop frames with non-zero UDP checksum (default 0).
 * @param local_port_i   16-bit local UDP port filter.
 * @param promiscuous_i  Accept all destination ports when 1.
 * @param payload_len_o  UDP payload length = udp_len - 8 (valid when hdr_valid_o=1).
 * @param udp_checksum_zero_o        UDP checksum field was 0x0000.
 * @param udp_checksum_unchecked_o   UDP checksum field was non-zero (not validated).
 * @param hdr_valid_o    Asserted in ST_PAYLOAD (frame accepted).
 * @param drop_o         Asserted in ST_DROP (frame rejected).
 */

`ifndef UDP_HEADER_PARSER_SV
`define UDP_HEADER_PARSER_SV

`default_nettype none

module udp_header_parser #(
  parameter bit DROP_NONZERO_CHECKSUM = 1'b0
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic [15:0] local_port_i,
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

  output      logic [15:0] src_port_o,
  output      logic [15:0] dst_port_o,
  output      logic [15:0] udp_len_o,
  output      logic [15:0] payload_len_o,
  output      logic        hdr_valid_o,
  // Fires on the last header byte cycle (byte_cnt==7), 1 cycle before hdr_valid_o.
  output      logic        hdr_pre_valid_o,
  output      logic [15:0] src_port_pre_o,
  output      logic [15:0] dst_port_pre_o,
  output      logic [15:0] payload_len_pre_o,
  output      logic        drop_o,
  output      logic        udp_checksum_zero_o,
  output      logic        udp_checksum_unchecked_o
);

  typedef enum logic [1:0] {
    ST_HEADER  = 2'd0,
    ST_PAYLOAD = 2'd1,
    ST_FLUSH   = 2'd2,
    ST_DROP    = 2'd3
  } state_e;

  state_e     state_q;
  logic [2:0] byte_cnt_q;
  logic [15:0] payload_len_q;
  logic [15:0] payload_cnt_q;

  // Dedicated byte-capture registers: one 8-bit register per UDP header byte.
  // Avoids Quartus Lite synthesis bugs with wide (64-bit) shift registers.
  logic [7:0] src_b0_q, src_b1_q;   // bytes 0-1: source port
  logic [7:0] dst_b0_q, dst_b1_q;   // bytes 2-3: destination port
  logic [7:0] len_b0_q, len_b1_q;   // bytes 4-5: UDP length
  logic [7:0] csum_b0_q, csum_b1_q; // bytes 6-7: checksum

  // Running match for port comparison (byte-by-byte, avoids 16-bit comparison issues)
  logic port_match_q;  // 1 iff dst_port bytes 2-3 match local_port_i
  // UDP length validity flag: registered at byte 5 when both length bytes are known
  logic len_ok_q;      // 1 iff udp_len >= 8

  // Drop decision at byte 7: all flags are pure FF values; no concat with live input.
  logic drop_decision_w;
  logic csum_nonzero_w;
  assign csum_nonzero_w = (csum_b0_q != 8'h00) || (s_axis_tdata != 8'h00);
  assign drop_decision_w =
    !len_ok_q ||
    (!promiscuous_i && !port_match_q) ||
    (DROP_NONZERO_CHECKSUM && csum_nonzero_w);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= ST_HEADER;
      byte_cnt_q    <= 3'd0;
      payload_len_q <= 16'd0;
      payload_cnt_q <= 16'd0;
      src_b0_q      <= 8'h00;
      src_b1_q      <= 8'h00;
      dst_b0_q      <= 8'h00;
      dst_b1_q      <= 8'h00;
      len_b0_q      <= 8'h00;
      len_b1_q      <= 8'h00;
      csum_b0_q     <= 8'h00;
      csum_b1_q     <= 8'h00;
      port_match_q  <= 1'b0;
      len_ok_q      <= 1'b0;
    end else if (s_axis_tvalid && s_axis_tready) begin
      case (state_q)
        ST_HEADER: begin
          if (byte_cnt_q == 3'd7) begin
            byte_cnt_q <= 3'd0;
            csum_b1_q  <= s_axis_tdata;
            if (drop_decision_w) begin
              state_q <= ST_DROP;
            end else begin
              payload_len_q <= {len_b0_q, len_b1_q} - 16'd8;
              payload_cnt_q <= 16'd0;
              // udp_len == 8 means zero payload: skip ST_PAYLOAD
              state_q <= ({len_b0_q, len_b1_q} == 16'd8) ? ST_FLUSH : ST_PAYLOAD;
            end
          end else if (s_axis_tlast) begin
            // Short frame < 8 bytes: reset silently
            byte_cnt_q <= 3'd0;
          end else begin
            byte_cnt_q <= byte_cnt_q + 3'd1;
            case (byte_cnt_q)
              3'd0: src_b0_q     <= s_axis_tdata;
              3'd1: src_b1_q     <= s_axis_tdata;
              3'd2: begin
                dst_b0_q    <= s_axis_tdata;
                port_match_q <= (s_axis_tdata == local_port_i[15:8]);
              end
              3'd3: begin
                dst_b1_q    <= s_axis_tdata;
                port_match_q <= port_match_q && (s_axis_tdata == local_port_i[7:0]);
              end
              3'd4: len_b0_q     <= s_axis_tdata;
              3'd5: begin
                len_b1_q  <= s_axis_tdata;
                // udp_len >= 8: high byte > 0, OR (high byte == 0 AND low byte >= 8)
                len_ok_q  <= (len_b0_q != 8'h00) || (s_axis_tdata >= 8'h08);
              end
              3'd6: csum_b0_q    <= s_axis_tdata;
              default: ;
            endcase
          end
        end
        ST_PAYLOAD: begin
          if (payload_cnt_q == payload_len_q - 16'd1) begin
            // Last payload byte forwarded
            payload_cnt_q <= 16'd0;
            state_q <= s_axis_tlast ? ST_HEADER : ST_FLUSH;
          end else if (s_axis_tlast) begin
            // Truncated frame: reset FSM
            state_q       <= ST_HEADER;
            payload_cnt_q <= 16'd0;
          end else begin
            payload_cnt_q <= payload_cnt_q + 16'd1;
          end
        end
        ST_FLUSH: begin
          if (s_axis_tlast) state_q <= ST_HEADER;
        end
        ST_DROP: begin
          if (s_axis_tlast) state_q <= ST_HEADER;
        end
        default: state_q <= ST_HEADER;
      endcase
    end
  end

  // ST_PAYLOAD: downstream backpressure. All other states: consume freely.
  assign s_axis_tready = (state_q == ST_PAYLOAD) ? m_axis_tready : 1'b1;

  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid && (state_q == ST_PAYLOAD);
  // m_axis_tlast on the last UDP payload byte — not tied to s_axis_tlast.
  assign m_axis_tlast  = m_axis_tvalid && (payload_cnt_q == payload_len_q - 16'd1);
  assign m_axis_tuser  = s_axis_tuser;

  // Outputs assembled from individual byte registers (no wide register slice).
  assign src_port_o    = {src_b0_q,  src_b1_q};
  assign dst_port_o    = {dst_b0_q,  dst_b1_q};
  assign udp_len_o     = {len_b0_q,  len_b1_q};
  assign payload_len_o = payload_len_q;
  assign hdr_valid_o   = (state_q == ST_PAYLOAD);

  // Pre outputs: valid at hdr_pre_valid_o=1 (byte_cnt==7, frame accepted, udp_len>=8).
  assign hdr_pre_valid_o   = (state_q == ST_HEADER) && s_axis_tvalid &&
                              (byte_cnt_q == 3'd7) && !drop_decision_w;
  assign src_port_pre_o    = {src_b0_q, src_b1_q};
  assign dst_port_pre_o    = {dst_b0_q, dst_b1_q};
  assign payload_len_pre_o = {len_b0_q, len_b1_q} - 16'd8;

  assign drop_o                = (state_q == ST_DROP);
  assign udp_checksum_zero_o      = (csum_b0_q == 8'h00) && (csum_b1_q == 8'h00);
  assign udp_checksum_unchecked_o = (csum_b0_q != 8'h00) || (csum_b1_q != 8'h00);

endmodule

`endif // UDP_HEADER_PARSER_SV
