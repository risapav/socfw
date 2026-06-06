/**
 * @file arp_tx.sv
 * @brief ARP reply builder: generates an ARP reply frame for eth_tx_mac.
 * @param LOCAL_MAC  48-bit FPGA MAC address.
 * @param LOCAL_IP   32-bit FPGA IP address.
 * @details Consumes requester MAC+IP from arp_rx (via async_fifo CDC in TX clock domain).
 *   Drives eth_tx_mac with: dst_mac=requester_mac, src_mac=LOCAL_MAC, eth_type=0x0806,
 *   followed by the 28-byte ARP reply payload.
 *
 *   FSM: ST_IDLE → ST_TX_META (wait for eth_tx_mac meta_ready) →
 *        ST_TX_PAYLOAD (28 bytes) → ST_IDLE.
 *
 *   ARP reply payload byte map (28 bytes):
 *     [0:1]  htype=0x0001  [2:3]  ptype=0x0800  [4] hlen=6  [5] plen=4
 *     [6:7]  oper=0x0002 (reply)
 *     [8:13] sha = LOCAL_MAC  (our MAC)
 *     [14:17] spa = LOCAL_IP  (our IP)
 *     [18:23] tha = requester_mac  (their MAC)
 *     [24:27] tpa = requester_ip   (their IP)
 */
`ifndef ARP_TX_SV
`define ARP_TX_SV

`default_nettype none

module arp_tx #(
  parameter logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0,
  parameter logic [31:0] LOCAL_IP  = 32'hC0A80002
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // ---- Request parameters from arp_rx (via CDC FIFO) ----
  input  wire logic        s_valid_i,
  output      logic        s_ready_o,
  input  wire logic [47:0] s_requester_mac_i,
  input  wire logic [31:0] s_requester_ip_i,

  // ---- eth_tx_mac metadata interface ----
  output      logic        m_meta_valid_o,
  input  wire logic        m_meta_ready_i,
  output      logic [47:0] m_meta_dst_mac_o,
  output      logic [47:0] m_meta_src_mac_o,
  output      logic [15:0] m_meta_eth_type_o,

  // ---- eth_tx_mac payload AXI-Stream ----
  output      logic [7:0]  m_axis_tdata_o,
  output      logic        m_axis_tvalid_o,
  input  wire logic        m_axis_tready_i,
  output      logic        m_axis_tlast_o,
  output      logic        m_axis_tuser_o,

  // ---- Diagnostics ----
  output      logic [15:0] stat_tx_replies
);

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE       = 2'd0,
    ST_TX_META    = 2'd1,
    ST_TX_PAYLOAD = 2'd2
  } state_e;

  state_e      state_q;
  logic [4:0]  byte_cnt_q;  // 0..27

  logic [47:0] req_mac_q;
  logic [31:0] req_ip_q;
  logic [15:0] cnt_reply_q;

  // -------------------------------------------------------------------------
  // 28-byte ARP reply payload ROM (combinatorial from byte_cnt_q)
  // -------------------------------------------------------------------------
  logic [7:0] payload_byte_w;
  always_comb begin
    case (byte_cnt_q)
      // htype = 0x0001
      5'd0:  payload_byte_w = 8'h00;
      5'd1:  payload_byte_w = 8'h01;
      // ptype = 0x0800
      5'd2:  payload_byte_w = 8'h08;
      5'd3:  payload_byte_w = 8'h00;
      // hlen = 6
      5'd4:  payload_byte_w = 8'h06;
      // plen = 4
      5'd5:  payload_byte_w = 8'h04;
      // oper = 0x0002 (reply)
      5'd6:  payload_byte_w = 8'h00;
      5'd7:  payload_byte_w = 8'h02;
      // sha = LOCAL_MAC (our MAC)
      5'd8:  payload_byte_w = LOCAL_MAC[47:40];
      5'd9:  payload_byte_w = LOCAL_MAC[39:32];
      5'd10: payload_byte_w = LOCAL_MAC[31:24];
      5'd11: payload_byte_w = LOCAL_MAC[23:16];
      5'd12: payload_byte_w = LOCAL_MAC[15:8];
      5'd13: payload_byte_w = LOCAL_MAC[7:0];
      // spa = LOCAL_IP (our IP)
      5'd14: payload_byte_w = LOCAL_IP[31:24];
      5'd15: payload_byte_w = LOCAL_IP[23:16];
      5'd16: payload_byte_w = LOCAL_IP[15:8];
      5'd17: payload_byte_w = LOCAL_IP[7:0];
      // tha = requester MAC
      5'd18: payload_byte_w = req_mac_q[47:40];
      5'd19: payload_byte_w = req_mac_q[39:32];
      5'd20: payload_byte_w = req_mac_q[31:24];
      5'd21: payload_byte_w = req_mac_q[23:16];
      5'd22: payload_byte_w = req_mac_q[15:8];
      5'd23: payload_byte_w = req_mac_q[7:0];
      // tpa = requester IP
      5'd24: payload_byte_w = req_ip_q[31:24];
      5'd25: payload_byte_w = req_ip_q[23:16];
      5'd26: payload_byte_w = req_ip_q[15:8];
      5'd27: payload_byte_w = req_ip_q[7:0];
      default: payload_byte_w = 8'h00;
    endcase
  end

  logic fire_w;
  assign fire_w = m_axis_tvalid_o && m_axis_tready_i;

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_IDLE;
      byte_cnt_q   <= 5'd0;
      req_mac_q    <= '0;
      req_ip_q     <= '0;
      cnt_reply_q  <= '0;
    end else begin
      case (state_q)

        ST_IDLE: begin
          if (s_valid_i) begin
            req_mac_q  <= s_requester_mac_i;
            req_ip_q   <= s_requester_ip_i;
            byte_cnt_q <= 5'd0;
            state_q    <= ST_TX_META;
          end
        end

        ST_TX_META: begin
          if (m_meta_valid_o && m_meta_ready_i) begin
            state_q <= ST_TX_PAYLOAD;
          end
        end

        ST_TX_PAYLOAD: begin
          if (fire_w) begin
            if (byte_cnt_q == 5'd27) begin
              cnt_reply_q <= cnt_reply_q + 16'd1;
              state_q     <= ST_IDLE;
              byte_cnt_q  <= 5'd0;
            end else begin
              byte_cnt_q <= byte_cnt_q + 5'd1;
            end
          end
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Output wiring
  // -------------------------------------------------------------------------
  assign s_ready_o = (state_q == ST_IDLE);

  assign m_meta_valid_o    = (state_q == ST_TX_META);
  assign m_meta_dst_mac_o  = req_mac_q;
  assign m_meta_src_mac_o  = LOCAL_MAC;
  assign m_meta_eth_type_o = 16'h0806;

  assign m_axis_tdata_o  = payload_byte_w;
  assign m_axis_tvalid_o = (state_q == ST_TX_PAYLOAD);
  assign m_axis_tlast_o  = (state_q == ST_TX_PAYLOAD) && (byte_cnt_q == 5'd27);
  assign m_axis_tuser_o  = 1'b0;

  assign stat_tx_replies = cnt_reply_q;

endmodule

`endif // ARP_TX_SV
