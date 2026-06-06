/**
 * @file eth_tx_arb.sv
 * @brief 3-to-1 fixed-priority TX arbiter for eth_tx_mac.
 * @details Arbitrates three sources (port0=ARP, port1=ICMP, port2=UDP) to one
 *   eth_tx_mac input stream at the frame level (no preemption mid-frame).
 *   Priority: port0 > port1 > port2.
 *
 *   States: ST_IDLE (arbitrate) -> ST_TX_META (wait meta_ready) -> ST_TX_PAY (until tlast).
 *   Meta handshake: when grant is determined in ST_IDLE, immediately move to ST_TX_META.
 *   Payload: forward selected port's stream until tlast, then return to ST_IDLE.
 *
 *   Payload output is registered (1-stage pipeline/skid buffer) to break the
 *   combinatorial path from upstream RAM read through the 3-way mux into eth_tx_mac.
 *   Upstream tready uses pipe_ready_w = m_axis_tready_i || !m_tvalid_q so the
 *   source can pre-load the pipeline one cycle ahead of downstream consumption.
 *
 *   All three input ports share the same meta interface format as eth_tx_mac:
 *     dst_mac[47:0], src_mac[47:0], eth_type[15:0].
 */
`ifndef ETH_TX_ARB_SV
`define ETH_TX_ARB_SV

`default_nettype none

module eth_tx_arb (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // ---- Port 0: ARP ----
  input  wire logic        s_meta0_valid_i,
  output      logic        s_meta0_ready_o,
  input  wire logic [47:0] s_meta0_dst_mac_i,
  input  wire logic [47:0] s_meta0_src_mac_i,
  input  wire logic [15:0] s_meta0_eth_type_i,
  input  wire logic [7:0]  s_axis0_tdata_i,
  input  wire logic        s_axis0_tvalid_i,
  output      logic        s_axis0_tready_o,
  input  wire logic        s_axis0_tlast_i,
  input  wire logic        s_axis0_tuser_i,

  // ---- Port 1: ICMP ----
  input  wire logic        s_meta1_valid_i,
  output      logic        s_meta1_ready_o,
  input  wire logic [47:0] s_meta1_dst_mac_i,
  input  wire logic [47:0] s_meta1_src_mac_i,
  input  wire logic [15:0] s_meta1_eth_type_i,
  input  wire logic [7:0]  s_axis1_tdata_i,
  input  wire logic        s_axis1_tvalid_i,
  output      logic        s_axis1_tready_o,
  input  wire logic        s_axis1_tlast_i,
  input  wire logic        s_axis1_tuser_i,

  // ---- Port 2: UDP ----
  input  wire logic        s_meta2_valid_i,
  output      logic        s_meta2_ready_o,
  input  wire logic [47:0] s_meta2_dst_mac_i,
  input  wire logic [47:0] s_meta2_src_mac_i,
  input  wire logic [15:0] s_meta2_eth_type_i,
  input  wire logic [7:0]  s_axis2_tdata_i,
  input  wire logic        s_axis2_tvalid_i,
  output      logic        s_axis2_tready_o,
  input  wire logic        s_axis2_tlast_i,
  input  wire logic        s_axis2_tuser_i,

  // ---- Output to eth_tx_mac ----
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

  typedef enum logic [1:0] {
    ST_IDLE     = 2'd0,
    ST_TX_META  = 2'd1,
    ST_TX_PAY   = 2'd2
  } state_e;

  state_e      state_q;
  logic [1:0]  grant_q;   // 0=port0, 1=port1, 2=port2

  // Combinatorial arbitration (fixed priority 0 > 1 > 2)
  logic [1:0] arb_grant_w;
  logic       arb_any_w;
  always_comb begin
    if (s_meta0_valid_i) begin
      arb_grant_w = 2'd0;
      arb_any_w   = 1'b1;
    end else if (s_meta1_valid_i) begin
      arb_grant_w = 2'd1;
      arb_any_w   = 1'b1;
    end else if (s_meta2_valid_i) begin
      arb_grant_w = 2'd2;
      arb_any_w   = 1'b1;
    end else begin
      arb_grant_w = 2'd0;
      arb_any_w   = 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // Registered payload output (1-stage pipeline breaks timing path)
  // -------------------------------------------------------------------------
  logic [7:0] m_tdata_q;
  logic       m_tvalid_q;
  logic       m_tlast_q;
  logic       m_tuser_q;

  // Pipeline can accept upstream data when downstream consumed it or slot is empty
  logic pipe_ready_w;
  assign pipe_ready_w = m_axis_tready_i || !m_tvalid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m_tdata_q  <= 8'h00;
      m_tvalid_q <= 1'b0;
      m_tlast_q  <= 1'b0;
      m_tuser_q  <= 1'b0;
    end else if (pipe_ready_w) begin
      case (grant_q)
        2'd0: begin
          m_tdata_q  <= s_axis0_tdata_i;
          m_tvalid_q <= s_axis0_tvalid_i && (state_q == ST_TX_PAY);
          m_tlast_q  <= s_axis0_tlast_i;
          m_tuser_q  <= s_axis0_tuser_i;
        end
        2'd1: begin
          m_tdata_q  <= s_axis1_tdata_i;
          m_tvalid_q <= s_axis1_tvalid_i && (state_q == ST_TX_PAY);
          m_tlast_q  <= s_axis1_tlast_i;
          m_tuser_q  <= s_axis1_tuser_i;
        end
        default: begin
          m_tdata_q  <= s_axis2_tdata_i;
          m_tvalid_q <= s_axis2_tvalid_i && (state_q == ST_TX_PAY);
          m_tlast_q  <= s_axis2_tlast_i;
          m_tuser_q  <= s_axis2_tuser_i;
        end
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      grant_q <= 2'd0;
    end else begin
      case (state_q)

        ST_IDLE: begin
          if (arb_any_w) begin
            grant_q <= arb_grant_w;
            state_q <= ST_TX_META;
          end
        end

        ST_TX_META: begin
          if (m_meta_valid_o && m_meta_ready_i)
            state_q <= ST_TX_PAY;
        end

        ST_TX_PAY: begin
          // Check registered pipeline output — not combinatorial source signals
          if (m_tvalid_q && m_axis_tready_i && m_tlast_q)
            state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Meta output mux (combinatorial — meta is not on the critical timing path)
  // -------------------------------------------------------------------------
  always_comb begin
    case (grant_q)
      2'd0: begin
        m_meta_dst_mac_o  = s_meta0_dst_mac_i;
        m_meta_src_mac_o  = s_meta0_src_mac_i;
        m_meta_eth_type_o = s_meta0_eth_type_i;
      end
      2'd1: begin
        m_meta_dst_mac_o  = s_meta1_dst_mac_i;
        m_meta_src_mac_o  = s_meta1_src_mac_i;
        m_meta_eth_type_o = s_meta1_eth_type_i;
      end
      default: begin
        m_meta_dst_mac_o  = s_meta2_dst_mac_i;
        m_meta_src_mac_o  = s_meta2_src_mac_i;
        m_meta_eth_type_o = s_meta2_eth_type_i;
      end
    endcase
  end

  // -------------------------------------------------------------------------
  // Meta handshake
  // -------------------------------------------------------------------------
  assign m_meta_valid_o  = (state_q == ST_TX_META);

  assign s_meta0_ready_o = (state_q == ST_TX_META) && (grant_q == 2'd0) && m_meta_ready_i;
  assign s_meta1_ready_o = (state_q == ST_TX_META) && (grant_q == 2'd1) && m_meta_ready_i;
  assign s_meta2_ready_o = (state_q == ST_TX_META) && (grant_q == 2'd2) && m_meta_ready_i;

  // -------------------------------------------------------------------------
  // Payload tready: upstream advances when pipeline slot is available
  // -------------------------------------------------------------------------
  assign s_axis0_tready_o = (state_q == ST_TX_PAY) && (grant_q == 2'd0) && pipe_ready_w;
  assign s_axis1_tready_o = (state_q == ST_TX_PAY) && (grant_q == 2'd1) && pipe_ready_w;
  assign s_axis2_tready_o = (state_q == ST_TX_PAY) && (grant_q == 2'd2) && pipe_ready_w;

  // -------------------------------------------------------------------------
  // Registered payload output
  // -------------------------------------------------------------------------
  assign m_axis_tdata_o  = m_tdata_q;
  assign m_axis_tvalid_o = m_tvalid_q;
  assign m_axis_tlast_o  = m_tlast_q;
  assign m_axis_tuser_o  = m_tuser_q;

endmodule

`endif // ETH_TX_ARB_SV
