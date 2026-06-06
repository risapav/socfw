/**
 * @file ipv4_tx.sv
 * @brief IPv4 TX builder: prepends 20-byte IPv4 header (IHL=5, TTL=64, DF=1) to protocol payload.
 * @param LOCAL_IP   32-bit FPGA source IP address.
 * @param LOCAL_MAC  48-bit FPGA source MAC (forwarded to eth_tx_mac meta as src_mac).
 * @details Checksum computed over 4 pipelined single-addition states (CSUM0..3) to keep
 *   each adder at exactly 2 operands, meeting 125 MHz timing in Quartus Lite.
 *   CSUM_SEED folds the constant header words (0x4500, 0x4000, LOCAL_IP) so only variable
 *   words (total_len, TTL/proto, dst_ip) are added at run time.
 *
 *   FSM: ST_IDLE -> ST_CSUM0..3 -> ST_FOLD -> ST_TX_META -> ST_TX_HDR (20B) -> ST_TX_PAY.
 *   Latency from meta accept to first output byte: 7 cycles.
 *
 *   Payload backpressure: m_axis_tready_i propagates back via s_axis_tready_o.
 *   Meta output: m_meta_eth_type_o=0x0800, m_meta_src_mac_o=LOCAL_MAC.
 *
 *   IPv4 header checksum words:
 *     SEED = 0x4500 + 0x0000(id) + 0x4000(DF) + LOCAL_IP[31:16] + LOCAL_IP[15:0]
 *     CSUM0 += total_len          CSUM1 += {TTL=0x40, proto}
 *     CSUM2 += dst_ip[31:16]      CSUM3 += dst_ip[15:0]
 */
`ifndef IPV4_TX_SV
`define IPV4_TX_SV

`default_nettype none

module ipv4_tx #(
  parameter logic [31:0] LOCAL_IP  = 32'hC0A80002,
  parameter logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // ---- Metadata from protocol handler ----
  input  wire logic        s_meta_valid_i,
  output      logic        s_meta_ready_o,
  input  wire logic [7:0]  s_meta_proto_i,
  input  wire logic [31:0] s_meta_dst_ip_i,
  input  wire logic [47:0] s_meta_dst_mac_i,
  input  wire logic [15:0] s_meta_payload_len_i,  // IP payload bytes (excl. 20B header)

  // ---- Payload stream from protocol handler ----
  input  wire logic [7:0]  s_axis_tdata_i,
  input  wire logic        s_axis_tvalid_i,
  output      logic        s_axis_tready_o,
  input  wire logic        s_axis_tlast_i,
  input  wire logic        s_axis_tuser_i,

  // ---- To eth_tx_mac (via arbiter) ----
  output      logic        m_meta_valid_o,
  input  wire logic        m_meta_ready_i,
  output      logic [47:0] m_meta_dst_mac_o,
  output      logic [47:0] m_meta_src_mac_o,
  output      logic [15:0] m_meta_eth_type_o,

  output      logic [7:0]  m_axis_tdata_o,
  output      logic        m_axis_tvalid_o,
  input  wire logic        m_axis_tready_i,
  output      logic        m_axis_tlast_o,
  output      logic        m_axis_tuser_o
);

  // -------------------------------------------------------------------------
  // Constant checksum seed: fixed header words known at compile time.
  // SEED = 0x4500 + 0x4000(DF, id=0 contributes 0) + LOCAL_IP_HALF_SUM
  // (identification=0 and checksum=0 contribute 0)
  // -------------------------------------------------------------------------
  localparam logic [31:0] CSUM_SEED =
    32'h0000_4500 + 32'h0000_4000
    + {16'd0, LOCAL_IP[31:16]} + {16'd0, LOCAL_IP[15:0]};

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_IDLE     = 4'd0,
    ST_CSUM0    = 4'd1,
    ST_CSUM1    = 4'd2,
    ST_CSUM2    = 4'd3,
    ST_CSUM3    = 4'd4,
    ST_FOLD     = 4'd5,
    ST_TX_META  = 4'd6,
    ST_TX_HDR   = 4'd7,
    ST_TX_PAY   = 4'd8
  } state_e;

  state_e      state_q;
  logic [4:0]  hdr_cnt_q;   // 0..19 for IPv4 header bytes

  // Registered metadata
  logic [7:0]  proto_q;
  logic [31:0] dst_ip_q;
  logic [47:0] dst_mac_q;
  logic [15:0] total_len_q; // payload_len + 20

  // Checksum pipeline
  logic [31:0] csum_q;
  logic [15:0] ip_csum_q;

  // Checksum fold wires (combinatorial from csum_q)
  logic [16:0] fold1_w;
  logic [15:0] fold2_w;
  assign fold1_w = {1'b0, csum_q[15:0]} + {1'b0, csum_q[31:16]};
  assign fold2_w = fold1_w[15:0] + {15'd0, fold1_w[16]};

  // -------------------------------------------------------------------------
  // IP header byte ROM (combinatorial from registered fields)
  // -------------------------------------------------------------------------
  logic [7:0] hdr_byte_w;
  always_comb begin
    case (hdr_cnt_q)
      5'd0:  hdr_byte_w = 8'h45;               // version=4, IHL=5
      5'd1:  hdr_byte_w = 8'h00;               // DSCP+ECN
      5'd2:  hdr_byte_w = total_len_q[15:8];
      5'd3:  hdr_byte_w = total_len_q[7:0];
      5'd4:  hdr_byte_w = 8'h00;               // identification MSB
      5'd5:  hdr_byte_w = 8'h00;               // identification LSB
      5'd6:  hdr_byte_w = 8'h40;               // flags: DF=1, MF=0
      5'd7:  hdr_byte_w = 8'h00;               // frag_off = 0
      5'd8:  hdr_byte_w = 8'h40;               // TTL = 64
      5'd9:  hdr_byte_w = proto_q;
      5'd10: hdr_byte_w = ip_csum_q[15:8];
      5'd11: hdr_byte_w = ip_csum_q[7:0];
      5'd12: hdr_byte_w = LOCAL_IP[31:24];     // src IP (FPGA)
      5'd13: hdr_byte_w = LOCAL_IP[23:16];
      5'd14: hdr_byte_w = LOCAL_IP[15:8];
      5'd15: hdr_byte_w = LOCAL_IP[7:0];
      5'd16: hdr_byte_w = dst_ip_q[31:24];
      5'd17: hdr_byte_w = dst_ip_q[23:16];
      5'd18: hdr_byte_w = dst_ip_q[15:8];
      5'd19: hdr_byte_w = dst_ip_q[7:0];
      default: hdr_byte_w = 8'h00;
    endcase
  end

  // -------------------------------------------------------------------------
  // FSM logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= ST_IDLE;
      hdr_cnt_q   <= 5'd0;
      proto_q     <= 8'h00;
      dst_ip_q    <= '0;
      dst_mac_q   <= '0;
      total_len_q <= 16'd0;
      csum_q      <= 32'd0;
      ip_csum_q   <= 16'd0;
    end else begin
      case (state_q)

        ST_IDLE: begin
          if (s_meta_valid_i) begin
            proto_q     <= s_meta_proto_i;
            dst_ip_q    <= s_meta_dst_ip_i;
            dst_mac_q   <= s_meta_dst_mac_i;
            total_len_q <= s_meta_payload_len_i + 16'd20;
            state_q     <= ST_CSUM0;
          end
        end

        ST_CSUM0: begin
          csum_q  <= CSUM_SEED + {16'd0, total_len_q};
          state_q <= ST_CSUM1;
        end

        ST_CSUM1: begin
          csum_q  <= csum_q + {16'd0, 8'h40, proto_q};  // TTL=64, protocol
          state_q <= ST_CSUM2;
        end

        ST_CSUM2: begin
          csum_q  <= csum_q + {16'd0, dst_ip_q[31:16]};
          state_q <= ST_CSUM3;
        end

        ST_CSUM3: begin
          csum_q  <= csum_q + {16'd0, dst_ip_q[15:0]};
          state_q <= ST_FOLD;
        end

        ST_FOLD: begin
          ip_csum_q <= ~fold2_w;
          state_q   <= ST_TX_META;
        end

        ST_TX_META: begin
          if (m_meta_valid_o && m_meta_ready_i) begin
            hdr_cnt_q <= 5'd0;
            state_q   <= ST_TX_HDR;
          end
        end

        ST_TX_HDR: begin
          if (m_axis_tready_i) begin
            if (hdr_cnt_q == 5'd19) begin
              hdr_cnt_q <= 5'd0;
              state_q   <= ST_TX_PAY;
            end else begin
              hdr_cnt_q <= hdr_cnt_q + 5'd1;
            end
          end
        end

        ST_TX_PAY: begin
          if (s_axis_tvalid_i && m_axis_tready_i && s_axis_tlast_i) begin
            state_q <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Output wiring
  // -------------------------------------------------------------------------
  assign s_meta_ready_o = (state_q == ST_IDLE);

  assign m_meta_valid_o    = (state_q == ST_TX_META);
  assign m_meta_dst_mac_o  = dst_mac_q;
  assign m_meta_src_mac_o  = LOCAL_MAC;
  assign m_meta_eth_type_o = 16'h0800;

  assign s_axis_tready_o = (state_q == ST_TX_PAY) && m_axis_tready_i;

  assign m_axis_tdata_o  = (state_q == ST_TX_HDR) ? hdr_byte_w : s_axis_tdata_i;
  assign m_axis_tvalid_o = (state_q == ST_TX_HDR) ||
                           (s_axis_tvalid_i && (state_q == ST_TX_PAY));
  assign m_axis_tlast_o  = (state_q == ST_TX_PAY) && s_axis_tvalid_i && s_axis_tlast_i;
  assign m_axis_tuser_o  = (state_q == ST_TX_PAY) && s_axis_tuser_i;

endmodule

`endif // IPV4_TX_SV
