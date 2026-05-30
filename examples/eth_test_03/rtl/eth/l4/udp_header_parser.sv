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
 * Drop conditions (evaluated on last header byte via header_next_w):
 *   - udp_len < 8 (invalid)
 *   - dst_port != local_port_i and !promiscuous_i
 *   - DROP_NONZERO_CHECKSUM=1 and udp_checksum != 0x0000
 *
 * UDP header byte layout (MSB-first shift register):
 *   header_reg_q[63:48] bytes 0-1: Source Port
 *   header_reg_q[47:32] bytes 2-3: Destination Port
 *   header_reg_q[31:16] bytes 4-5: UDP Length (header + payload)
 *   header_reg_q[15:0]  bytes 6-7: UDP Checksum
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
  // The _pre outputs below use header_next_w and are valid at hdr_pre_valid_o=1.
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

  state_e       state_q;
  logic [2:0]   byte_cnt_q;
  logic [63:0]  header_reg_q;
  logic [15:0]  payload_len_q;
  logic [15:0]  payload_cnt_q;

  // Combinatorial next-state of header_reg: avoids stale validation at byte 7.
  logic [63:0] header_next_w;
  assign header_next_w = {header_reg_q[55:0], s_axis_tdata};

  // Drop when: udp_len < 8, port mismatch, or nonzero checksum with parameter set.
  logic drop_decision_w;
  assign drop_decision_w =
    (header_next_w[31:16] < 16'd8) ||
    (!promiscuous_i && (header_next_w[47:32] != local_port_i)) ||
    (DROP_NONZERO_CHECKSUM && (header_next_w[15:0] != 16'h0000));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= ST_HEADER;
      byte_cnt_q    <= 3'd0;
      header_reg_q  <= '0;
      payload_len_q <= 16'd0;
      payload_cnt_q <= 16'd0;
    end else if (s_axis_tvalid && s_axis_tready) begin
      case (state_q)
        ST_HEADER: begin
          header_reg_q <= header_next_w;
          if (byte_cnt_q == 3'd7) begin
            byte_cnt_q <= 3'd0;
            if (drop_decision_w) begin
              state_q <= ST_DROP;
            end else begin
              payload_len_q <= header_next_w[31:16] - 16'd8;
              payload_cnt_q <= 16'd0;
              // udp_len == 8 means zero payload: skip ST_PAYLOAD
              state_q <= (header_next_w[31:16] == 16'd8) ? ST_FLUSH : ST_PAYLOAD;
            end
          end else if (s_axis_tlast) begin
            // Short frame < 8 bytes: reset silently
            byte_cnt_q   <= 3'd0;
            header_reg_q <= '0;
          end else begin
            byte_cnt_q <= byte_cnt_q + 3'd1;
          end
        end
        ST_PAYLOAD: begin
          if (payload_cnt_q == payload_len_q - 16'd1) begin
            // Last payload byte forwarded
            payload_cnt_q <= 16'd0;
            header_reg_q  <= '0;
            state_q <= s_axis_tlast ? ST_HEADER : ST_FLUSH;
          end else if (s_axis_tlast) begin
            // Truncated frame: reset FSM
            state_q       <= ST_HEADER;
            payload_cnt_q <= 16'd0;
            header_reg_q  <= '0;
          end else begin
            payload_cnt_q <= payload_cnt_q + 16'd1;
          end
        end
        ST_FLUSH: begin
          if (s_axis_tlast) begin
            state_q      <= ST_HEADER;
            header_reg_q <= '0;
          end
        end
        ST_DROP: begin
          if (s_axis_tlast) begin
            state_q      <= ST_HEADER;
            header_reg_q <= '0;
          end
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

  // Field outputs valid when hdr_valid_o = 1 (state == ST_PAYLOAD).
  assign src_port_o   = header_reg_q[63:48];
  assign dst_port_o   = header_reg_q[47:32];
  assign udp_len_o    = header_reg_q[31:16];
  assign payload_len_o = payload_len_q;
  assign hdr_valid_o  = (state_q == ST_PAYLOAD);
  assign hdr_pre_valid_o  = (state_q == ST_HEADER) && s_axis_tvalid &&
                             (byte_cnt_q == 3'd7) && !drop_decision_w &&
                             (header_next_w[31:16] >= 16'd8);
  // header_next_w holds all 8 header bytes when hdr_pre_valid_o=1 (byte_cnt==7).
  assign src_port_pre_o   = header_next_w[63:48];
  assign dst_port_pre_o   = header_next_w[47:32];
  assign payload_len_pre_o = header_next_w[31:16] - 16'd8;
  assign drop_o       = (state_q == ST_DROP);

  assign udp_checksum_zero_o      = (header_reg_q[15:0] == 16'h0000);
  assign udp_checksum_unchecked_o = (header_reg_q[15:0] != 16'h0000);

endmodule

`endif // UDP_HEADER_PARSER_SV
